import Foundation

/// Where and as whom to open Jellyfin's realtime `/socket` — the one value
/// `JellyfinSocketHub` needs to decide whether the live connection is still
/// the right one.
///
/// **The token rides in the `Authorization` header, not the URL** (audit
/// 2026-09-22, S7). A WebSocket upgrade is an ordinary HTTP request, so it
/// carries headers like any other — the old comment claiming « a socket has no
/// header » was wrong — and Jellyfin's socket middleware authenticates the
/// upgrade through the same `AuthorizationContext` as every REST call (10.9 →
/// 12.0). A token in the URL, by contrast, lands in reverse-proxy access logs.
/// The `ApiKey` query item survives only as a FALLBACK, for a server or a
/// proxy that refuses the header (see `RealtimeSocketAuth`).
///
/// **Identity is explicit, never `URL` equality.** It used to be the tokenised
/// URL itself, which bundled the token into the key by accident. Two endpoints
/// name the same connection when their socket URL (scheme, host, port, base
/// path, device id — no token in it any more) and their TOKEN are equal. The
/// user is compared THROUGH the token: Jellyfin binds each access token to
/// exactly one user, and the client holds no separate user id — a re-login,
/// a user switch or a server switch all change one of the two.
public struct RealtimeSocketEndpoint: Sendable {
    /// `ws(s)://host[/base]/socket?deviceId=…` — carries no token.
    public let url: URL
    let token: String
    /// The same `MediaBrowser …, Token=…` header the REST calls send.
    let authorization: String

    public init(url: URL, token: String, authorization: String) {
        self.url = url
        self.token = token
        self.authorization = authorization
    }

    /// Whether `other` names the connection this endpoint is already served by.
    public func isSameConnection(as other: RealtimeSocketEndpoint) -> Bool {
        url == other.url && token == other.token
    }

    /// The upgrade request. The header is always sent; `queryAuth` adds the
    /// token as an `ApiKey` query item too, for a server that refused the header.
    func request(queryAuth: Bool) -> URLRequest {
        var target = url
        if queryAuth, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // `ApiKey`, never the legacy `api_key`: rejected once Jellyfin
            // 12.0's `EnableLegacyAuthorization = false` default applies.
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "ApiKey", value: token)]
            target = components.url ?? url
        }
        var request = URLRequest(url: target)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }
}

/// When the socket gives up on the header and falls back to the query item.
public enum RealtimeSocketAuth {
    /// Header-mode upgrades the server ANSWERED without a 401 / 403 (a proxy
    /// rejecting the header form with a 400, say) and without any frame, after
    /// which the token is tried in the URL. An attempt that never reached the
    /// server is not counted by the caller: it says nothing about auth.
    public static let headerAttemptsBeforeFallback = 2

    /// Whether the next attempt should carry the token in the URL.
    ///
    /// Only while the header has NEVER worked on this socket: once a frame
    /// arrived, a later drop is the network, not the authentication. A 401 /
    /// 403 on the upgrade falls back at once; another answered refusal counts
    /// toward `headerAttemptsBeforeFallback`.
    public static func shouldFallBackToQuery(
        usingQuery: Bool,
        headerEverWorked: Bool,
        statusCode: Int?,
        failedHeaderAttempts: Int
    ) -> Bool {
        guard !usingQuery, !headerEverWorked else { return false }
        if statusCode == 401 || statusCode == 403 { return true }
        return failedHeaderAttempts >= headerAttemptsBeforeFallback
    }
}
