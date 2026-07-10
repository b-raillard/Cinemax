import Foundation
import OSLog
import Get
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

/// Strips access tokens from a raw response/JSON body before it is logged.
/// PlaybackInfo bodies embed the token inside `MediaSources[].TranscodingUrl`
/// (`…api_key=<token>…`), so logging the body verbatim leaks the token the way
/// `redactedURL` prevents for standalone URLs. Redacts the `api_key`/`apikey`/
/// `…token…` query-style assignments wherever they appear in the string.
/// Case-insensitive; keeps everything else intact for debuggability.
public func redactedBody(_ raw: String) -> String {
    // Matches `key=<value>` where key is api_key / apikey / anything ending in
    // "token" (e.g. `api_key`, `X-Emby-Token`), stopping the value at the first
    // delimiter that can terminate a query param inside JSON or a URL.
    let pattern = #"(?i)((?:api_?key|[a-z-]*token)=)[^&"'\\\s]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
    let range = NSRange(raw.startIndex..., in: raw)
    return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "$1REDACTED")
}

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

    /// Precise 401 classifier — the SINGLE source of truth for "is this error
    /// an authentication failure". Used by `notifyIfUnauthorized` (lazy
    /// recovery) AND `validateSession` (the confirm-before-logout probe).
    ///
    /// `Get` is a direct CinemaxKit dependency (see Package.swift), so we
    /// pattern-match `Get.APIError.unacceptableStatusCode(401)` — the canonical
    /// signal the Jellyfin SDK throws — instead of the old fragile substring
    /// match on `"(401)"`, which produced false positives (any error text
    /// containing `(401)`, a `403/404` body echoing 401, our own
    /// `playbackFailed("… 401")` message, etc.). Genuine 401s arriving by
    /// other routes are also covered: `URLError`/`NSURLErrorUserAuthentication-
    /// Required` (-1013) and our structured `JellyfinError.unauthorized` raised
    /// from the raw PlaybackInfo POST.
    static func isUnauthorized(_ error: Error) -> Bool {
        if case Get.APIError.unacceptableStatusCode(let code) = error, code == 401 {
            return true
        }
        if case JellyfinError.unauthorized = error { return true }
        if (error as NSError).code == NSURLErrorUserAuthenticationRequired { return true }
        if let urlErr = error as? URLError,
           let resp = urlErr.userInfo[NSURLErrorFailingURLErrorKey] as? HTTPURLResponse,
           resp.statusCode == 401 {
            return true
        }
        return false
    }

    /// Fires the unauthorized callback when `error` is a genuine 401. Called
    /// from the catch block of every session-scoped public method that surfaces
    /// results to the UI; fire-and-forget reporters in `+Playback.swift` skip it
    /// because they swallow errors silently anyway.
    internal func notifyIfUnauthorized(_ error: Error) {
        if Self.isUnauthorized(error) { getOnUnauthorized()?() }
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

    // MARK: - Quick Connect

    public func isQuickConnectEnabled() async throws -> Bool {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        // The endpoint returns a raw JSON boolean body (`true`/`false`), typed
        // as `Data` by the SDK — decode it ourselves.
        let data = try await client.send(Paths.getQuickConnectEnabled).value
        if let bool = try? JSONDecoder().decode(Bool.self, from: data) { return bool }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.lowercased() == "true"
    }

    public func initiateQuickConnect() async throws -> QuickConnectRequest {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let result = try await client.send(Paths.initiateQuickConnect).value
        guard let code = result.code, let secret = result.secret else {
            throw JellyfinError.authenticationFailed
        }
        return QuickConnectRequest(code: code, secret: secret)
    }

    public func quickConnectAuthorized(secret: String) async throws -> Bool {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let result = try await client.send(Paths.getQuickConnectState(secret: secret)).value
        return result.isAuthenticated ?? false
    }

    public func authenticateWithQuickConnect(secret: String) async throws -> UserSession {
        guard let client = getClient() else { throw JellyfinError.notConnected }

        let body = QuickConnectDto(secret: secret)
        let result = try await client.send(Paths.authenticateWithQuickConnect(body)).value

        guard let accessToken = result.accessToken,
              let userID = result.user?.id else {
            throw JellyfinError.authenticationFailed
        }

        // Reconfigure client with the issued access token — identical to the
        // password path so every downstream call is authenticated.
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
            username: result.user?.name ?? "",
            accessToken: accessToken,
            serverID: result.serverID ?? ""
        )
    }

    public func authorizeQuickConnect(code: String) async throws -> Bool {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        do {
            // No `userID` is sent: the server authorizes for the user behind the
            // access token (matches the Jellyfin web client, and means a user
            // can't approve a sign-in as someone else). The endpoint returns a
            // raw JSON boolean body typed as `Data` by the SDK — decode it like
            // `isQuickConnectEnabled`.
            let data = try await client.send(Paths.authorizeQuickConnect(code: code)).value
            if let bool = try? JSONDecoder().decode(Bool.self, from: data) { return bool }
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.lowercased() == "true"
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
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
    /// `waitsForConnectivity = false` + the app-layer `NetworkMonitor` are what
    /// actually detect *offline* (instantly), so this config only needs to bound
    /// the "online but slow server" case. The previous 8s/20s values were far too
    /// tight for self-hosted Jellyfin: a server that briefly stalls (e.g. while
    /// libVLC floods it with AVI range-requests, or mid-transcode) made a single
    /// slow API call fail and tore whole screens down to "Serveur injoignable".
    /// 30s idle / 60s total tolerates a slow server while still failing a truly
    /// dead one in bounded time.
    fileprivate static let fastFailSessionConfiguration: URLSessionConfiguration = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
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
