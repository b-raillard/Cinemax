import Foundation
import JellyfinAPI
import CinemaxKit

// MARK: - Mock API Client

final class MockAPIClient: APIClientProtocol, @unchecked Sendable {

    // MARK: - Call tracking

    var connectCalled = false
    var authenticateCalled = false
    var reconnectCalled = false

    // MARK: - Stubs

    var stubbedServerInfo = ServerInfo(name: "Mock Server", serverID: "mock-id", version: "10.0.0", url: URL(string: "http://localhost:8096")!)
    var stubbedSession = UserSession(userID: "user1", username: "Test User", accessToken: "mock-token", serverID: "mock-id")
    var stubbedResumeItems: [BaseItemDto] = []
    var stubbedLatestItems: [BaseItemDto] = []
    var stubbedSearchResults: [BaseItemDto] = []
    var stubbedItems: [BaseItemDto] = []
    var stubbedTotalCount = 0
    var stubbedGenres: [String] = []

    /// Called by `getEpisodes(seriesId:seasonId:userId:)` when set, so tests can
    /// inject per-season delays or cancellation-sensitive behavior. Falls back to
    /// an empty array when nil.
    var getEpisodesHandler: (@Sendable (String) async throws -> [BaseItemDto])?

    /// Called by `searchItems(userId:searchTerm:limit:)` when set, so tests can
    /// inject cancellation-sensitive delays. Falls back to `stubbedSearchResults`.
    var searchItemsHandler: (@Sendable (String) async throws -> [BaseItemDto])?

    // MARK: - Error control

    var shouldThrow = false
    var stubbedError: Error = MockError.genericFailure

    // MARK: - APIClientProtocol

    func connectToServer(url: URL) async throws -> ServerInfo {
        connectCalled = true
        if shouldThrow { throw stubbedError }
        return stubbedServerInfo
    }

    func fetchServerInfo() async throws -> ServerInfo {
        if shouldThrow { throw stubbedError }
        return stubbedServerInfo
    }

    func reconnect(url: URL, accessToken: String) {
        reconnectCalled = true
    }

    func authenticate(username: String, password: String) async throws -> UserSession {
        authenticateCalled = true
        if shouldThrow { throw stubbedError }
        return stubbedSession
    }

    func getPublicUsers() async throws -> [UserDto] { [] }
    func getUsers() async throws -> [UserDto] { [] }
    func getActiveSessions(activeWithinSeconds: Int) async throws -> [SessionInfoDto] { [] }
    func getDevices() async throws -> [DeviceInfoDto] { [] }
    func deleteDevice(id: String) async throws {}

    // MARK: - Cache

    func clearCache() {}
    func applyContentRatingLimit(maxAge: Int) {}

    func getResumeItems(userId: String, limit: Int) async throws -> [BaseItemDto] {
        if shouldThrow { throw stubbedError }
        return stubbedResumeItems
    }

    func getLatestMedia(userId: String, parentId: String?, limit: Int) async throws -> [BaseItemDto] {
        if shouldThrow { throw stubbedError }
        return stubbedLatestItems
    }

    func getItems(
        userId: String, parentId: String?, includeItemTypes: [BaseItemKind]?,
        sortBy: [ItemSortBy]?, sortOrder: [JellyfinAPI.SortOrder]?,
        genres: [String]?, years: [Int]?, isFavorite: Bool?,
        filters: [ItemFilter]?, limit: Int?, startIndex: Int?
    ) async throws -> (items: [BaseItemDto], totalCount: Int) {
        if shouldThrow { throw stubbedError }
        return (stubbedItems, stubbedTotalCount)
    }

    func getGenres(userId: String, includeItemTypes: [BaseItemKind]?) async throws -> [String] {
        if shouldThrow { throw stubbedError }
        return stubbedGenres
    }

    func getUserViews(userId: String) async throws -> [BaseItemDto] { [] }

    func getItem(userId: String, itemId: String) async throws -> BaseItemDto {
        if shouldThrow { throw stubbedError }
        return BaseItemDto()
    }

    func getSimilarItems(itemId: String, userId: String, limit: Int) async throws -> [BaseItemDto] { [] }

    func searchItems(userId: String, searchTerm: String, limit: Int) async throws -> [BaseItemDto] {
        if let handler = searchItemsHandler {
            return try await handler(searchTerm)
        }
        if shouldThrow { throw stubbedError }
        return stubbedSearchResults
    }

    func getSeasons(seriesId: String, userId: String) async throws -> [BaseItemDto] { [] }
    func getEpisodes(seriesId: String, seasonId: String, userId: String) async throws -> [BaseItemDto] {
        if let handler = getEpisodesHandler {
            return try await handler(seasonId)
        }
        return []
    }
    func getNextUp(seriesId: String, userId: String) async throws -> BaseItemDto? { nil }
    func markItemUnplayed(itemId: String, userId: String) async throws {}

    // MARK: - Media Segments

    func getMediaSegments(itemId: String, includeSegmentTypes: [MediaSegmentType]?) async throws -> [MediaSegmentDto] { [] }

    // `PlayMethod` is disambiguated with `CinemaxKit.` prefix because JellyfinAPI
    // exports a type of the same name; Swift can't tell which one the protocol
    // signature refers to without the explicit module qualifier.
    func reportPlaybackStart(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, playMethod: CinemaxKit.PlayMethod) async {}
    func reportPlaybackProgress(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, isPaused: Bool, playMethod: CinemaxKit.PlayMethod) async {}
    func reportPlaybackStopped(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?) async {}

    func getPlaybackInfo(
        itemId: String, userId: String, maxBitrate: Int,
        audioStreamIndex: Int?, subtitleStreamIndex: Int?
    ) async throws -> PlaybackInfo {
        if shouldThrow { throw stubbedError }
        return PlaybackInfo(
            url: URL(string: "http://localhost/stream")!,
            playSessionId: "session1",
            mediaSourceId: itemId,
            playMethod: .directStream,
            audioTracks: [], subtitleTracks: [],
            selectedAudioIndex: nil, selectedSubtitleIndex: nil,
            authToken: "mock-token"
        )
    }
}

// MARK: - Mock Keychain

final class MockKeychain: SecureStorageProtocol, @unchecked Sendable {
    var savedAccessToken: String?
    var savedServerURL: URL?
    var savedSession: UserSession?
    var shouldThrowOnSave = false

    func saveAccessToken(_ token: String) throws {
        if shouldThrowOnSave { throw MockError.genericFailure }
        savedAccessToken = token
    }
    func getAccessToken() -> String? { savedAccessToken }
    func deleteAccessToken() { savedAccessToken = nil }

    func saveServerURL(_ url: URL) throws {
        if shouldThrowOnSave { throw MockError.genericFailure }
        savedServerURL = url
    }
    func getServerURL() -> URL? { savedServerURL }
    func deleteServerURL() { savedServerURL = nil }

    func saveUserSession(_ session: UserSession) throws {
        if shouldThrowOnSave { throw MockError.genericFailure }
        savedSession = session
    }
    func getUserSession() -> UserSession? { savedSession }
    func deleteUserSession() { savedSession = nil }

    func clearAll() {
        savedAccessToken = nil
        savedServerURL = nil
        savedSession = nil
    }
}

// MARK: - Error

enum MockError: Error {
    case genericFailure
}
