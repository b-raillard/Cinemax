import Foundation

/// Canonical spelling of a Seerr address typed (or pasted) by the user.
///
/// Rules, on top of `ServerURLNormalizer`'s (lowercase scheme + host, http(s)
/// only, default port dropped, trailing `/`, query, fragment and user info
/// stripped, **sub-path preserved** — Seerr behind `https://host/seerr` must
/// work):
/// - no scheme ⇒ `http://`, not `https://` as for Jellyfin: Seerr listens in
///   plain HTTP on 5055, and a public address is pasted whole from the browser,
///   scheme included;
/// - a pasted `/api/v1` suffix is removed — the client appends it itself.
public enum SeerrAddress {
    private static let apiPrefix = "/api/v1"

    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A bare `host:port` through `URL(string:)` reads the host as the scheme.
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        // The `URL` overload: the `String` one would prepend `https://`.
        guard let url = URL(string: candidate),
              let normalized = ServerURLNormalizer.normalize(url),
              var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false)
        else { return nil }
        // The normalizer already removed trailing slashes, so one suffix test
        // covers `/api/v1` and `/api/v1/`.
        let path = components.percentEncodedPath
        if path.lowercased().hasSuffix(apiPrefix) {
            components.percentEncodedPath = String(path.dropLast(apiPrefix.count))
        }
        return components.url
    }
}
