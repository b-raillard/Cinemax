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

    public init(id: Int, label: String, isDefault: Bool, isForced: Bool) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
        self.isForced = isForced
    }
}
