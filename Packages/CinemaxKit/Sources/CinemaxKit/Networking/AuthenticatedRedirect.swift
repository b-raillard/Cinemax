import Foundation

/// Whether an authenticated request may follow a redirect.
///
/// URLSession follows a 3xx by copying the ORIGINAL request's headers onto the
/// new one — `Authorization` included — whatever host the `Location` names. A
/// reverse proxy, a captive portal or a compromised server answering
/// `302 Location: https://elsewhere/` would therefore receive the account
/// token (audit 2026-09-22, S11).
///
/// A request that carries the token (a credential header or an `ApiKey`
/// query item) is therefore NOT FOLLOWED off its origin: the 3xx comes back as
/// the response, an ordinary non-2xx error. Stripping the credentials and
/// following instead was tried and rejected: every call would reach the other
/// host unauthenticated, answer 401, and the session-expiry coordinator would
/// sign the user out of a server that is merely redirecting. A request with no
/// credentials follows wherever it is sent.
///
/// « Same origin » is the same host on the same port and scheme — plus one
/// exception: an upgrade to a secure scheme on the SAME host keeps the token
/// whatever the port, which is exactly Jellyfin's own « Require HTTPS »
/// redirect (`http://nas:8096` → `https://nas:8920`). A secure → clear
/// downgrade never keeps it (that would send the token in clear on the wire).
public enum AuthenticatedRedirect {
    /// Every header this app, `Get` or the SDK uses to carry the token.
    static let credentialHeaders = [
        "Authorization", "X-Emby-Authorization", "X-Emby-Token", "X-MediaBrowser-Token",
    ]

    /// Query items that carry the token in a URL (`authedURL`, the server's own
    /// `TranscodingUrl`, the legacy spelling), compared case-insensitively.
    static let credentialQueryItems: Set<String> = ["apikey", "api_key"]

    private static let secureSchemes: Set<String> = ["https", "wss"]

    /// Whether credentials may ride from `from` (the URL that answered 3xx) to
    /// `to` (its `Location`).
    public static func keepsCredentials(from: URL?, to: URL?) -> Bool {
        guard let from, let to,
              let fromHost = from.host?.lowercased(), !fromHost.isEmpty,
              let toHost = to.host?.lowercased(), fromHost == toHost else { return false }
        let fromScheme = from.scheme?.lowercased() ?? ""
        let toScheme = to.scheme?.lowercased() ?? ""
        let fromSecure = secureSchemes.contains(fromScheme)
        let toSecure = secureSchemes.contains(toScheme)
        if fromSecure && !toSecure { return false }
        if !fromSecure && toSecure { return true }
        return fromScheme == toScheme && port(of: from) == port(of: to)
    }

    /// Whether `request` carries the token at all.
    static func carriesCredentials(_ request: URLRequest) -> Bool {
        if credentialHeaders.contains(where: { request.value(forHTTPHeaderField: $0) != nil }) { return true }
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.contains { credentialQueryItems.contains($0.name.lowercased()) }
    }

    /// The request to follow after a redirect from `from`, or `nil` to stop
    /// there and hand the 3xx back.
    public static func followed(_ request: URLRequest, redirectedFrom from: URL?) -> URLRequest? {
        guard carriesCredentials(request) else { return request }
        return keepsCredentials(from: from, to: request.url) ? request : nil
    }

    private static func port(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }
}
