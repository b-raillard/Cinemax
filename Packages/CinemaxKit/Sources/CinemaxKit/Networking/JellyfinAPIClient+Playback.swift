import Foundation
import JellyfinAPI

extension JellyfinAPIClient {
    // MARK: - Playback

    /// Builds the best streaming URL for the given item.
    /// Follows Swiftfin's exact flow:
    /// 1. Get full item → extract initial media source
    /// 2. POST PlaybackInfo with device profile
    /// 3. Build stream URL from response (transcodingURL or direct stream)
    public func getPlaybackInfo(itemId: String, userId: String, maxBitrate: Int = 40_000_000, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil) async throws -> PlaybackInfo {
        guard let client = getClient(),
              let serverURL = getServerURL() else {
            throw JellyfinError.notConnected
        }

        let token = client.configuration.accessToken

        // Step 1: Get full item details (same as Swiftfin's getFullItem)
        var item = try await getItem(userId: userId, itemId: itemId)
        var effectiveItemId = itemId

        #if DEBUG
        debugLog("Item '\(item.name ?? "?")': type=\(item.type?.rawValue ?? "nil"), mediaSources=\(item.mediaSources?.count ?? 0)")
        #endif

        // If this is a Series or Season, resolve to a playable episode
        if item.type == .series {
            let resolvedId: String
            if let nextEp = try await getNextUp(seriesId: itemId, userId: userId),
               let epId = nextEp.id {
                resolvedId = epId
                #if DEBUG
                debugLog("Resolved Series → next up episode (\(epId))")
                #endif
            } else {
                // No next up — try first episode of first season
                let seasons = try await getSeasons(seriesId: itemId, userId: userId)
                guard let firstSeason = seasons.first, let seasonId = firstSeason.id else {
                    throw JellyfinError.playbackFailed("No episodes available")
                }
                let episodes = try await getEpisodes(seriesId: itemId, seasonId: seasonId, userId: userId)
                guard let firstEp = episodes.first, let firstEpId = firstEp.id else {
                    throw JellyfinError.playbackFailed("No episodes available")
                }
                resolvedId = firstEpId
                #if DEBUG
                debugLog("Resolved Series → first episode (\(firstEpId))")
                #endif
            }
            item = try await getItem(userId: userId, itemId: resolvedId)
            effectiveItemId = resolvedId
        } else if item.type == .season {
            guard let seriesId = item.seriesID else {
                throw JellyfinError.playbackFailed("No series ID for season")
            }
            let episodes = try await getEpisodes(seriesId: seriesId, seasonId: itemId, userId: userId)
            guard let firstEp = episodes.first, let firstEpId = firstEp.id else {
                throw JellyfinError.playbackFailed("No episodes in this season")
            }
            item = try await getItem(userId: userId, itemId: firstEpId)
            effectiveItemId = firstEpId
            #if DEBUG
            debugLog("Resolved Season → first episode (\(firstEpId))")
            #endif
        }

        let initialMediaSource = item.mediaSources?.first
        let initialMediaSourceId = initialMediaSource?.id

        #if DEBUG
        debugLog("Playback item '\(item.name ?? "?")': type=\(item.type?.rawValue ?? "nil"), mediaSources=\(item.mediaSources?.count ?? 0)")
        if let src = initialMediaSource {
            debugLog("  source: id=\(src.id ?? "nil"), container=\(src.container ?? "nil")")
            for s in src.mediaStreams ?? [] {
                debugLog("  stream: type=\(s.type?.rawValue ?? "?"), codec=\(s.codec ?? "?")")
            }
        } else {
            debugLog("  No media sources from getItem")
        }
        #endif

        // Step 2: POST PlaybackInfo (matching Swiftfin exactly)
        var body = PlaybackInfoDto(deviceProfile: Self.buildAppleDeviceProfile(maxBitrate: maxBitrate))
        body.isAutoOpenLiveStream = true
        body.maxStreamingBitrate = maxBitrate
        body.userID = userId
        body.audioStreamIndex = audioStreamIndex
        body.subtitleStreamIndex = subtitleStreamIndex
        if let initialMediaSourceId {
            body.mediaSourceID = initialMediaSourceId
        }

        #if DEBUG
        debugLog("POST /Items/\(effectiveItemId)/PlaybackInfo (mediaSourceId=\(initialMediaSourceId ?? "nil"))")
        #endif

        // Use raw URLSession POST to capture the full 500 error body for diagnosis
        let response: PlaybackInfoResponse
        do {
            response = try await rawPostPlaybackInfo(
                serverURL: serverURL,
                itemId: effectiveItemId,
                client: client,
                body: body
            )
        } catch {
            #if DEBUG
            debugLog("POST PlaybackInfo failed: \(error) — using direct stream fallback")
            #endif
            return buildDirectStreamURL(
                itemId: effectiveItemId, serverURL: serverURL, token: token, etag: item.etag
            )
        }

        // Step 3: Find matching media source in response (same matching as Swiftfin)
        let mediaSource: MediaSourceInfo? = {
            guard let sources = response.mediaSources else { return nil }
            if let etag = initialMediaSource?.eTag,
               let match = sources.first(where: { $0.eTag == etag }) { return match }
            if let id = initialMediaSourceId,
               let match = sources.first(where: { $0.id == id }) { return match }
            return sources.first
        }()

        guard let mediaSource else {
            #if DEBUG
            debugLog("No media source in PlaybackInfo response — using direct stream fallback")
            #endif
            return buildDirectStreamURL(
                itemId: effectiveItemId, serverURL: serverURL, token: token, etag: item.etag
            )
        }

        let playSessionId = response.playSessionID

        #if DEBUG
        debugLog("PlaybackInfo OK: playSession=\(playSessionId ?? "nil")")
        debugLog("  source: id=\(mediaSource.id ?? "nil"), container=\(mediaSource.container ?? "nil")")
        debugLog("  directPlay=\(mediaSource.isSupportsDirectPlay ?? false), directStream=\(mediaSource.isSupportsDirectStream ?? false)")
        debugLog("  transcodingURL=\(redactedURL(mediaSource.transcodingURL))")
        #endif

        // Step 4: Build stream URL (same logic as Swiftfin's streamURL)

        // Option A: Server returned a transcoding URL — use it directly
        if let transcodingPath = mediaSource.transcodingURL {
            let baseURL = serverURL.absoluteString.trimmingCharacters(in: ["/"])
            if let url = URL(string: baseURL + transcodingPath) {
                #if DEBUG
                debugLog("Transcode URL: \(redactedURL(url))")
                #endif
                let (audioTracks, subtitleTracks) = Self.extractTracks(from: mediaSource)
                return PlaybackInfo(
                    url: url,
                    playSessionId: playSessionId,
                    mediaSourceId: mediaSource.id,
                    playMethod: .transcode,
                    audioTracks: audioTracks,
                    subtitleTracks: subtitleTracks,
                    selectedAudioIndex: audioStreamIndex ?? mediaSource.defaultAudioStreamIndex,
                    selectedSubtitleIndex: subtitleStreamIndex ?? mediaSource.defaultSubtitleStreamIndex,
                    authToken: nil // token already embedded in Jellyfin's HLS URL
                )
            }
        }

        // Option B: Direct stream (Swiftfin uses Paths.getVideoStream with isStatic=true)
        guard let playSessionId else {
            return buildDirectStreamURL(
                itemId: effectiveItemId, serverURL: serverURL, token: token, etag: item.etag
            )
        }

        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return buildDirectStreamURL(
                itemId: effectiveItemId, serverURL: serverURL, token: token, etag: item.etag
            )
        }
        components.path = "/Videos/\(effectiveItemId)/stream"
        var queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "playSessionId", value: playSessionId),
            URLQueryItem(name: "mediaSourceId", value: mediaSource.id ?? effectiveItemId),
        ]
        if let tag = item.etag { queryItems.append(URLQueryItem(name: "tag", value: tag)) }
        // Token passed via Authorization header on AVURLAsset, not in URL query params
        components.queryItems = queryItems

        guard let url = components.url else {
            return buildDirectStreamURL(
                itemId: effectiveItemId, serverURL: serverURL, token: token, etag: item.etag
            )
        }

        #if DEBUG
        debugLog("Direct stream URL: \(redactedURL(url))")
        #endif
        let (audioTracks, subtitleTracks) = Self.extractTracks(from: mediaSource)
        return PlaybackInfo(
            url: url,
            playSessionId: playSessionId,
            mediaSourceId: mediaSource.id,
            playMethod: .directStream,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            selectedAudioIndex: audioStreamIndex ?? mediaSource.defaultAudioStreamIndex,
            selectedSubtitleIndex: subtitleStreamIndex ?? mediaSource.defaultSubtitleStreamIndex,
            authToken: token
        )
    }

    /// Raw HTTP POST to PlaybackInfo, captures the full response body for diagnosis.
    private func rawPostPlaybackInfo(
        serverURL: URL,
        itemId: String,
        client: JellyfinClient,
        body: PlaybackInfoDto
    ) async throws -> PlaybackInfoResponse {
        let url = serverURL.appendingPathComponent("/Items/\(itemId)/PlaybackInfo")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build the same auth header the SDK uses
        var rawFields = [
            "DeviceId": client.configuration.deviceID,
            "Device": client.configuration.deviceName,
            "Client": client.configuration.client,
            "Version": client.configuration.version,
        ]
        if let token = client.accessToken {
            rawFields["Token"] = token
        }
        let fields = rawFields.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        request.setValue("MediaBrowser \(fields)", forHTTPHeaderField: "Authorization")

        // Encode the body
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        #if DEBUG
        if let bodyStr = String(data: request.httpBody!, encoding: .utf8) {
            let truncated = bodyStr.prefix(500)
            debugLog("POST body: \(truncated)...")
        }
        #endif

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        let httpResponse = urlResponse as? HTTPURLResponse

        #if DEBUG
        debugLog("POST PlaybackInfo status: \(httpResponse?.statusCode ?? -1)")
        if let responseStr = String(data: data, encoding: .utf8) {
            debugLog("POST PlaybackInfo response body: \(responseStr.prefix(1000))")
        }
        #endif

        guard let statusCode = httpResponse?.statusCode, (200..<300).contains(statusCode) else {
            let statusCode = httpResponse?.statusCode ?? -1
            #if DEBUG
            if let bodyStr = String(data: data, encoding: .utf8) {
                debugLog("PlaybackInfo \(statusCode) body: \(bodyStr.prefix(500))")
            }
            #endif
            throw JellyfinError.playbackFailed("PlaybackInfo returned \(statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return isoFormatter.date(from: dateStr) ?? Date()
        }
        return try decoder.decode(PlaybackInfoResponse.self, from: data)
    }

    /// Fallback: direct stream URL without PlaybackInfo session.
    private func buildDirectStreamURL(
        itemId: String, serverURL: URL, token: String?, etag: String?
    ) -> PlaybackInfo {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = "/Videos/\(itemId)/stream"
        var queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: itemId),
            URLQueryItem(name: "deviceId", value: deviceID),
        ]
        if let etag { queryItems.append(URLQueryItem(name: "tag", value: etag)) }
        // Token passed via Authorization header on AVURLAsset, not in URL query params
        components.queryItems = queryItems

        let url = components.url ?? serverURL
        #if DEBUG
        debugLog("Direct stream fallback URL: \(redactedURL(url))")
        #endif
        return PlaybackInfo(url: url, playSessionId: nil, mediaSourceId: itemId, playMethod: .directStream,
                            audioTracks: [], subtitleTracks: [], selectedAudioIndex: nil, selectedSubtitleIndex: nil,
                            authToken: token)
    }

    // MARK: - Playback Reporting

    public func reportPlaybackStart(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, playMethod: PlayMethod) async {
        guard let client = getClient() else { return }
        let jellyfinMethod = JellyfinAPI.PlayMethod(rawValue: playMethod.rawValue)
        let body = PlaybackStartInfo(
            canSeek: true,
            itemID: itemId,
            mediaSourceID: mediaSourceId,
            playMethod: jellyfinMethod,
            playSessionID: playSessionId,
            positionTicks: positionTicks
        )
        _ = try? await client.send(Paths.reportPlaybackStart(body))
    }

    public func reportPlaybackProgress(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, isPaused: Bool, playMethod: PlayMethod) async {
        guard let client = getClient() else { return }
        let jellyfinMethod = JellyfinAPI.PlayMethod(rawValue: playMethod.rawValue)
        let body = PlaybackProgressInfo(
            canSeek: true,
            isPaused: isPaused,
            itemID: itemId,
            mediaSourceID: mediaSourceId,
            playMethod: jellyfinMethod,
            playSessionID: playSessionId,
            positionTicks: positionTicks
        )
        _ = try? await client.send(Paths.reportPlaybackProgress(body))
    }

    public func reportPlaybackStopped(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?) async {
        guard let client = getClient() else { return }
        let body = PlaybackStopInfo(
            itemID: itemId,
            mediaSourceID: mediaSourceId,
            playSessionID: playSessionId,
            positionTicks: positionTicks
        )
        _ = try? await client.send(Paths.reportPlaybackStopped(body))
    }

    /// Extracts audio and subtitle track info from a media source's stream list.
    fileprivate static func extractTracks(from source: MediaSourceInfo) -> (audio: [MediaTrackInfo], subtitles: [MediaTrackInfo]) {
        let streams = source.mediaStreams ?? []
        let audio: [MediaTrackInfo] = streams
            .filter { $0.type == .audio }
            .compactMap { s in
                guard let idx = s.index else { return nil }
                let label = s.displayTitle ?? s.language ?? "Track \(idx)"
                return MediaTrackInfo(id: idx, label: label, isDefault: s.isDefault ?? false, isForced: s.isForced ?? false)
            }
        let subtitles: [MediaTrackInfo] = streams
            .filter { $0.type == .subtitle }
            .compactMap { s in
                guard let idx = s.index else { return nil }
                let label = s.displayTitle ?? s.language ?? "Track \(idx)"
                return MediaTrackInfo(id: idx, label: label, isDefault: s.isDefault ?? false, isForced: s.isForced ?? false)
            }
        return (audio, subtitles)
    }

    // Cached constant arrays — built once at class load time, reused on every playback request.
    nonisolated(unsafe) fileprivate static let _directPlayProfiles: [DirectPlayProfile] = [
        DirectPlayProfile(
            audioCodec: "aac,ac3,alac,eac3,flac",
            container: "mp4,m4v",
            type: .video,
            videoCodec: "h264,hevc"
        ),
        DirectPlayProfile(
            audioCodec: "aac,ac3,alac,eac3,mp3,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le",
            container: "mov",
            type: .video,
            videoCodec: "h264,hevc,mjpeg"
        ),
        DirectPlayProfile(
            audioCodec: "aac,ac3,eac3,mp3",
            container: "mpegts",
            type: .video,
            videoCodec: "h264,hevc"
        ),
    ]
    // hevc,h264 only — MPEG-4 ASP is not a valid HLS transcode target on Apple devices
    // and causes Jellyfin to inject mpeg4-* URL parameters that AVFoundation doesn't recognise.
    // enableSubtitlesInManifest = true → Jellyfin includes WebVTT renditions in the HLS manifest.
    // AVKit shows them natively in ONE unified Subtitles menu on both iOS and tvOS.
    // On iOS, HLSManifestLoader strips ASS/SSA tags from WebVTT segments.
    // On tvOS, AVAssetResourceLoaderDelegate doesn't work, so ASS tags may appear in subtitles.
    nonisolated(unsafe) fileprivate static let _transcodingProfiles: [TranscodingProfile] = [
        TranscodingProfile(
            audioCodec: "aac,ac3,alac,eac3,flac",
            isBreakOnNonKeyFrames: true,
            container: "mp4",
            context: .streaming,
            enableSubtitlesInManifest: true,
            maxAudioChannels: "8",
            minSegments: 2,
            protocol: .hls,
            type: .video,
            videoCodec: "hevc,h264"
        ),
    ]
    nonisolated(unsafe) fileprivate static let _subtitleProfiles: [SubtitleProfile] = [
        SubtitleProfile(format: "srt",    method: .hls),
        SubtitleProfile(format: "subrip", method: .hls),
        SubtitleProfile(format: "vtt",    method: .hls),
        SubtitleProfile(format: "webvtt", method: .hls),
        SubtitleProfile(format: "ass",    method: .hls),
        SubtitleProfile(format: "ssa",    method: .hls),
        SubtitleProfile(format: "ttml",   method: .hls),
        SubtitleProfile(format: "pgs",    method: .encode),
        SubtitleProfile(format: "pgssub", method: .encode),
        SubtitleProfile(format: "dvbsub", method: .encode),
        SubtitleProfile(format: "dvdsub", method: .encode),
        SubtitleProfile(format: "sub",    method: .encode),
    ]

    /// Builds a DeviceProfile matching Swiftfin's native player profile.
    fileprivate static func buildAppleDeviceProfile(maxBitrate: Int = 40_000_000) -> DeviceProfile {
        DeviceProfile(
            directPlayProfiles: _directPlayProfiles,
            maxStreamingBitrate: maxBitrate,
            subtitleProfiles: _subtitleProfiles,
            transcodingProfiles: _transcodingProfiles
        )
    }
}
