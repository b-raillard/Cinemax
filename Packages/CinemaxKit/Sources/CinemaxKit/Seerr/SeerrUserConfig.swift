import Foundation
import JellyfinAPI

/// The per-user Seerr configuration, stored on the Jellyfin server in a
/// dedicated DisplayPreferences entity (`customPrefs`) so it follows the
/// account across devices.
public struct SeerrUserConfig: Equatable, Sendable {
    public var isEnabled: Bool
    public var url: URL?

    public init(isEnabled: Bool, url: URL?) {
        self.isEnabled = isEnabled
        self.url = url
    }

    public static let preferencesId = "jellyglass-seerr"
    public static let client = "jellyglass"

    static let enabledKey = "seerr.enabled"
    static let urlKey = "seerr.url"

    /// Enabled only for the exact string `"true"`; an unparsable address is nil.
    public static func read(_ dto: DisplayPreferencesDto?) -> Self {
        let prefs = dto?.customPrefs ?? [:]
        return Self(
            isEnabled: prefs[enabledKey] == "true",
            url: prefs[urlKey].flatMap(SeerrAddress.normalize)
        )
    }

    /// The DTO to POST back: the POST replaces the whole entity, and Jellyfin
    /// injects legacy keys into `customPrefs` it resets when they are omitted,
    /// so every key but ours is carried over untouched.
    public static func merged(_ config: Self, into dto: DisplayPreferencesDto?) -> DisplayPreferencesDto {
        var result = dto ?? DisplayPreferencesDto()
        var prefs = result.customPrefs ?? [:]
        if config.isEnabled { prefs[enabledKey] = "true" } else { prefs.removeValue(forKey: enabledKey) }
        if let url = config.url { prefs[urlKey] = url.absoluteString } else { prefs.removeValue(forKey: urlKey) }
        result.customPrefs = prefs
        result.id = preferencesId
        result.client = client
        return result
    }
}
