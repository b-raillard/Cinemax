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

/// Strips secret query items (`ApiKey`, legacy `api_key`, `X-Emby-Token`, anything
/// containing "token") from a URL so logs can include the URL without leaking
/// the access token. Keeps path + non-secret query items for debuggability.
/// Accepts `String?` because Jellyfin's `transcodingURL` is a string path we
/// log before resolving to a `URL`.
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
    /// Everything that describes the live connection, read and replaced in ONE
    /// critical section (audit 2026-09-22, Q3).
    ///
    /// These used to be seven `nonisolated(unsafe)` fields, each behind its own
    /// short lock: a reader could see the new client with the old URL, and a
    /// writer that had awaited — `connectToServer`'s `/System/Info/Public`, the
    /// version probe of `fetchServerInfo` — wrote after a `reconnect` that
    /// landed meanwhile, pointing the app back at the server it had just left
    /// or stamping one server's version onto another.
    struct ClientState {
        /// `JellyfinClient` (jellyfin-sdk-swift) is not `Sendable`; it is only
        /// ever read or replaced inside `withState`.
        var client: JellyfinClient?
        var serverURL: URL?
        /// The token the current client was built with, kept so a language
        /// change can rebuild an authenticated client without a re-login.
        /// `nil` while the client is the pre-auth one from `connectToServer`.
        var accessToken: String?
        /// Version of the server currently pointed at, parsed from
        /// `/System/Info/Public`. `nil` means "not learned yet" — every
        /// capability gate MUST read that as "unsupported", because the window
        /// exists on every cold launch (the probe runs in the background while
        /// the UI is already live).
        var serverVersion: ServerVersion?
        /// The app language every request asks the server to answer in (`"fr"`
        /// / `"en"`). Baked into the `URLSessionConfiguration` at client
        /// construction, so a change rebuilds the client (`setPreferredLanguage`).
        var preferredLanguage: String?
        var maxContentAge: Int = 0
        /// Fired by `notifyIfUnauthorized` on a genuine 401. Set once at launch
        /// by `AppState.init()`; `@Sendable` because it runs on whatever actor
        /// the failing call ran on.
        var onUnauthorized: (@Sendable () -> Void)?
        /// Bumped every time the client is replaced. A write computed from an
        /// older generation — i.e. across an `await` — is dropped.
        var generation: UInt64 = 0

        /// Installs `client` for `url` unless the connection moved on since
        /// `expected` was read. Returns whether it was installed.
        mutating func install(
            _ client: JellyfinClient,
            url: URL,
            accessToken: String?,
            ifGeneration expected: UInt64? = nil
        ) -> Bool {
            if let expected, expected != generation { return false }
            self.client = client
            serverURL = url
            self.accessToken = accessToken
            generation &+= 1
            return true
        }
    }

    private let lock = NSLock()
    /// The ONE unsafe field, and nothing touches it outside `withState`.
    nonisolated(unsafe) private var _state = ClientState()

    private func withState<T>(_ body: (inout ClientState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&_state)
    }
    internal let cache = APICache()

    /// Every short-TTL cache key whose payload carries per-item **userData**
    /// (watched marks, resume positions, the series' next-up pointer). All three
    /// must be swept together by every userData mutator — `markItemPlayed`,
    /// `markItemUnplayed` (`+Library`) and `reportPlaybackStopped` (`+Playback`)
    /// — because a single toggle cascades across all of them: marking a series
    /// played flips every episode's watched mark, changes each season's progress,
    /// AND advances next-up. Declared once here rather than repeated as literals
    /// at each site so a new cached userData-bearing endpoint is added in exactly
    /// one place and can't be half-wired. `CinemaxKitTests.APICacheTests` asserts
    /// the sweep of this list against the live key shapes.
    ///
    /// Adding an entry means adding a cache whose key uses that prefix; removing
    /// one means that payload is no longer cached (or no longer userData-bearing).
    internal static let userDataCachePrefixes: [String] = ["episodes-", "seasons-", "nextup-"]

    public init() {}

    internal func getClient() -> JellyfinClient? {
        withState { $0.client }
    }

    internal func getServerURL() -> URL? {
        withState { $0.serverURL }
    }

    /// Client and URL read together — never one from before a `reconnect` and
    /// the other from after it.
    internal func getConnection() -> (client: JellyfinClient, serverURL: URL)? {
        withState { state in
            guard let client = state.client, let url = state.serverURL else { return nil }
            return (client, url)
        }
    }

    private func connectionWithGeneration() -> (client: JellyfinClient, serverURL: URL, generation: UInt64)? {
        withState { state in
            guard let client = state.client, let url = state.serverURL else { return nil }
            return (client, url, state.generation)
        }
    }

    internal func getPreferredLanguage() -> String? {
        withState { $0.preferredLanguage }
    }

    /// Records the language and, when a client already exists, rebuilds it so
    /// the new `Accept-Language` applies from the next request. Same server
    /// and same token, so nothing that `reconnect` resets is reset here: the
    /// learned `ServerVersion` stays. The response cache IS dropped — its keys
    /// carry no language, and a cached season list would otherwise keep
    /// serving the previous locale's stream titles for its TTL.
    public func setPreferredLanguage(_ languageCode: String?) {
        let snapshot = withState { state -> (url: URL?, token: String?, hasClient: Bool, generation: UInt64) in
            state.preferredLanguage = languageCode
            return (state.serverURL, state.accessToken, state.client != nil, state.generation)
        }

        guard snapshot.hasClient, let url = snapshot.url else { return }
        let token = snapshot.token
        cache.clear()
        let client = makeClient(url: url, accessToken: token)
        // A reconnect that landed while this client was being built already
        // carries the new language (recorded first, above): keep it.
        _ = withState { $0.install(client, url: url, accessToken: token, ifGeneration: snapshot.generation) }
    }

    /// `Accept-Language` value for an app language code, or `nil` for a blank
    /// one. The app's two languages get a region-qualified primary with the
    /// bare code as fallback — Jellyfin matches cultures by name and falls
    /// back to the parent, so either spelling lands on the right resources.
    public static func acceptLanguageHeader(for languageCode: String) -> String? {
        let code = languageCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return nil }
        switch code {
        case "fr": return "fr-FR, fr;q=0.9"
        case "en": return "en-US, en;q=0.9"
        default: return code
        }
    }

    /// The session configuration for the language currently recorded.
    /// The ONLY place a `JellyfinClient` is built. Every one carries the
    /// certificate delegate: #186 wired it into the two post-login clients
    /// only, so the client `reconnect` rebuilds at every launch — and the ones
    /// from `connectToServer` and a language change — refused a user-approved
    /// self-signed certificate: the server worked until the next relaunch.
    private func makeClient(url: URL, accessToken: String?) -> JellyfinClient {
        JellyfinClient(
            configuration: .init(
                url: url,
                accessToken: accessToken,
                client: "JellyGlass",
                deviceName: deviceName,
                deviceID: deviceID,
                version: appVersion
            ),
            sessionConfiguration: currentSessionConfiguration(),
            // Must be the TASK-level delegate — see the RULE on
            // `ServerTrustDelegate`.
            sessionDelegate: ServerTrustDelegate.shared
        )
    }

    private func currentSessionConfiguration() -> URLSessionConfiguration {
        Self.sessionConfiguration(acceptLanguage: getPreferredLanguage().flatMap(Self.acceptLanguageHeader(for:)))
    }

    internal func getMaxContentAge() -> Int {
        withState { $0.maxContentAge }
    }

    /// The server's version, or `nil` while it hasn't been learned. See
    /// `ClientState.serverVersion` for why `nil` must gate *off*.
    internal func getServerVersion() -> ServerVersion? {
        withState { $0.serverVersion }
    }

    /// Records the version reported by `/System/Info/Public`. An unparseable
    /// string clears it rather than keeping the previous value — a stale higher
    /// version would enable an endpoint the current server may not have.
    internal func setServerVersion(_ raw: String?) {
        let parsed = raw.flatMap(ServerVersion.init)
        withState { $0.serverVersion = parsed }
    }

    /// Whether `url` names the server the client is already pointed at, in the
    /// registry's own equivalence class (`ServerURLNormalizer.dedupKey`). A
    /// client with no URL yet is not "the same server" as anything.
    private static func isSameServer(_ current: URL?, as url: URL) -> Bool {
        guard let current else { return false }
        return ServerURLNormalizer.dedupKey(current) == ServerURLNormalizer.dedupKey(url)
    }

    /// Whether the connected server is known to be at least `required`.
    /// Conservative by construction: an unknown version answers `false`.
    internal func serverSupports(_ required: ServerVersion) -> Bool {
        getServerVersion()?.supports(required) ?? false
    }

    /// `ServerAPI` witness — the learned version, `nil` while unknown. See the
    /// protocol declaration for why the UI gets the raw value rather than
    /// `serverSupports(_:)`.
    public func knownServerVersion() -> ServerVersion? { getServerVersion() }

    public func setOnUnauthorized(_ callback: @escaping @Sendable () -> Void) {
        withState { $0.onUnauthorized = callback }
    }

    private func getOnUnauthorized() -> (@Sendable () -> Void)? {
        withState { $0.onUnauthorized }
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
        withState { $0.maxContentAge = max(0, maxAge) }
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
        let generation = withState { $0.generation }
        let client = makeClient(url: url, accessToken: nil)

        let response = try await client.send(Paths.getPublicSystemInfo)
        let info = response.value

        // Installed only if nothing replaced the client during the probe: a
        // `reconnect` that landed meanwhile (a restore, a server switch) is
        // newer, and this pre-auth client must not point the app back.
        let version = info.version.flatMap(ServerVersion.init)
        let installed = withState { state in
            guard state.install(client, url: url, accessToken: nil, ifGeneration: generation) else { return false }
            state.serverVersion = version
            return true
        }
        guard installed else { throw CancellationError() }

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
        let cacheStamp = cache.stamp()   // before the fetch: see APICache.stamp()
        if let cached: ServerInfo = cache.get(cacheKey) {
            // Re-seed the version on the cache-hit path too, so "we have server
            // info" and "we know the version" can never disagree — `reconnect`
            // clears the version but a caller could otherwise repopulate the
            // cache entry without it.
            setServerVersion(cached.version)
            return cached
        }

        guard let (client, url, generation) = connectionWithGeneration() else {
            throw JellyfinError.notConnected
        }

        let response = try await client.send(Paths.getPublicSystemInfo)
        let info = response.value
        // Only onto the client it was asked of: a switch that landed during the
        // probe would otherwise get the previous server's version.
        let version = info.version.flatMap(ServerVersion.init)
        withState { state in
            if state.generation == generation { state.serverVersion = version }
        }

        let result = ServerInfo(
            name: info.serverName ?? "Jellyfin Server",
            serverID: info.id ?? "",
            version: info.version ?? "",
            url: url
        )
        cache.set(cacheKey, value: result, ttl: 600, stamp: cacheStamp)
        return result
    }

    public func authenticate(username: String, password: String) async throws -> UserSession {
        guard let (client, url, generation) = connectionWithGeneration() else {
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

        // Onto the client the credentials were checked against: a switch that
        // landed during the request owns the connection now.
        let authedClient = makeClient(url: url, accessToken: accessToken)
        guard withState({ $0.install(authedClient, url: url, accessToken: accessToken, ifGeneration: generation) }) else {
            throw CancellationError()
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
        guard let (client, url, generation) = connectionWithGeneration() else { throw JellyfinError.notConnected }

        let body = QuickConnectDto(secret: secret)
        let result = try await client.send(Paths.authenticateWithQuickConnect(body)).value

        guard let accessToken = result.accessToken,
              let userID = result.user?.id else {
            throw JellyfinError.authenticationFailed
        }

        // Reconfigure client with the issued access token — identical to the
        // password path so every downstream call is authenticated.
        // Onto the client the credentials were checked against: a switch that
        // landed during the request owns the connection now.
        let authedClient = makeClient(url: url, accessToken: accessToken)
        guard withState({ $0.install(authedClient, url: url, accessToken: accessToken, ifGeneration: generation) }) else {
            throw CancellationError()
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
        // A reconnect can repoint the client at a DIFFERENT server (multi-server
        // switch), and the learned version stops being true then: clearing sends
        // every capability gate back to its conservative path until the
        // `fetchServerInfo` that follows re-learns it, because keeping the old
        // value would let a 12.0 feature fire against a 10.9 box.
        //
        // But a reconnect onto the SAME server is the common case — a user
        // switch (`UserSwitchSheet`) and a refused switch's rollback both go
        // through here with the URL already pointed at — and nothing re-learns
        // the version on those paths. Clearing it there left the rest of the
        // process on "version unknown", which every gate reads as *unsupported*:
        // the library Collections row, the `/Items/{id}/Collections` reverse
        // lookup, the lightweight `fetchUserData` and the UPnP row all
        // disappeared in silence on a 12.0 server after switching account. Same
        // server ⇒ same version, so it is kept. Equality is the registry's own
        // `dedupKey`, not raw `URL` equality, so a trailing slash or an
        // uppercase host doesn't read as a different server.
        let client = makeClient(url: url, accessToken: accessToken)
        withState { state in
            if !Self.isSameServer(state.serverURL, as: url) { state.serverVersion = nil }
            _ = state.install(client, url: url, accessToken: accessToken)
        }
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
    ///
    /// `urlCache = nil`: every request on this session is authenticated, and
    /// `URLSessionConfiguration.default` otherwise writes those responses to a
    /// disk-backed `URLCache` inside the app container. Jellyfin's JSON is
    /// rarely cacheable to begin with, and freshness is already owned by the
    /// app's own `APICache` (short TTLs + explicit invalidation) — so the HTTP
    /// cache bought nothing and only widened the at-rest footprint.
    ///
    /// `acceptLanguage`: the `Accept-Language` value every request carries, or
    /// `nil` for none. Jellyfin 12.0 localizes per request from it (media-stream
    /// `DisplayTitle`s, activity strings — jellyfin PR #16488); 10.x has no
    /// request-localization middleware and ignores the header, which is why
    /// this needs no `ServerVersion` gate.
    internal static func sessionConfiguration(acceptLanguage: String?) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        c.urlCache = nil
        if let acceptLanguage {
            c.httpAdditionalHeaders = ["Accept-Language": acceptLanguage]
        }
        return c
    }

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
