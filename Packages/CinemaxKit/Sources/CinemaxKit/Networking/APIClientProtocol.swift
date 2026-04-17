import Foundation
import JellyfinAPI

/// Abstraction over JellyfinAPIClient enabling mock injection for testing.
public protocol APIClientProtocol: Sendable {

    // MARK: - Server

    func connectToServer(url: URL) async throws -> ServerInfo
    func fetchServerInfo() async throws -> ServerInfo
    func reconnect(url: URL, accessToken: String)

    // MARK: - Auth

    func authenticate(username: String, password: String) async throws -> UserSession
    func getPublicUsers() async throws -> [UserDto]
    func getUsers() async throws -> [UserDto]
    func getActiveSessions(activeWithinSeconds: Int) async throws -> [SessionInfoDto]

    // MARK: - Cache

    /// Drops every cached response (used by Settings → Server → Refresh Catalogue).
    func clearCache()

    // MARK: - Media Queries

    func getResumeItems(userId: String, limit: Int) async throws -> [BaseItemDto]
    func getLatestMedia(userId: String, parentId: String?, limit: Int) async throws -> [BaseItemDto]
    func getItems(
        userId: String,
        parentId: String?,
        includeItemTypes: [BaseItemKind]?,
        sortBy: [ItemSortBy]?,
        sortOrder: [JellyfinAPI.SortOrder]?,
        genres: [String]?,
        years: [Int]?,
        isFavorite: Bool?,
        filters: [ItemFilter]?,
        limit: Int?,
        startIndex: Int?
    ) async throws -> (items: [BaseItemDto], totalCount: Int)
    func getGenres(userId: String, includeItemTypes: [BaseItemKind]?) async throws -> [String]
    func getUserViews(userId: String) async throws -> [BaseItemDto]
    func getItem(userId: String, itemId: String) async throws -> BaseItemDto
    func getSimilarItems(itemId: String, userId: String, limit: Int) async throws -> [BaseItemDto]
    func searchItems(userId: String, searchTerm: String, limit: Int) async throws -> [BaseItemDto]

    // MARK: - Series / Episodes

    func getSeasons(seriesId: String, userId: String) async throws -> [BaseItemDto]
    func getEpisodes(seriesId: String, seasonId: String, userId: String) async throws -> [BaseItemDto]
    func getNextUp(seriesId: String, userId: String) async throws -> BaseItemDto?

    // MARK: - Media Segments

    func getMediaSegments(itemId: String, includeSegmentTypes: [MediaSegmentType]?) async throws -> [MediaSegmentDto]

    // MARK: - Playback

    func getPlaybackInfo(
        itemId: String,
        userId: String,
        maxBitrate: Int,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async throws -> PlaybackInfo

    // MARK: - Playback Reporting

    /// Reports that playback has started. Fire-and-forget; errors are silently ignored.
    func reportPlaybackStart(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, playMethod: PlayMethod) async
    /// Reports current playback position. Fire-and-forget; errors are silently ignored.
    func reportPlaybackProgress(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, isPaused: Bool, playMethod: PlayMethod) async
    /// Reports that playback has stopped at the given position. Fire-and-forget; errors are silently ignored.
    func reportPlaybackStopped(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?) async
}

// MARK: - Default arguments

public extension APIClientProtocol {
    func getResumeItems(userId: String, limit: Int = 10) async throws -> [BaseItemDto] {
        try await getResumeItems(userId: userId, limit: limit)
    }
    func getLatestMedia(userId: String, parentId: String? = nil, limit: Int = 16) async throws -> [BaseItemDto] {
        try await getLatestMedia(userId: userId, parentId: parentId, limit: limit)
    }
    func getItems(
        userId: String,
        parentId: String? = nil,
        includeItemTypes: [BaseItemKind]? = nil,
        sortBy: [ItemSortBy]? = nil,
        sortOrder: [JellyfinAPI.SortOrder]? = nil,
        genres: [String]? = nil,
        years: [Int]? = nil,
        isFavorite: Bool? = nil,
        filters: [ItemFilter]? = nil,
        limit: Int? = nil,
        startIndex: Int? = nil
    ) async throws -> (items: [BaseItemDto], totalCount: Int) {
        try await getItems(
            userId: userId, parentId: parentId, includeItemTypes: includeItemTypes,
            sortBy: sortBy, sortOrder: sortOrder, genres: genres, years: years,
            isFavorite: isFavorite, filters: filters, limit: limit, startIndex: startIndex
        )
    }
    func getGenres(userId: String, includeItemTypes: [BaseItemKind]? = nil) async throws -> [String] {
        try await getGenres(userId: userId, includeItemTypes: includeItemTypes)
    }
    func getSimilarItems(itemId: String, userId: String, limit: Int = 12) async throws -> [BaseItemDto] {
        try await getSimilarItems(itemId: itemId, userId: userId, limit: limit)
    }
    func getActiveSessions(activeWithinSeconds: Int = 60) async throws -> [SessionInfoDto] {
        try await getActiveSessions(activeWithinSeconds: activeWithinSeconds)
    }
    func searchItems(userId: String, searchTerm: String, limit: Int = 20) async throws -> [BaseItemDto] {
        try await searchItems(userId: userId, searchTerm: searchTerm, limit: limit)
    }
    func getMediaSegments(itemId: String, includeSegmentTypes: [MediaSegmentType]? = nil) async throws -> [MediaSegmentDto] {
        try await getMediaSegments(itemId: itemId, includeSegmentTypes: includeSegmentTypes)
    }
    func getPlaybackInfo(
        itemId: String,
        userId: String,
        maxBitrate: Int = 40_000_000,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) async throws -> PlaybackInfo {
        try await getPlaybackInfo(
            itemId: itemId, userId: userId, maxBitrate: maxBitrate,
            audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex
        )
    }
}

// MARK: - Conformance

extension JellyfinAPIClient: APIClientProtocol {}
