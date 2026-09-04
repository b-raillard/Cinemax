import Foundation

/// One of the server's known languages, as the preference pickers offer it.
///
/// A scalars-only value type rather than the SDK's `CultureDto`: the pickers
/// are `@MainActor` and the fetch is not, so a non-`Sendable` SDK type crossing
/// that boundary would be a region transfer — the same discipline
/// `RemoteImageCandidate` and `CardPlayTarget` follow.
public struct ServerCulture: Sendable, Hashable, Identifiable {
    /// The two-letter ISO code `UserConfiguration` stores.
    public let code: String
    /// What the server calls it, in its own locale.
    public let displayName: String

    public var id: String { code }

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }
}

/// The slice of the signed-in user's Jellyfin `UserConfiguration` this app
/// surfaces.
///
/// Deliberately NOT the whole DTO: the server holds a dozen fields this app has
/// no opinion about (grouped folders, latest-items exclusions, the web client's
/// own layout), and round-tripping them through a model of our own would let a
/// field we never show be silently reset by a save. The client reads the
/// server's configuration, changes only these fields and posts it back — so
/// everything else survives untouched.
///
/// The server honours these in `PlaybackInfo`, which is what makes them worth
/// setting from here at all rather than being a second, client-side preference
/// that disagrees with every other Jellyfin client.
public struct UserPlaybackPreferences: Sendable, Equatable {
    /// Two-letter ISO code, or `nil` for "no preference — server default".
    public var audioLanguage: String?
    public var subtitleLanguage: String?
    /// When subtitles are shown at all.
    public var subtitleMode: SubtitleMode

    public enum SubtitleMode: String, Sendable, CaseIterable, Identifiable {
        case defaultTrack = "Default"
        case smart = "Smart"
        case onlyForced = "OnlyForced"
        case always = "Always"
        case none = "None"

        public var id: String { rawValue }
    }

    public init(
        audioLanguage: String? = nil,
        subtitleLanguage: String? = nil,
        subtitleMode: SubtitleMode = .defaultTrack
    ) {
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
        self.subtitleMode = subtitleMode
    }
}
