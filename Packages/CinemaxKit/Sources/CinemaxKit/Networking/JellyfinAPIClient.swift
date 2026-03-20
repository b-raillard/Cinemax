import Foundation
#if DEBUG
import Get
#endif
import JellyfinAPI

#if DEBUG
func debugLog(_ message: String) {
    print("[Cinemax] \(message)")
}
#endif

public final class JellyfinAPIClient: Sendable {
    // JellyfinClient is not Sendable, so we protect it with a lock
    private let lock = NSLock()
    nonisolated(unsafe) private var _jellyfinClient: JellyfinClient?
    nonisolated(unsafe) private var _serverURL: URL?

    public init() {}

    private func getClient() -> JellyfinClient? {
        lock.lock()
        defer { lock.unlock() }
        return _jellyfinClient
    }

    private func setClient(_ client: JellyfinClient, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        _jellyfinClient = client
        _serverURL = url
    }

    private func getServerURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return _serverURL
    }

    public func connectToServer(url: URL) async throws -> ServerInfo {
        let client = JellyfinClient(
            configuration: .init(
                url: url,
                client: "Cinemax",
                deviceName: deviceName,
                deviceID: deviceID,
                version: appVersion
            )
        )

        let response = try await client.send(Paths.getPublicSystemInfo)
        let info = response.value

        setClient(client, url: url)

        return ServerInfo(
            name: info.serverName ?? "Jellyfin Server",
            serverID: info.id ?? "",
            version: info.version ?? "",
            url: url
        )
    }

    /// Fetches server info using the existing client (does NOT replace it).
    public func fetchServerInfo() async throws -> ServerInfo {
        guard let client = getClient(),
              let url = getServerURL() else {
            throw JellyfinError.notConnected
        }

        let response = try await client.send(Paths.getPublicSystemInfo)
        let info = response.value

        return ServerInfo(
            name: info.serverName ?? "Jellyfin Server",
            serverID: info.id ?? "",
            version: info.version ?? "",
            url: url
        )
    }

    public func authenticate(username: String, password: String) async throws -> UserSession {
        guard let client = getClient() else {
            throw JellyfinError.notConnected
        }

        let body = AuthenticateUserByName(pw: password, username: username)
        let request = Paths.authenticateUserByName(body)
        let response = try await client.send(request)
        let result = response.value

        guard let accessToken = result.accessToken,
              let userID = result.user?.id else {
            throw JellyfinError.authenticationFailed
        }

        // Reconfigure client with access token
        if let url = getServerURL() {
            let authedClient = JellyfinClient(
                configuration: .init(
                    url: url,
                    accessToken: accessToken,
                    client: "Cinemax",
                    deviceName: deviceName,
                    deviceID: deviceID,
                    version: appVersion
                )
            )
            setClient(authedClient, url: url)
        }

        return UserSession(
            userID: userID,
            username: result.user?.name ?? username,
            accessToken: accessToken,
            serverID: result.serverID ?? ""
        )
    }

    // MARK: - Media Queries

    public func getResumeItems(userId: String, limit: Int = 10) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetResumeItemsParameters(
            userID: userId,
            limit: limit,
            enableUserData: true,
            enableImageTypes: [.primary, .backdrop, .thumb]
        )
        let response = try await client.send(Paths.getResumeItems(parameters: params))
        return response.value.items ?? []
    }

    public func getLatestMedia(userId: String, parentId: String? = nil, limit: Int = 16) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetLatestMediaParameters(
            userID: userId,
            parentID: parentId,
            enableImages: true,
            imageTypeLimit: 1,
            enableUserData: true,
            limit: limit
        )
        let response = try await client.send(Paths.getLatestMedia(parameters: params))
        return response.value
    }

    public func getItems(
        userId: String,
        parentId: String? = nil,
        includeItemTypes: [BaseItemKind]? = nil,
        sortBy: [ItemSortBy]? = nil,
        limit: Int? = nil,
        startIndex: Int? = nil
    ) async throws -> (items: [BaseItemDto], totalCount: Int) {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetItemsParameters(
            userID: userId,
            startIndex: startIndex,
            limit: limit,
            isRecursive: true,
            parentID: parentId,
            includeItemTypes: includeItemTypes,
            sortBy: sortBy
        )
        let response = try await client.send(Paths.getItems(parameters: params))
        let result = response.value
        return (result.items ?? [], result.totalRecordCount ?? 0)
    }

    public func getUserViews(userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetUserViewsParameters(userID: userId)
        let response = try await client.send(Paths.getUserViews(parameters: params))
        return response.value.items ?? []
    }

    public func getItem(userId: String, itemId: String) async throws -> BaseItemDto {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getItem(itemID: itemId, userID: userId))
        return response.value
    }

    public func getSimilarItems(itemId: String, userId: String, limit: Int = 12) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetSimilarItemsParameters(userID: userId, limit: limit)
        let response = try await client.send(Paths.getSimilarItems(itemID: itemId, parameters: params))
        return response.value.items ?? []
    }

    public func searchItems(userId: String, searchTerm: String, limit: Int = 20) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetItemsParameters(
            userID: userId,
            limit: limit,
            isRecursive: true,
            searchTerm: searchTerm,
            includeItemTypes: [.movie, .series, .episode]
        )
        let response = try await client.send(Paths.getItems(parameters: params))
        return response.value.items ?? []
    }

    public func getSeasons(seriesId: String, userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetSeasonsParameters(userID: userId, enableUserData: true)
        let response = try await client.send(Paths.getSeasons(seriesID: seriesId, parameters: params))
        return response.value.items ?? []
    }

    public func getEpisodes(seriesId: String, seasonId: String, userId: String) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetEpisodesParameters(userID: userId, seasonID: seasonId, enableUserData: true)
        let response = try await client.send(Paths.getEpisodes(seriesID: seriesId, parameters: params))
        return response.value.items ?? []
    }

    public func getNextUp(seriesId: String, userId: String) async throws -> BaseItemDto? {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetNextUpParameters(
            userID: userId,
            limit: 1,
            seriesID: seriesId,
            enableUserData: true
        )
        let response = try await client.send(Paths.getNextUp(parameters: params))
        return response.value.items?.first
    }

    // MARK: - Playback

    /// Playback info returned after negotiating with the server.
    public struct PlaybackInfo: Sendable {
        public let url: URL
        public let playSessionId: String?
        public let mediaSourceId: String?
        public let playMethod: String // "DirectPlay", "DirectStream", "Transcode"
    }

    /// Builds the best streaming URL for the given item.
    /// Follows Swiftfin's exact flow:
    /// 1. Get full item → extract initial media source
    /// 2. POST PlaybackInfo with device profile
    /// 3. Build stream URL from response (transcodingURL or direct stream)
    public func getPlaybackInfo(itemId: String, userId: String) async throws -> PlaybackInfo {
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
        var body = PlaybackInfoDto(deviceProfile: Self.buildAppleDeviceProfile())
        body.isAutoOpenLiveStream = true
        body.maxStreamingBitrate = 40_000_000
        body.userID = userId
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
        debugLog("  transcodingURL=\(mediaSource.transcodingURL ?? "nil")")
        #endif

        // Step 4: Build stream URL (same logic as Swiftfin's streamURL)

        // Option A: Server returned a transcoding URL — use it directly
        if let transcodingPath = mediaSource.transcodingURL {
            let baseURL = serverURL.absoluteString.trimmingCharacters(in: ["/"])
            if let url = URL(string: baseURL + transcodingPath) {
                #if DEBUG
                debugLog("Transcode URL: \(url)")
                #endif
                return PlaybackInfo(
                    url: url,
                    playSessionId: playSessionId,
                    mediaSourceId: mediaSource.id,
                    playMethod: "Transcode"
                )
            }
        }

        // Option B: Direct stream (Swiftfin uses Paths.getVideoStream with isStatic=true)
        guard let playSessionId else {
            return buildDirectStreamURL(
                itemId: effectiveItemId, serverURL: serverURL, token: token, etag: item.etag
            )
        }

        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.path = "/Videos/\(effectiveItemId)/stream"
        var queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "playSessionId", value: playSessionId),
            URLQueryItem(name: "mediaSourceId", value: effectiveItemId),
        ]
        if let tag = item.etag { queryItems.append(URLQueryItem(name: "tag", value: tag)) }
        if let token { queryItems.append(URLQueryItem(name: "api_key", value: token)) }
        components.queryItems = queryItems

        guard let url = components.url else {
            return buildDirectStreamURL(
                itemId: effectiveItemId, serverURL: serverURL, token: token, etag: item.etag
            )
        }

        #if DEBUG
        debugLog("Direct stream URL: \(url)")
        #endif
        return PlaybackInfo(
            url: url,
            playSessionId: playSessionId,
            mediaSourceId: mediaSource.id,
            playMethod: "DirectStream"
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
            let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
            throw JellyfinError.playbackFailed("PlaybackInfo returned \(statusCode): \(bodyStr.prefix(200))")
        }

        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            return isoFormatter.date(from: dateStr) ?? Date()
        }
        return try decoder.decode(PlaybackInfoResponse.self, from: data)
    }

    /// Fallback: direct stream URL without PlaybackInfo session.
    private func buildDirectStreamURL(
        itemId: String, serverURL: URL, token: String?, etag: String?
    ) -> PlaybackInfo {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.path = "/Videos/\(itemId)/stream"
        var queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: itemId),
            URLQueryItem(name: "deviceId", value: deviceID),
        ]
        if let etag { queryItems.append(URLQueryItem(name: "tag", value: etag)) }
        if let token { queryItems.append(URLQueryItem(name: "api_key", value: token)) }
        components.queryItems = queryItems

        let url = components.url ?? serverURL
        #if DEBUG
        debugLog("Direct stream fallback URL: \(url)")
        #endif
        return PlaybackInfo(url: url, playSessionId: nil, mediaSourceId: itemId, playMethod: "DirectStream")
    }

    /// Builds a DeviceProfile matching Swiftfin's native player profile.
    private static func buildAppleDeviceProfile() -> DeviceProfile {
        let directPlayProfiles = [
            DirectPlayProfile(
                audioCodec: "aac,ac3,alac,eac3,flac",
                container: "mp4,m4v",
                type: .video,
                videoCodec: "h264,hevc,mpeg4"
            ),
            DirectPlayProfile(
                audioCodec: "aac,ac3,alac,eac3,mp3,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le",
                container: "mov",
                type: .video,
                videoCodec: "h264,hevc,mjpeg,mpeg4"
            ),
            DirectPlayProfile(
                audioCodec: "aac,ac3,eac3,mp3",
                container: "mpegts",
                type: .video,
                videoCodec: "h264,hevc"
            ),
        ]
        let transcodingProfiles = [
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
                videoCodec: "hevc,h264,mpeg4"
            ),
        ]
        return DeviceProfile(
            directPlayProfiles: directPlayProfiles,
            maxStreamingBitrate: 40_000_000,
            transcodingProfiles: transcodingProfiles
        )
    }

    public func reconnect(url: URL, accessToken: String) {
        let client = JellyfinClient(
            configuration: .init(
                url: url,
                accessToken: accessToken,
                client: "Cinemax",
                deviceName: deviceName,
                deviceID: deviceID,
                version: appVersion
            )
        )
        setClient(client, url: url)
    }

    private var deviceName: String {
        #if os(tvOS)
        "Apple TV"
        #elseif os(iOS)
        "iPhone"
        #else
        "Apple Device"
        #endif
    }

    private var deviceID: String {
        if let stored = UserDefaults.standard.string(forKey: "cinemax_device_id") {
            return stored
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "cinemax_device_id")
        return id
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

public enum JellyfinError: LocalizedError, Sendable {
    case notConnected
    case authenticationFailed
    case invalidURL
    case playbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to a server"
        case .authenticationFailed: "Authentication failed"
        case .invalidURL: "Invalid server URL"
        case .playbackFailed(let reason): "Playback failed: \(reason)"
        }
    }
}
