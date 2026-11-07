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

    /// Whether two addresses name the same Seerr: scheme, host, port and path,
    /// exactly, once normalized (a default port written out or not is the same
    /// port). A Seerr secret — a session cookie, an API key — is only ever sent
    /// to the address it was issued for.
    public static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs, let left = originKey(lhs), let right = originKey(rhs) else { return false }
        return left == right
    }

    private static func originKey(_ url: URL) -> String? {
        guard let normalized = normalize(url.absoluteString),
              let components = URLComponents(url: normalized, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)\(components.percentEncodedPath)"
    }
}

/// A Seerr secret (session cookie, API key) and the Seerr address it belongs
/// to. Stored together so the secret can never be sent to another address —
/// a profile's configuration pointing elsewhere makes it unusable, not leaked.
public struct SeerrBoundSecret: Codable, Equatable, Sendable {
    public let value: String
    /// The normalized address (`SeerrAddress.normalize`) it was issued for.
    public let origin: String

    public init(value: String, origin: URL) {
        self.value = value
        self.origin = origin.absoluteString
    }

    public func isBound(to url: URL?) -> Bool {
        SeerrAddress.sameOrigin(URL(string: origin), url)
    }
}

// The value must not leak through `print`, interpolation or a failed `#expect`.
extension SeerrBoundSecret: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "SeerrBoundSecret(…)" }
    public var debugDescription: String { description }
}
