import Foundation

/// Which client-side playback engine will consume the stream. Drives the
/// `DeviceProfile` sent in the PlaybackInfo negotiation:
/// - `.vlc` advertises broad DirectPlay (any container) so Jellyfin serves the
///   raw file with **no transcode** — VLC decodes MKV/HEVC/Dolby Vision natively.
/// - `.native` advertises the AVFoundation-safe profile (mp4/mov + HLS
///   transcode fallback) for `AVPlayer`/AVKit.
public enum VideoPlaybackEngine: String, Sendable {
    case vlc
    case native
}

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
    /// Access token for Authorization header injection (AVURLAsset, the VLC
    /// loopback proxy). Never part of `url`: the VLC path appends it as `ApiKey`
    /// only on a direct retry (`VLCStreamPresenter.streamURL`).
    /// Nil for transcoding URLs where Jellyfin already embeds the token in the path.
    public let authToken: String?
    /// Source container as the server reports it (e.g. "avi", "mkv"), for
    /// DirectPlay/DirectStream only. Lets the player route seek-heavy /
    /// non-streaming-friendly containers (AVI keeps its index at EOF, so libVLC
    /// floods the server with range requests and can trip a reverse proxy)
    /// through the loopback proxy, which bounds concurrency. Nil ⇒ unknown / not
    /// applicable (transcode/HLS).
    public let sourceContainer: String?
    /// Live stream the server opened for this session — every PlaybackInfo
    /// negotiation asks for one (`isAutoOpenLiveStream=true`). Handed back in
    /// the stop report so the server releases it; without that the resource
    /// lingers until the server expires it on its own. Nil when no negotiation
    /// took place (the direct-stream fallback never talks to the server).
    public let liveStreamId: String?
    /// Size of the source file in bytes, as the server reports it — DirectPlay
    /// / DirectStream only, nil for a transcode (no file to size) and for the
    /// fallback that never negotiates. Read by the player's feed watchdog: a
    /// source whose every byte has already been read legitimately stops the
    /// input for the rest of the playback (a short trailer buffers whole), so
    /// without this the watchdog would read that as a dead feed.
    public let sourceSizeBytes: Int64?

    public init(
        url: URL,
        playSessionId: String?,
        mediaSourceId: String?,
        playMethod: PlayMethod,
        audioTracks: [MediaTrackInfo],
        subtitleTracks: [MediaTrackInfo],
        selectedAudioIndex: Int?,
        selectedSubtitleIndex: Int?,
        authToken: String?,
        sourceContainer: String? = nil,
        liveStreamId: String? = nil,
        sourceSizeBytes: Int64? = nil
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
        self.sourceContainer = sourceContainer
        self.liveStreamId = liveStreamId
        self.sourceSizeBytes = sourceSizeBytes
    }
}
