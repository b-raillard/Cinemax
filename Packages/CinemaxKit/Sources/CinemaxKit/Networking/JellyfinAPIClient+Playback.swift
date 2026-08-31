import Foundation
import JellyfinAPI

extension JellyfinAPIClient {
    // MARK: - Playback

    /// Builds the best streaming URL for the given item.
    /// Follows Swiftfin's exact flow:
    /// 1. Get full item → extract initial media source
    /// 2. POST PlaybackInfo with device profile
    /// 3. Build stream URL from response (transcodingURL or direct stream)
    public func getPlaybackInfo(itemId: String, userId: String, maxBitrate: Int = 40_000_000, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil, engine: VideoPlaybackEngine = .native, mediaSourceId: String? = nil) async throws -> PlaybackInfo {
        do {
            return try await _getPlaybackInfo(itemId: itemId, userId: userId, maxBitrate: maxBitrate, audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex, engine: engine, mediaSourceId: mediaSourceId)
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    private func _getPlaybackInfo(itemId: String, userId: String, maxBitrate: Int, audioStreamIndex: Int?, subtitleStreamIndex: Int?, engine: VideoPlaybackEngine, mediaSourceId: String? = nil, forceTranscode: Bool = false) async throws -> PlaybackInfo {
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

        // If this is a Series or Season, resolve to a playable episode.
        let resolved = try await resolvePlayableEpisode(item: item, itemId: itemId, userId: userId)
        item = resolved.item
        effectiveItemId = resolved.itemId

        // Multi-version items (a 4K remux alongside a 1080p encode, an IMAX cut
        // alongside the theatrical) expose several sources here. Ranking is
        // owned by `MediaSourceQuality` so the version this opens is the same
        // one the detail screen's badges describe — `mediaSources.first` used to
        // pick arbitrarily on both sides. An explicit `mediaSourceId` is the
        // user's override from the version row; a stale one falls back to the
        // ranked pick rather than failing playback.
        let initialMediaSource = MediaSourceQuality.resolve(
            item.mediaSources ?? [],
            preferredID: mediaSourceId,
            maxBitrate: maxBitrate
        )
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

        // The container is already known here — `getItem` carried it into
        // `initialMediaSource` above — so the seek-heavy decision (see the
        // fallback below for the why) is made BEFORE the first POST. It used to
        // be read off the *response*, which cost an AVI two full PlaybackInfo
        // round-trips: negotiate, discover the container, re-negotiate with the
        // transcode profile. The post-response check stays as the fallback for
        // items whose `getItem` carried no source or no container.
        let forcedTranscode = forceTranscode
            || (engine == .vlc && Self.isSeekHeavyContainer(initialMediaSource?.container))
        #if DEBUG
        if forcedTranscode, !forceTranscode {
            debugLog("  seek-heavy container '\(initialMediaSource?.container ?? "?")' → forcing HLS transcode up front")
        }
        #endif

        let deviceProfile: DeviceProfile = (engine == .vlc)
            ? (forcedTranscode ? Self.buildVLCTranscodeProfile(maxBitrate: maxBitrate)
                               : Self.buildVLCDeviceProfile(maxBitrate: maxBitrate))
            : Self.buildAppleDeviceProfile(maxBitrate: maxBitrate)
        var body = PlaybackInfoDto(deviceProfile: deviceProfile)
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
            // A 401 means the token is revoked — the direct-stream fallback
            // would fail identically at the media layer with an opaque player
            // error. Rethrow so the outer `getPlaybackInfo` wrapper runs
            // `notifyIfUnauthorized` and the session-expiry flow fires.
            if Self.isUnauthorized(error) { throw error }
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
            // Neither the eTag nor the id matched what `getItem` reported, so
            // rank the response's own sources rather than taking whichever
            // happens to be first — same owner, same answer.
            return MediaSourceQuality.best(of: sources, maxBitrate: maxBitrate)
        }()

        guard let mediaSource else {
            // The POST succeeded but matched no source. If `getItem` ALSO had no
            // media source, the item has no playable file (missing / unmounted on
            // the server) — surface a clear error rather than falling through to a
            // direct-stream URL that resolves to a 404/empty mux and leaves the
            // user on a frozen black screen. When getItem *did* have a source, the
            // mismatch is benign and the direct-stream fallback can still work.
            guard initialMediaSource != nil else {
                throw JellyfinError.playbackFailed("No playable media source")
            }
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

        // Seek-heavy containers (AVI/XviD &c.) keep their index at EOF, so libVLC
        // seeks constantly over HTTP — un-streamable raw from a reverse-proxied
        // origin: direct trips the proxy (HTTP/2 range storm) and our loopback
        // proxy can't serve the random-access pattern (the index seek wedges the
        // one-shot connection → freeze). So re-resolve once with an empty-DirectPlay
        // profile, forcing the server to hand us a linear HLS transcode instead.
        // (A true remux/copy would be lighter, but this server transcodes XviD
        // regardless: it reports SupportsDirectStream=false / ContainerNotSupported
        // for mpeg4.) Falls through to the raw path only if the server can't
        // transcode at all.
        //
        // The decision normally fires BEFORE the POST above, off the container
        // `getItem` reported. This re-negotiation is the fallback for the case
        // that check can't cover: no media source (or no container) on the item,
        // with the response revealing a seek-heavy one.
        if engine == .vlc, !forcedTranscode,
           Self.isSeekHeavyContainer(mediaSource.container) {
            #if DEBUG
            debugLog("  seek-heavy container '\(mediaSource.container ?? "?")' → forcing HLS transcode")
            #endif
            // Carry the resolved source id into the retry: without it the
            // re-resolve would re-rank from scratch and could transcode a
            // different version than the one that triggered the fallback.
            if let transcoded = try? await _getPlaybackInfo(
                itemId: effectiveItemId, userId: userId, maxBitrate: maxBitrate,
                audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex,
                engine: engine, mediaSourceId: mediaSource.id ?? mediaSourceId, forceTranscode: true
            ), transcoded.playMethod == .transcode {
                return transcoded
            }
            #if DEBUG
            debugLog("  forced transcode unavailable — falling back to raw stream")
            #endif
        }

        // Step 4: Build stream URL (same logic as Swiftfin's streamURL)

        // Option A: Server returned a transcoding URL — use it directly
        if let transcodingPath = mediaSource.transcodingURL {
            let baseURL = serverURL.absoluteString.trimmingCharacters(in: ["/"])
            if let url = URL(string: baseURL + transcodingPath) {
                #if DEBUG
                Self.logPlaybackDecision(method: "transcode", item: item, source: mediaSource, url: url)
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
                    authToken: nil, // token already embedded in Jellyfin's HLS URL
                    liveStreamId: mediaSource.liveStreamID
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
        components.setEndpointPath("/Videos/\(effectiveItemId)/stream", preservingBasePathOf: serverURL)
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
        Self.logPlaybackDecision(method: "directStream", item: item, source: mediaSource, url: url)
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
            authToken: token,
            sourceContainer: mediaSource.container,
            liveStreamId: mediaSource.liveStreamID
        )
    }

    /// Resolves a Series/Season to a playable Episode, fetching the full DTO.
    /// Movies (and any other already-playable kind) pass through unchanged.
    /// Series prefers the user's "Next Up" episode; falls back to the first
    /// episode of the first season. Season picks the first episode.
    private func resolvePlayableEpisode(
        item: BaseItemDto,
        itemId: String,
        userId: String
    ) async throws -> (item: BaseItemDto, itemId: String) {
        if item.type == .series {
            let resolvedId: String
            if let nextEp = try await getNextUp(seriesId: itemId, userId: userId),
               let epId = nextEp.id {
                resolvedId = epId
                #if DEBUG
                debugLog("Resolved Series → next up episode (\(epId))")
                #endif
            } else {
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
            let resolved = try await getItem(userId: userId, itemId: resolvedId)
            return (resolved, resolvedId)
        } else if item.type == .season {
            guard let seriesId = item.seriesID else {
                throw JellyfinError.playbackFailed("No series ID for season")
            }
            let episodes = try await getEpisodes(seriesId: seriesId, seasonId: itemId, userId: userId)
            guard let firstEp = episodes.first, let firstEpId = firstEp.id else {
                throw JellyfinError.playbackFailed("No episodes in this season")
            }
            let resolved = try await getItem(userId: userId, itemId: firstEpId)
            #if DEBUG
            debugLog("Resolved Season → first episode (\(firstEpId))")
            #endif
            return (resolved, firstEpId)
        }
        return (item, itemId)
    }

    /// Dedicated session for the hand-built PlaybackInfo POST. Deliberately NOT
    /// `URLSession.shared`, which carries a disk-backed `URLCache`: this request
    /// is authenticated (`MediaBrowser Token=…` header) and its response body
    /// contains the freshly-negotiated stream URL — including the `api_key`
    /// query item — so a shared-session cache file would hold both at rest.
    /// Mirrors `syncPlaySession` and the SDK clients'
    /// `fastFailSessionConfiguration` (`urlCache = nil`, bounded timeouts,
    /// `waitsForConnectivity = false`); the per-request `timeoutInterval = 20`
    /// set by the caller still wins over the configuration default.
    private static let playbackInfoSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

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

        // Generous enough for a loaded/transcoding server to negotiate without
        // a spurious timeout, but still bounded so a dead server fails the Play
        // tap in reasonable time. (Was 8s — too tight for slow self-hosts.)
        request.timeoutInterval = 20
        let (data, urlResponse) = try await Self.playbackInfoSession.data(for: request)
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
            // Surface a structured 401 so `isUnauthorized` matches it precisely
            // (the old `playbackFailed("… 401")` string only worked under the
            // now-removed substring heuristic).
            if statusCode == 401 { throw JellyfinError.unauthorized }
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
        components.setEndpointPath("/Videos/\(itemId)/stream", preservingBasePathOf: serverURL)
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

    public func reportPlaybackStopped(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, liveStreamId: String?) async {
        guard let client = getClient() else { return }
        let body = PlaybackStopInfo(
            itemID: itemId,
            liveStreamID: liveStreamId,
            mediaSourceID: mediaSourceId,
            playSessionID: playSessionId,
            positionTicks: positionTicks
        )
        _ = try? await client.send(Paths.reportPlaybackStopped(body))
        // Playback just moved this item's resume position server-side. Drop its
        // short-TTL getItem entry (and the resume list) so the detail screen's
        // immediate post-dismiss reload — tvOS reloads synchronously on dismiss —
        // paints the fresh resume bar instead of the pre-playback position. Also
        // drop every userData-bearing series cache so a season's per-episode
        // progress bar reflects the just-watched episode and the detail screen's
        // post-playback refresh re-resolves the next episode instead of
        // re-serving the one that just finished.
        cache.invalidate(prefix: "item-\(itemId)-")
        cache.invalidate(prefix: "resume-")
        for prefix in Self.userDataCachePrefixes { cache.invalidate(prefix: prefix) }
    }

    /// Tears down the server's encoding job for this play session. `deviceID` is
    /// resolved here rather than passed in — the caller (`PlaybackReporter`) has
    /// no business knowing this device's identity.
    public func stopEncoding(playSessionId: String) async {
        guard let client = getClient() else { return }
        _ = try? await client.send(
            Paths.stopEncodingProcess(deviceID: deviceID, playSessionID: playSessionId)
        )
    }

    /// Refreshes the server's activity clock for this play session, so it won't
    /// reap an encoding job that's merely paused.
    public func pingPlaybackSession(playSessionId: String) async {
        guard let client = getClient() else { return }
        _ = try? await client.send(Paths.pingPlaybackSession(playSessionID: playSessionId))
    }

    public func closeLiveStream(liveStreamId: String) async {
        guard let client = getClient() else { return }
        _ = try? await client.send(Paths.closeLiveStream(liveStreamID: liveStreamId))
    }

    /// Compact, single-tag diagnostic for the playback decision.
    /// Filter the Xcode console / Console.app for `CINEMAX-PLAYBACK` to capture it.
    ///
    /// The decisive field is `TranscodeReasons` (NOT the `VideoCodec` URL param — that's
    /// just the list of output codecs the client accepts, not the server's decision).
    ///   • no `Video*` reason          → server REMUXES (`-c:v copy`): fast start, DV/HDR intact
    ///   • any `Video*` reason present → server RE-ENCODES the video: slow, the freeze bug
    /// `ContainerNotSupported` / `SubtitleCodecNotSupported` / `AudioCodecNotSupported`
    /// alone do not force a video re-encode (remux + sidecar subs / audio transcode).
    fileprivate static func logPlaybackDecision(
        method: String,
        item: BaseItemDto,
        source: MediaSourceInfo,
        url: URL?
    ) {
        #if DEBUG
        let videoStream = source.mediaStreams?.first { $0.type == .video }
        debugLog("CINEMAX-PLAYBACK ▸ item=\(item.name ?? "?") method=\(method)")
        debugLog("CINEMAX-PLAYBACK ▸ srcContainer=\(source.container ?? "?") videoCodec=\(videoStream?.codec ?? "?") range=\(videoStream?.videoRangeType?.rawValue ?? videoStream?.videoRange?.rawValue ?? "?") bitDepth=\(videoStream?.bitDepth.map(String.init) ?? "?")")
        debugLog("CINEMAX-PLAYBACK ▸ directPlay=\(source.isSupportsDirectPlay ?? false) directStream=\(source.isSupportsDirectStream ?? false)")
        if let url, let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            let wanted = ["VideoCodec", "AudioCodec", "TranscodeReasons", "videoCodec", "audioCodec", "static"]
            let picked = q
                .filter { wanted.contains($0.name) }
                .map { "\($0.name)=\($0.value ?? "")" }
                .joined(separator: " ")
            if !picked.isEmpty { debugLog("CINEMAX-PLAYBACK ▸ \(picked)") }
            let reasons = (q.first { $0.name == "TranscodeReasons" }?.value ?? "")
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if q.first(where: { $0.name == "TranscodeReasons" }) == nil {
                debugLog("CINEMAX-PLAYBACK ▸ verdict=✅ \(method) (no server transcode at all)")
            } else if let videoReason = reasons.first(where: { $0.lowercased().hasPrefix("video") }) {
                debugLog("CINEMAX-PLAYBACK ▸ verdict=⚠️ RE-ENCODE — video transcode forced by \(videoReason). Profile fix NOT effective.")
            } else {
                debugLog("CINEMAX-PLAYBACK ▸ verdict=✅ REMUX (-c:v copy) — reasons=[\(reasons.joined(separator: ", "))] are container/subtitle/audio only; video copied, DV/HDR intact, fast start. Confirm with server ffmpeg line (-codec:v:0 copy).")
            }
        } else {
            debugLog("CINEMAX-PLAYBACK ▸ verdict=✅ \(method) (no server transcode)")
        }
        debugLog("CINEMAX-PLAYBACK ▸ url=\(redactedURL(url?.absoluteString))")
        #endif
    }

    /// Extracts audio and subtitle track info from a media source's stream list.
    fileprivate static func extractTracks(from source: MediaSourceInfo) -> (audio: [MediaTrackInfo], subtitles: [MediaTrackInfo]) {
        let streams = source.mediaStreams ?? []
        let audio: [MediaTrackInfo] = streams
            .filter { $0.type == .audio }
            .compactMap { s in
                guard let idx = s.index else { return nil }
                let label = s.displayTitle ?? s.language ?? "Track \(idx)"
                return MediaTrackInfo(
                    id: idx,
                    label: label,
                    isDefault: s.isDefault ?? false,
                    isForced: s.isForced ?? false,
                    codec: s.codec,
                    language: s.language
                )
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
    // Without these, Jellyfin has no signal that the Apple TV / iOS device can decode
    // HEVC Main 10 + Dolby Vision / HDR10 inside an HLS fMP4 container, so it falls back
    // to its most conservative decision: a full 4K re-encode + DV/HDR→SDR tonemap +
    // 10-bit→8-bit conversion. That transcode is so slow to produce segments that
    // AVPlayer stalls, the server's kill timer keeps restarting ffmpeg at new -ss
    // offsets, and playback freezes (see server logs: repeated "Stopping ffmpeg" /
    // sub-second "Playback stopped" reports).
    //
    // Declaring the supported bit depth, level and (critically) VideoRangeType set tells
    // Jellyfin the source is playable as-is, so for MKV sources it emits a *remux* —
    // `-codec:v copy` into HLS fMP4 — which starts in well under a second. Apple TV 4K
    // natively decodes HEVC Main 10 and Dolby Vision Profile 5/8 (incl. the HDR10/HLG/SDR
    // cross-compatible variants); when DV isn't engaged the HDR10 base layer still plays.
    nonisolated(unsafe) fileprivate static let _codecProfiles: [CodecProfile] = [
        CodecProfile(
            codec: "hevc",
            conditions: [
                ProfileCondition(condition: .lessThanEqual, isRequired: false, property: .videoBitDepth, value: "10"),
                ProfileCondition(condition: .lessThanEqual, isRequired: false, property: .videoLevel, value: "183"),
                ProfileCondition(
                    condition: .equalsAny,
                    isRequired: false,
                    property: .videoRangeType,
                    value: "SDR|HDR10|HLG|HDR10Plus|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR"
                ),
            ],
            type: .video
        ),
        CodecProfile(
            codec: "h264",
            conditions: [
                ProfileCondition(condition: .lessThanEqual, isRequired: false, property: .videoBitDepth, value: "8"),
                ProfileCondition(condition: .lessThanEqual, isRequired: false, property: .videoLevel, value: "52"),
                ProfileCondition(
                    condition: .equalsAny,
                    isRequired: false,
                    property: .videoRangeType,
                    value: "SDR"
                ),
            ],
            type: .video
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
            codecProfiles: _codecProfiles,
            directPlayProfiles: _directPlayProfiles,
            maxStreamingBitrate: maxBitrate,
            subtitleProfiles: _subtitleProfiles,
            transcodingProfiles: _transcodingProfiles
        )
    }

    // MARK: - VLC Device Profile

    // libVLC decodes virtually any container/codec, so we advertise a single
    // DirectPlayProfile with **no container restriction** (container == nil ⇒
    // "any"). Jellyfin then serves the raw file (`/Videos/{id}/stream?static=true`)
    // with NO transcode — preserving 4K / HEVC 10-bit / Dolby Vision and
    // eliminating the slow-transcode segment thrash that froze AVPlayer.
    // Mirrors Swiftfin's `_swiftfinDirectPlayProfiles`.
    nonisolated(unsafe) fileprivate static let _vlcDirectPlayProfiles: [DirectPlayProfile] = [
        DirectPlayProfile(
            audioCodec: "aac,ac3,alac,amr_nb,amr_wb,dts,eac3,flac,mp1,mp2,mp3,nellymoser,opus,pcm_alaw,pcm_bluray,pcm_dvd,pcm_mulaw,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le,pcm_u8,speex,truehd,vorbis,wavpack,wmalossless,wmapro,wmav1,wmav2",
            container: nil, // any container — VLC handles mkv/avi/ts/webm/…
            type: .video,
            videoCodec: "av1,dirac,dv,ffv1,flv1,h261,h263,h264,hevc,mjpeg,mpeg1video,mpeg2video,mpeg4,msmpeg4v1,msmpeg4v2,msmpeg4v3,prores,theora,vc1,vp8,vp9,wmv1,wmv2,wmv3"
        ),
    ]
    // Last-resort fallback only — VLC direct-plays essentially everything, but
    // if the server still insists on transcoding (e.g. a codec it can't even
    // remux) we keep an HLS path so playback isn't impossible.
    nonisolated(unsafe) fileprivate static let _vlcTranscodingProfiles: [TranscodingProfile] = [
        TranscodingProfile(
            // NO mp1/mp2/mp3 here on purpose. MPEG audio is legal in the TS
            // segments below (that's what TS was built for), so the original
            // reason is narrower than it was — but it is NOT re-litigated here
            // without a measurement: when the video is transcoded and a source
            // MPEG-audio track is COPIED into the segments, MP3's
            // encoder delay/priming isn't re-timed against the new video → a
            // constant audio offset (the "son décalé" on transcoded AVI/XviD).
            // Leaving these out forces the server to re-encode audio to AAC,
            // which stays locked to the transcoded video whatever the segment
            // container.
            audioCodec: "aac,ac3,alac,dts,eac3,flac,opus,vorbis",
            isBreakOnNonKeyFrames: true,
            // MPEG-TS segments, NOT fMP4. libVLC's MP4 demuxer inspects the fMP4
            // init segment, finds no chunk table (`no chunk defined`, `STTS table
            // of 0 entries` — normal for fragmented MP4, where samples live in
            // each media segment's moof), concludes `that media doesn't look
            // interleaved, will need to seek`, and then random-accesses inside
            // every segment. Over HTTP/2 that becomes one cancelled stream after
            // another (`local stream N error: Cancellation (0x8)`, hundreds of
            // them) and playback crawls — measured at ~9s of picture in ~3min on
            // a server that had already finished encoding the whole episode.
            // TS is a linear byte stream with no such structure to probe, so the
            // seek behaviour disappears by construction.
            container: "ts",
            context: .streaming,
            maxAudioChannels: "8",
            // 1, not 2: Jellyfin holds the playlist back until `minSegments`
            // segments have actually been ENCODED (`WaitForMinimumSegmentCount`),
            // so each one is real ffmpeg time added before the first frame can
            // play — the dominant cost of starting a forced-transcode AVI. One
            // segment is enough to start; `:network-caching` covers the rest.
            minSegments: 1,
            protocol: .hls,
            type: .video,
            videoCodec: "hevc,h264"
        ),
    ]
    // VLC renders embedded text subtitles itself; image subs delivered as-is.
    nonisolated(unsafe) fileprivate static let _vlcSubtitleProfiles: [SubtitleProfile] = [
        SubtitleProfile(format: "ass",    method: .embed),
        SubtitleProfile(format: "ssa",    method: .embed),
        SubtitleProfile(format: "srt",    method: .embed),
        SubtitleProfile(format: "subrip", method: .embed),
        SubtitleProfile(format: "vtt",    method: .embed),
        SubtitleProfile(format: "webvtt", method: .embed),
        SubtitleProfile(format: "ttml",   method: .embed),
        SubtitleProfile(format: "pgssub", method: .embed),
        SubtitleProfile(format: "dvbsub", method: .embed),
        SubtitleProfile(format: "dvdsub", method: .embed),
    ]

    /// Broad-DirectPlay profile for the VLC engine — Jellyfin serves the raw
    /// file with no transcode (4K / HEVC 10-bit / Dolby Vision preserved).
    fileprivate static func buildVLCDeviceProfile(maxBitrate: Int = 40_000_000) -> DeviceProfile {
        DeviceProfile(
            directPlayProfiles: _vlcDirectPlayProfiles,
            maxStreamingBitrate: maxBitrate,
            subtitleProfiles: _vlcSubtitleProfiles,
            transcodingProfiles: _vlcTranscodingProfiles
        )
    }

    /// Transcode-forcing VLC profile: empty `directPlayProfiles` means nothing
    /// matches for DirectPlay/DirectStream, so the server hands back a linear HLS
    /// transcode. Used only for seek-heavy containers (`isSeekHeavyContainer`)
    /// that can't be streamed raw over HTTP from a reverse-proxied origin.
    fileprivate static func buildVLCTranscodeProfile(maxBitrate: Int = 40_000_000) -> DeviceProfile {
        DeviceProfile(
            directPlayProfiles: [],
            maxStreamingBitrate: maxBitrate,
            subtitleProfiles: _vlcSubtitleProfiles,
            transcodingProfiles: _vlcTranscodingProfiles
        )
    }

    /// Containers whose index lives at EOF, so libVLC seeks constantly over HTTP
    /// (the AVI/XviD range storm). These must be transcoded server-side, not
    /// streamed raw. Matched against the (possibly comma/space-joined) container.
    private static let seekHeavyContainers: Set<String> = [
        "avi", "divx", "wmv", "asf", "flv", "vob", "mpg", "mpeg", "mpe", "m2v"
    ]
    static func isSeekHeavyContainer(_ container: String?) -> Bool {
        guard let raw = container?.lowercased() else { return false }
        return raw.split(whereSeparator: { $0 == "," || $0 == " " })
            .contains { seekHeavyContainers.contains(String($0)) }
    }
}
