import Foundation

/// A parsed Jellyfin server version, ordered numerically.
///
/// Exists because feature gating had no home: `ServerInfo.version` was stored
/// but never *read* to decide anything, so the one version-dependent call in
/// the app (`getCollections`' post-10.11 reverse lookup) probed the new
/// endpoint on every server and ate a 404 round-trip on older ones. Anything
/// that depends on a server capability should ask this type instead.
///
/// String comparison is not an option — `"10.9" > "10.10"` lexicographically —
/// so every component is compared as an integer.
public struct ServerVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let build: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0, _ build: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.build = build
    }

    /// Parses a version reported by `/System/Info/Public`. Accepts the 2-to-4
    /// component forms Jellyfin emits (`10.10`, `10.10.7`, `10.8.13.0`), an
    /// optional `v` prefix, and any pre-release / build suffix (`10.11.0-rc1`),
    /// which is truncated rather than rejected — a release candidate carries the
    /// capabilities of its release, and refusing to parse it would silently
    /// disable every gated feature for testers.
    ///
    /// Returns `nil` only when no leading integer can be read at all, so callers
    /// can treat `nil` as "unknown server" and stay on the conservative path.
    public init?(_ raw: String) {
        var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        // Stop at the first character that is neither a digit nor a separator,
        // which drops `-rc1` / `+build` suffixes without special-casing them.
        let core = text.prefix { $0.isNumber || $0 == "." }

        var values: [Int] = []
        for component in core.split(separator: ".", omittingEmptySubsequences: false) {
            // Break rather than fail: a trailing empty component (left behind by
            // a stripped suffix, e.g. `10.10.` from `10.10.beta`) must not throw
            // away the components already read.
            guard values.count < 4, let value = Int(component) else { break }
            values.append(value)
        }

        guard let major = values.first else { return nil }
        self.major = major
        self.minor = values.count > 1 ? values[1] : 0
        self.patch = values.count > 2 ? values[2] : 0
        self.build = values.count > 3 ? values[3] : 0
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.build) < (rhs.major, rhs.minor, rhs.patch, rhs.build)
    }

    public var description: String { "\(major).\(minor).\(patch).\(build)" }
}

// MARK: - Capability thresholds

public extension ServerVersion {
    /// Minimum server version exposing `GET /UserItems/{id}/UserData`, the
    /// lightweight per-item userData read used instead of re-fetching a whole
    /// `BaseItemDto` after playback.
    static let itemUserDataEndpoint = ServerVersion(10, 10)

    /// Whether this server is at least `required`. Reads better at call sites
    /// than a bare `>=` against a constant whose meaning isn't obvious.
    func supports(_ required: ServerVersion) -> Bool { self >= required }
}
