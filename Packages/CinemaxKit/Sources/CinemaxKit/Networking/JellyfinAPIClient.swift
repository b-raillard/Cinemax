import Foundation
import OSLog
#if DEBUG
import Get
#endif
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "API")

#if DEBUG
func debugLog(_ message: String) {
    logger.debug("\(message)")
}
#endif

/// Strips secret query items (`api_key`, `ApiKey`, `X-Emby-Token`, anything
/// containing "token") from a URL so logs can include the URL without leaking
/// the access token. Keeps path + non-secret query items for debuggability.
/// Accepts `String?` because Jellyfin's `transcodingURL` is a string path we
/// log before resolving to a `URL`.
///
/// KEEP THE PREDICATE IN SYNC with `DownloadItem.sanitizedRemoteURL`
/// (Shared/Screens/Downloads/DownloadItem+BaseItemDto.swift), which uses the
/// same rule to strip credentials before persisting download URLs to disk.
public func redactedURL(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "nil" }
    guard var components = URLComponents(string: raw) else { return raw }
    if let items = components.queryItems {
        components.queryItems = items.map { item in
            let lower = item.name.lowercased()
            if lower == "api_key" || lower == "apikey" || lower.contains("token") {
                return URLQueryItem(name: item.name, value: "REDACTED")
            }
            return item
        }
    }
    return components.string ?? raw
}

public func redactedURL(_ url: URL) -> String { redactedURL(url.absoluteString) }

public final class JellyfinAPIClient: Sendable {
    // `JellyfinClient` (from jellyfin-sdk-swift) is not marked `Sendable`, but we need
    // cross-actor access. Invariant: every access to `_jellyfinClient` / `_serverURL`
    // goes through `getClient()` / `getServerURL()` / `setClient(_:url:)` which all
    // acquire `lock`. Do not read or write these fields directly outside those helpers.
    private let lock = NSLock()
    nonisolated(unsafe) private var _jellyfinClient: JellyfinClient?
    nonisolated(unsafe) private var _serverURL: URL?
    nonisolated(unsafe) private var _maxContentAge: Int = 0
    /// Fired by `notifyIfUnauthorized` whenever the Jellyfin SDK surfaces an
    /// HTTP 401 from any session-scoped call. Set once at app launch by
    /// `AppState.init()`; the closure must be `@Sendable` because it's
    /// invoked from whatever actor the failing API call ran on.
    nonisolated(unsafe) private var _onUnauthorized: (@Sendable () -> Void)?
    internal let cache = APICache()

    public init() {}

    internal func getClient() -> JellyfinClient? {
        lock.lock()
        defer { lock.unlock() }
        return _jellyfinClient
    }

    internal func setClient(_ client: JellyfinClient, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        _jellyfinClient = client
        _serverURL = url
    }

