import Foundation

/// Server-wide kill-switch for the offline-downloads feature.
///
/// Jellyfin has no native *global* "allow downloads" setting (only the
/// per-user `UserPolicy.enableContentDownloading`), so the global flag is
/// persisted as an inert CSS comment inside the server's Branding
/// `CustomCss`. That store was chosen deliberately:
///   * **Readable by every user** — `GET /Branding/Configuration` is a
///     public endpoint (the web login page consumes it pre-auth), so a
///     non-admin client can evaluate the flag without elevation.
///   * **Writable only by admins** — `POST /System/Configuration/branding`
///     requires elevation, so a regular user can't turn the feature on.
///   * **Inert** — a CSS comment renders nothing in Jellyfin web; the only
///     side effect of flipping the flag is the marker line itself.
///   * **Fail-safe** — a missing marker (fresh server, admin wiped their
///     custom CSS from the dashboard) reads as *disabled*, which is the
///     safe default for App Store review.
public enum OfflineFeatureFlag {
    /// Token searched for in `CustomCss`. Kept format-agnostic (the whole
    /// line is stripped on rewrite, however the comment was formatted).
    public static let markerToken = "cinemax:offline-downloads=on"

    /// Canonical marker line written when enabling the flag.
    public static let markerLine = "/* cinemax:offline-downloads=on */"

    /// Whether the global flag is set in the given Branding `CustomCss`.
    public static func isEnabled(customCss: String?) -> Bool {
        customCss?.contains(markerToken) ?? false
    }

    /// Returns `customCss` rewritten so the marker's presence matches
    /// `enabled`, preserving any admin-authored CSS. Removal is line-based
    /// (any line containing the token goes) so a hand-edited marker with
    /// different comment formatting is still cleaned up.
    public static func applying(enabled: Bool, to customCss: String?) -> String {
        var lines = (customCss ?? "")
            .components(separatedBy: "\n")
            .filter { !$0.contains(markerToken) }
        // Collapse a leading blank left behind by a stripped marker line.
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        if enabled {
            lines.insert(markerLine, at: 0)
        }
        return lines.joined(separator: "\n")
    }
}
