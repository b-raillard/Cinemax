import Foundation

/// A single audio or subtitle track from a Jellyfin media source.
///
/// The `id` maps to Jellyfin's `AudioStreamIndex` / `SubtitleStreamIndex` — used when
/// requesting a new `PlaybackInfo` to switch the active track server-side.
public struct MediaTrackInfo: Identifiable, Equatable, Sendable {
    public let id: Int          // stream index (AudioStreamIndex / SubtitleStreamIndex)
    public let label: String    // Jellyfin DisplayTitle, e.g. "English - AAC - Stereo"
    public let isDefault: Bool
    public let isForced: Bool
    /// Jellyfin's raw codec name, lowercased by the server (`truehd`, `dts`,
    /// `ac3`, `eac3`…). Carried because the *engine*, not the server, decides
    /// whether a track can actually be heard: libVLC on Apple cannot output
    /// TrueHD, so `AudioTrackPolicy` needs the codec to refuse it as an
    /// automatic default. Nil when the server reported none.
    public let codec: String?
    /// Track language as the server reports it (`fre`, `eng`, `fr-FR`…).
    /// Used to keep the language when a default has to be replaced.
    public let language: String?

    public init(
        id: Int,
        label: String,
        isDefault: Bool,
        isForced: Bool,
        codec: String? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
        self.isForced = isForced
        self.codec = codec
        self.language = language
    }
}
