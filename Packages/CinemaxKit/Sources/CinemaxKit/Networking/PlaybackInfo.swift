import Foundation

/// Playback info returned after negotiating streaming parameters with the Jellyfin server.
public struct PlaybackInfo: Sendable {
    public let url: URL
    public let playSessionId: String?
    public let mediaSourceId: String?
    public let playMethod: PlayMethod
    public let audioTracks: [MediaTrackInfo]
    public let subtitleTracks: [MediaTrackInfo]
    public let selectedAudioIndex: Int?    // default or caller-requested audio stream index
    public let selectedSubtitleIndex: Int? // default or caller-requested subtitle index (-1 = off)
    /// Access token for Authorization header injection into AVURLAsset.
    /// Nil for transcoding URLs where Jellyfin already embeds the token in the path.
    public let authToken: String?

    public init(
        url: URL,
        playSessionId: String?,
        mediaSourceId: String?,
        playMethod: PlayMethod,
        audioTracks: [MediaTrackInfo],
        subtitleTracks: [MediaTrackInfo],
        selectedAudioIndex: Int?,
        selectedSubtitleIndex: Int?,
        authToken: String?
    ) {
        self.url = url
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.playMethod = playMethod
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.selectedAudioIndex = selectedAudioIndex
        self.selectedSubtitleIndex = selectedSubtitleIndex
        self.authToken = authToken
    }
}
