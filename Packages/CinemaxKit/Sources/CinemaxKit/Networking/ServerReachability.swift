import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cinemax", category: "Servers")

/// Result of a lightweight, unauthenticated server probe.
public enum PingResult: Sendable, Equatable {
    /// Reachable. `name` / `version` are opportunistic — the server list uses
    /// them to self-heal entries whose metadata is stale or was never fetched.
    case online(name: String?, version: String?)
    case offline
}

/// Standalone reachability probe for a registered (possibly NON-active) server.
///
/// **RULE — this must never touch the shared session machinery.** It hits the
/// *unauthenticated* `GET /System/Info/Public` on its own `URLSession`, with no
/// auth header and no `JellyfinAPIClient` involvement, so:
/// - a 401 is structurally impossible → `notifyIfUnauthorized` /
///   `.cinemaxSessionExpired` can never fire from here, and a dead or
///   misconfigured secondary server can't log the user out of the ACTIVE one;
/// - the active client's base URL / token are never reconfigured by a probe.
///
/// Bounded by a short timeout with `waitsForConnectivity = false` so pinging N
/// servers on screen load can never block first paint.
public enum ServerReachability {

    /// Short leash: this drives a status dot, not a user-visible operation.
    public static let probeTimeout: TimeInterval = 4

    public static func ping(url: URL, session: URLSession? = nil) async -> PingResult {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .offline }
        // Preserve a reverse-proxy base path — assigning `path` directly would
        // drop `/jellyfin` and 404 every sub-path-hosted server.
        components.setEndpointPath("/System/Info/Public", preservingBasePathOf: url)
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else { return .offline }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = probeTimeout
        // This request IS the liveness check — a cached 200 would paint a green
        // dot on a server that is already dead. Belt-and-braces with the
        // session's `urlCache = nil` (an injected test session, or a future
        // config change, must not be able to re-introduce a cached answer).
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await (session ?? probeSession).data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return .offline }
            let info = try? JSONDecoder().decode(PublicSystemInfoLite.self, from: data)
            return .online(name: info?.serverName, version: info?.version)
        } catch {
            return .offline
        }
    }

    /// Minimal shape of `/System/Info/Public` — decoded opportunistically, so a
    /// server that omits either field still reports `.online`.
    private struct PublicSystemInfoLite: Decodable {
        let serverName: String?
        let version: String?

        private enum CodingKeys: String, CodingKey {
            case serverName = "ServerName"
            case version = "Version"
        }
    }

    /// Dedicated session: `URLSession.shared`'s 60 s default would let a
    /// black-holed host hold a status dot spinning long after the user left.
    ///
    /// `urlCache = nil` + `reloadIgnoringLocalCacheData`: `.ephemeral` still
    /// installs an in-memory `URLCache`, and `/System/Info/Public` is exactly
    /// the kind of static response a server (or a reverse proxy in front of it)
    /// will mark cacheable — a replayed 200 would then keep the status dot
    /// green long after the host went down, which defeats the whole probe.
    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = probeTimeout
        configuration.timeoutIntervalForResource = probeTimeout
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

/// Best-effort server-side session revocation for a registered server.
///
/// Used when the user deletes a server entry or signs out: the device's session
/// should disappear from the Jellyfin dashboard, not linger. Like
/// `ServerReachability` this is **standalone** — a hand-built request on its own
/// `URLSession`, never the shared `JellyfinAPIClient` — so revoking a *secondary*
/// server can't reconfigure the active client or feed the 401 machinery.
///
/// The request mirrors the auth discipline documented in
/// `JellyfinAPIClient+SyncPlay.swift`: `MediaBrowser` authorization header,
/// `setEndpointPath` to preserve a reverse-proxy base path, bounded timeout.
/// The result is deliberately **ignored** — the local entry is dropped either
/// way; a server that is offline or has already revoked the token must not block
/// or fail the user's action.
public enum ServerSessionRevoker {

    public static let requestTimeout: TimeInterval = 6

    public static func revoke(
        url: URL,
        accessToken: String,
        deviceId: String,
        session: URLSession? = nil
    ) async {
        guard !accessToken.isEmpty, !deviceId.isEmpty else { return }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.setEndpointPath("/Devices", preservingBasePathOf: url)
        components.fragment = nil
        components.queryItems = [URLQueryItem(name: "id", value: deviceId)]
        guard let endpoint = components.url else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue(authorizationHeader(accessToken: accessToken, deviceId: deviceId),
                         forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        do {
            _ = try await (session ?? revokeSession).data(for: request)
        } catch {
            // Best effort by design — the entry is removed locally regardless.
            logger.debug("Session revoke failed for \(redactedURL(endpoint), privacy: .public)")
        }
    }

    /// Same `MediaBrowser` header the SDK builds, assembled here from explicit
    /// values because the target server is not (necessarily) the one the shared
    /// client is pointed at — reading the client's configuration would revoke
    /// against the wrong server.
    private static func authorizationHeader(accessToken: String, deviceId: String) -> String {
        let fields = [
            "DeviceId": deviceId,
            "Device": deviceName,
            "Client": "Cinemax",
            "Version": appVersion,
            "Token": accessToken
        ]
        let joined = fields.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return "MediaBrowser \(joined)"
    }

    private static var deviceName: String {
        #if os(tvOS)
        "Apple TV"
        #elseif os(iOS)
        "iPhone"
        #else
        "Apple Device"
        #endif
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// Own session for the same reason `ServerReachability` keeps one: bounded
    /// timeouts, and never the app-wide shared pool. `urlCache = nil` because
    /// this request carries the account's `MediaBrowser Token=…` header — the
    /// same at-rest discipline as `fastFailSessionConfiguration`.
    private static let revokeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
