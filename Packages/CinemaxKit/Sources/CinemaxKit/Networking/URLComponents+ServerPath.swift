import Foundation

extension URLComponents {
    /// Sets the request path while PRESERVING the server's base path.
    ///
    /// `components.path = "/Videos/…"` REPLACES the whole path, silently
    /// dropping the sub-path of a server hosted at e.g.
    /// `https://host/jellyfin` (a common reverse-proxy layout) — every URL
    /// built that way 404s on such servers while SDK-routed calls (which
    /// resolve relative to the configured base URL) keep working, leaving the
    /// app half-broken. Always route hand-built endpoint paths through this
    /// helper instead of assigning `path` directly.
    mutating func setEndpointPath(_ endpoint: String, preservingBasePathOf serverURL: URL) {
        let base = serverURL.path
        if base.isEmpty || base == "/" {
            path = endpoint
        } else {
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            path = trimmed + endpoint
        }
    }
}
