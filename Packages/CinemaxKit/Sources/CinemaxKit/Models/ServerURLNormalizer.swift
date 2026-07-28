import Foundation

/// Canonical spelling of a Jellyfin server URL.
///
/// Single source of truth for two things that must never disagree:
/// 1. the URL we store in a `ServerEntry` / hand to `JellyfinAPIClient`, and
/// 2. the key we dedup on ("is this server already registered?").
///
/// Rules — lowercase scheme + host; `http`/`https` only; drop the default port
/// (`:443` on https, `:80` on http); strip a trailing `/`; drop query, fragment,
/// user and password. **Any sub-path is preserved** (`https://host/jellyfin`):
/// reverse-proxy sub-path hosting is load-bearing everywhere in this app (see
/// the `URLComponents+ServerPath` RULE) and dropping it would 404 every
/// hand-built URL.
public enum ServerURLNormalizer {

    /// Normalizes raw user input. Prepends `https://` when no scheme is typed —
    /// the behavior `ServerSetupScreen` has always had. Returns `nil` for input
    /// that isn't a usable http(s) server URL.
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }
        guard let url = URL(string: candidate) else { return nil }
        return normalize(url)
    }

    public static func normalize(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }

        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        if let port = components.port,
           (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
            components.port = nil
        }

        // Trailing slashes only — the rest of the path is the server's base
        // path and must survive untouched.
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path

        return components.url
    }

    /// Equivalence-class key for dedup. Two spellings of the same server
    /// (trailing slash, uppercase host, explicit `:443`) share one key.
    /// Falls back to the raw absolute string when the URL can't be normalized,
    /// so a stored oddity still compares equal to itself.
    public static func dedupKey(_ url: URL) -> String {
        (normalize(url) ?? url).absoluteString
    }
}
