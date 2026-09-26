import Foundation

/// What a redirect may carry forward from an authenticated request.
///
/// URLSession follows a 3xx by copying the ORIGINAL request's headers onto the
/// new one — `Authorization` included — whatever host the `Location` names. A
/// reverse proxy, a captive portal or a compromised server answering
/// `302 Location: https://elsewhere/` would therefore receive the account
/// token (audit 2026-09-22, S11). The redirect is still FOLLOWED — a `.strm`
/// item legitimately bounces to another host, and refusing would turn that
/// into a playback failure — but without the credentials, the way a browser
/// drops `Authorization` on a cross-origin redirect.
///
/// Credentials survive only onto the SAME host, and never from a secure scheme
/// to a clear one (that would send the token in clear on the wire).
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
        guard let fromHost = from?.host?.lowercased(), !fromHost.isEmpty,
              let toHost = to?.host?.lowercased(), fromHost == toHost else { return false }
        let fromSecure = secureSchemes.contains(from?.scheme?.lowercased() ?? "")
        let toSecure = secureSchemes.contains(to?.scheme?.lowercased() ?? "")
        return !(fromSecure && !toSecure)
    }

    /// `request` as it may be followed after a redirect from `from`: untouched
    /// when credentials may ride along, otherwise stripped of the token headers
    /// and of any token query item the `Location` repeated.
    public static func sanitized(_ request: URLRequest, redirectedFrom from: URL?) -> URLRequest {
        guard !keepsCredentials(from: from, to: request.url) else { return request }
        var stripped = request
        for header in credentialHeaders where stripped.value(forHTTPHeaderField: header) != nil {
            stripped.setValue(nil, forHTTPHeaderField: header)
        }
        if let url = stripped.url,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems,
           items.contains(where: { credentialQueryItems.contains($0.name.lowercased()) }) {
            let kept = items.filter { !credentialQueryItems.contains($0.name.lowercased()) }
            components.queryItems = kept.isEmpty ? nil : kept
            stripped.url = components.url ?? url
        }
        return stripped
    }
}