    internal func getServerURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return _serverURL
    }

    internal func getMaxContentAge() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxContentAge
    }

    public func setOnUnauthorized(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        _onUnauthorized = callback
    }

    private func getOnUnauthorized() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return _onUnauthorized
    }

    /// Inspects an error thrown from `client.send(...)` and fires the
    /// unauthorized callback if the underlying HTTP status was 401.
    /// `Get.APIError.unacceptableStatusCode(401)` is the canonical signal
    /// from the Jellyfin SDK, but `Get` is not a direct CinemaxKit
    /// dependency — only transitive via jellyfin-sdk-swift. Rather than
    /// add a fourth package dependency just for one type cast, we match
    /// on the error's textual representation. Get's APIError prints as
    /// `"unacceptableStatusCode(401)"` and `URLError` for HTTP 401
    /// surfaces NSURLErrorUserAuthenticationRequired (-1013). Either
    /// signal fires the callback. Called from the catch block of every
    /// session-scoped public method that surfaces results to the UI;
    /// fire-and-forget reporters in `+Playback.swift` skip it because
    /// they swallow errors silently anyway.
    internal func notifyIfUnauthorized(_ error: Error) {
        let description = String(describing: error)
        let isHTTP401 = description.contains("unacceptableStatusCode(401)")
            || description.contains("(401)")
        let isURLAuth = (error as NSError).code == NSURLErrorUserAuthenticationRequired
        if isHTTP401 || isURLAuth {
            getOnUnauthorized()?()
        }
    }

    /// See `ServerAPI.applyContentRatingLimit`. Pushes the user's Privacy &
    /// Security selection into the client so every subsequent item query picks
    /// it up automatically — no per-call plumbing needed.
    public func applyContentRatingLimit(maxAge: Int) {
        lock.lock()
        defer { lock.unlock() }
        _maxContentAge = max(0, maxAge)
        cache.clear()
    }

    /// Keeps only items whose `officialRating` passes the active maximum-age
    /// limit. A no-op when the limit is disabled.
    internal func applyRatingFilter(_ items: [BaseItemDto]) -> [BaseItemDto] {
        let maxAge = getMaxContentAge()
        guard maxAge > 0 else { return items }
        return items.filter { ContentRatingClassifier.passes(rating: $0.officialRating, maxAge: maxAge) }
    }

    public func connectToServer(url: URL) async throws -> ServerInfo {
        let client = JellyfinClient(
            configuration: .init(
                url: url,
                client: "Cinemax",
                deviceName: deviceName,
                deviceID: deviceID,
                version: appVersion
            ),
            sessionConfiguration: Self.fastFailSessionConfiguration
        )

        let response = try await client.send(Paths.getPublicSystemInfo)
        let info = response.value

        setClient(client, url: url)

        return ServerInfo(
            name: info.serverName ?? "Jellyfin Server",
            serverID: info.id ?? "",
            version: info.version ?? "",
            url: url
        )
    }

    /// Fetches server info using the existing client (does NOT replace it).
    public func fetchServerInfo() async throws -> ServerInfo {
        let cacheKey = "serverInfo"
        if let cached: ServerInfo = cache.get(cacheKey) { return cached }

        guard let client = getClient(),
              let url = getServerURL() else {
            throw JellyfinError.notConnected
        }

        let response = try await client.send(Paths.getPublicSystemInfo)
        let info = response.value

        let result = ServerInfo(
            name: info.serverName ?? "Jellyfin Server",
            serverID: info.id ?? "",
            version: info.version ?? "",
            url: url
        )
        cache.set(cacheKey, value: result, ttl: 600)
        return result
    }

    public func authenticate(username: String, password: String) async throws -> UserSession {
        guard let client = getClient() else {
            throw JellyfinError.notConnected
        }

        let body = AuthenticateUserByName(pw: password, username: username)
        let request = Paths.authenticateUserByName(body)
        let response = try await client.send(request)
        let result = response.value

        guard let accessToken = result.accessToken,
              let userID = result.user?.id else {
            throw JellyfinError.authenticationFailed
        }

        // Reconfigure client with access token
        if let url = getServerURL() {
            let authedClient = JellyfinClient(
                configuration: .init(
                    url: url,
                    accessToken: accessToken,
                    client: "Cinemax",
                    deviceName: deviceName,
                    deviceID: deviceID,
                    version: appVersion
                ),
                sessionConfiguration: Self.fastFailSessionConfiguration
            )
            setClient(authedClient, url: url)
        }

        return UserSession(
            userID: userID,
            username: result.user?.name ?? username,
            accessToken: accessToken,
            serverID: result.serverID ?? ""
        )
    }

    /// Invalidates every cached response (resume items, latest media, genres, etc.).
    /// Called by Settings → Server → Refresh Catalogue so that the next fetch hits
    /// the server rather than returning stale cached data.
    public func clearCache() {
        cache.clear()
    }

    public func reconnect(url: URL, accessToken: String) {
        cache.clear()
        let client = JellyfinClient(
            configuration: .init(
                url: url,
                accessToken: accessToken,
                client: "Cinemax",
                deviceName: deviceName,
                deviceID: deviceID,
                version: appVersion
            ),
            sessionConfiguration: Self.fastFailSessionConfiguration
        )
        setClient(client, url: url)
    }

    /// URLSession configuration applied to every `JellyfinClient` we hand out.
    /// Default system timeouts (~60s per request, 7 days per resource) make
    /// the app feel frozen when the user goes offline mid-flow — these tight
    /// values surface a `URLError` in ~8s so callers can fall back to cached
    /// or downloaded content. NetworkMonitor in the app layer gives us the
    /// fast path; this is the safety net for cases where the OS hasn't yet
    /// flipped path status.
    fileprivate static let fastFailSessionConfiguration: URLSessionConfiguration = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        return c
    }()

    private var deviceName: String {
        #if os(tvOS)
        "Apple TV"
        #elseif os(iOS)
        "iPhone"
        #else
        "Apple Device"
        #endif
    }

    internal var deviceID: String {
        KeychainService.getOrCreateDeviceID()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
