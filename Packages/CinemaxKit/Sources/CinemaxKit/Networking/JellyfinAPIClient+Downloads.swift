import Foundation
import JellyfinAPI

/// Request shape passed to `URLSession.downloadTask(with:)` for offline
/// downloads. Built by `JellyfinAPIClient.buildDownloadRequest` so callers
/// don't need to know about the `MediaBrowser` auth header format.
public struct DownloadStreamRequest: Sendable {
    public let itemId: String
    public let url: URL
    public let authHeader: String

    public init(itemId: String, url: URL, authHeader: String) {
        self.itemId = itemId
        self.url = url
        self.authHeader = authHeader
    }

    public func asURLRequest() -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return req
    }
}

extension JellyfinAPIClient: DownloadAPI {
    /// Negotiates an offline download URL.
    ///
    /// We POST `PlaybackInfo` with a download-specific `DeviceProfile`:
    ///   - `DirectPlayProfile`: MP4-family containers with `h264 / hevc` video
    ///     and a wide audio codec list — when the source matches, Jellyfin
    ///     hands us a static-stream URL and the bytes are the original file.
    ///   - `TranscodingProfile`: `protocol = .http`, `container = "mp4"`,
    ///     `context = .static` — when the source needs transcoding (MKV, AVI,
    ///     anything HEVC-in-Matroska), Jellyfin returns `transcodingUrl`
    ///     which is a progressive MP4 endpoint backed by a real transcoding
    ///     session keyed on `PlaySessionId`. URLSession downloads it as a
    ///     single file; once complete the `moov` atom is at EOF and AVPlayer
    ///     plays it back natively.
    ///
    /// The previous direct `/Items/{id}/Download` shortcut left MKV libraries
    /// stuck because AVPlayer can't demux Matroska. Going through PlaybackInfo
    /// lets the server do exactly the work it's there to do.
    public func buildDownloadRequest(itemId: String, userId: String) async throws -> DownloadStreamRequest {
        guard let client = getClient(), let serverURL = getServerURL() else {
            throw JellyfinError.notConnected
        }

        // Walk Series/Season → Episode if the caller handed us a non-playable id.
        let initialItem = try await getItem(userId: userId, itemId: itemId)
        let resolved = try await resolvePlayableEpisode(item: initialItem, itemId: itemId, userId: userId)
        let item = resolved.item
        let effectiveItemId = resolved.itemId
        let mediaSourceId = item.mediaSources?.first?.id

        var body = PlaybackInfoDto(deviceProfile: Self.buildDownloadDeviceProfile())
        body.isAutoOpenLiveStream = true
        body.userID = userId
        body.maxStreamingBitrate = 40_000_000
        if let mediaSourceId {
            body.mediaSourceID = mediaSourceId
        }

        let response = try await rawPostPlaybackInfo(
            serverURL: serverURL,
            itemId: effectiveItemId,
            client: client,
            body: body
        )

        let mediaSource: MediaSourceInfo? = response.mediaSources?.first(where: { $0.id == mediaSourceId })
            ?? response.mediaSources?.first
        let playSessionId = response.playSessionID
        let header = Self.buildAuthHeader(client: client)

        // Transcoding path — server hands us a session-bound progressive MP4 URL.
        if let transcodingPath = mediaSource?.transcodingURL {
            let base = serverURL.absoluteString.trimmingCharacters(in: ["/"])
            if let url = URL(string: base + transcodingPath) {
                return DownloadStreamRequest(itemId: itemId, url: url, authHeader: header)
            }
        }

        // Direct-stream path — source is already AVKit-friendly, no transcode needed.
        if let playSessionId,
           var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) {
            components.path = "/Videos/\(effectiveItemId)/stream"
            components.queryItems = [
                URLQueryItem(name: "static", value: "true"),
                URLQueryItem(name: "playSessionId", value: playSessionId),
                URLQueryItem(name: "mediaSourceId", value: mediaSource?.id ?? effectiveItemId)
            ]
            if let tag = item.etag {
                components.queryItems?.append(URLQueryItem(name: "tag", value: tag))
            }
            if let url = components.url {
                return DownloadStreamRequest(itemId: itemId, url: url, authHeader: header)
            }
        }

        // Last-resort fallback: official download endpoint. Preserves source
        // container, so the offline-playable gate in `VideoPlayerView` is what
        // catches anything AVKit can't decode.
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = "/Items/\(effectiveItemId)/Download"
        components.queryItems = [
            URLQueryItem(name: "mediaSourceId", value: mediaSource?.id ?? effectiveItemId),
            URLQueryItem(name: "deviceId", value: deviceID)
        ]
        guard let url = components.url else {
            throw JellyfinError.playbackFailed("Failed to build download URL for \(itemId)")
        }
        return DownloadStreamRequest(itemId: itemId, url: url, authHeader: header)
    }

    // MARK: - Helpers

    /// `DeviceProfile` used exclusively for offline downloads. Differs from the
    /// streaming profile in two ways:
    ///   - `TranscodingProfile.protocol = .http` (single MP4 file, not HLS
    ///     manifest + segments) so URLSession can hand the result to AVPlayer
    ///     as a single asset.
    ///   - `context = .static` — the server treats this as a download session,
    ///     emits the `moov` atom at EOF (no fast-start optimisation), and uses
    ///     `Content-Disposition: attachment` so we can detect the resulting
    ///     container from response headers.
    nonisolated(unsafe) private static let _downloadDirectPlayProfiles: [DirectPlayProfile] = [
        DirectPlayProfile(
            audioCodec: "aac,ac3,eac3,mp3,flac,alac",
            container: "mp4,m4v,mov,m4a",
            type: .video,
            videoCodec: "h264,hevc"
        )
    ]
    nonisolated(unsafe) private static let _downloadTranscodingProfiles: [TranscodingProfile] = [
        TranscodingProfile(
            audioCodec: "aac",
            isBreakOnNonKeyFrames: false,
            container: "mp4",
            context: .static,
            enableSubtitlesInManifest: false,
            maxAudioChannels: "6",
            minSegments: 0,
            protocol: .http,
            type: .video,
            videoCodec: "h264"
        )
    ]

    private static func buildDownloadDeviceProfile() -> DeviceProfile {
        DeviceProfile(
            directPlayProfiles: _downloadDirectPlayProfiles,
            maxStreamingBitrate: 40_000_000,
            transcodingProfiles: _downloadTranscodingProfiles
        )
    }

    private static func buildAuthHeader(client: JellyfinClient) -> String {
        var fields = [
            "DeviceId": client.configuration.deviceID,
            "Device": client.configuration.deviceName,
            "Client": client.configuration.client,
            "Version": client.configuration.version
        ]
        if let token = client.accessToken {
            fields["Token"] = token
        }
        return "MediaBrowser " + fields.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }
}

/// Protocol slice so the manager can depend on a narrow surface for tests.
public protocol DownloadAPI: Sendable {
    /// Negotiates a one-shot download URL for `itemId`. The returned request
    /// is fed straight to `URLSession.downloadTask(with:)`.
    func buildDownloadRequest(itemId: String, userId: String) async throws -> DownloadStreamRequest
}
