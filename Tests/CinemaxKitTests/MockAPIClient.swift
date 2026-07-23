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
    var stubbedUserViews: [BaseItemDto] = []

    /// Called by `getEpisodes(seriesId:seasonId:userId:)` when set, so tests can
    /// inject per-season delays or cancellation-sensitive behavior. Falls back to
    /// an empty array when nil.
    var getEpisodesHandler: (@Sendable (String) async throws -> [BaseItemDto])?

    /// Called by `searchItems(userId:searchTerm:limit:)` when set, so tests can
    /// inject cancellation-sensitive delays. Falls back to `stubbedSearchResults`.
    var searchItemsHandler: (@Sendable (String) async throws -> [BaseItemDto])?

    /// Called by `getItems(...)` when set, keyed on `startIndex`, so pagination
    /// tests can return a different page per call. Falls back to the flat
    /// `stubbedItems`/`stubbedTotalCount` pair when nil.
    var getItemsHandler: (@Sendable (Int?) async throws -> ([BaseItemDto], Int))?

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

    var stubbedValidity: SessionValidity = .valid
    var validateSessionDelayMs: UInt64 = 0
    private(set) var validateSessionCallCount = 0
    func validateSession() async -> SessionValidity {
        validateSessionCallCount += 1
        if validateSessionDelayMs > 0 {
            try? await Task.sleep(nanoseconds: validateSessionDelayMs * 1_000_000)
        }
        return stubbedValidity
    }

    func isQuickConnectEnabled() async throws -> Bool { false }
    func initiateQuickConnect() async throws -> QuickConnectRequest {
        if shouldThrow { throw stubbedError }
        return QuickConnectRequest(code: "123456", secret: "secret")
    }
    func quickConnectAuthorized(secret: String) async throws -> Bool { true }
    func authenticateWithQuickConnect(secret: String) async throws -> UserSession {
        if shouldThrow { throw stubbedError }
        return stubbedSession
    }
    private(set) var authorizeQuickConnectCalls: [String] = []
    var stubbedAuthorizeQuickConnectResult = true
    func authorizeQuickConnect(code: String) async throws -> Bool {
        authorizeQuickConnectCalls.append(code)
        if shouldThrow { throw stubbedError }
        return stubbedAuthorizeQuickConnectResult
    }

    func getPublicUsers() async throws -> [UserDto] { [] }
    func getUsers() async throws -> [UserDto] { [] }
    func getActiveSessions(activeWithinSeconds: Int) async throws -> [SessionInfoDto] { [] }
    func getDevices() async throws -> [DeviceInfoDto] { [] }
    func deleteDevice(id: String) async throws {}

    // MARK: - Admin

    var stubbedUserByID: UserDto = UserDto()
    var stubbedCreatedUser: UserDto = UserDto()
    var stubbedMediaFolders: [BaseItemDto] = []
    var stubbedActivityLogEntries: [ActivityLogEntry] = []
    var stubbedActivityLogTotal: Int = 0
    var stubbedSystemInfo: SystemInfo = SystemInfo()

    func getUserByID(id: String) async throws -> UserDto {
        if shouldThrow { throw stubbedError }
        return stubbedUserByID
    }
    func createUserByName(name: String, password: String?) async throws -> UserDto {
        if shouldThrow { throw stubbedError }
        return stubbedCreatedUser
    }
    func updateUser(id: String, user: UserDto) async throws {
        if shouldThrow { throw stubbedError }
    }
    func updateUserPolicy(id: String, policy: UserPolicy) async throws {
        if shouldThrow { throw stubbedError }
    }
    func updateUserPassword(id: String, newPassword: String, resetPassword: Bool) async throws {
        if shouldThrow { throw stubbedError }
    }
    func deleteUser(id: String) async throws {
        if shouldThrow { throw stubbedError }
    }
    func getMediaFolders() async throws -> [BaseItemDto] {
        if shouldThrow { throw stubbedError }
        return stubbedMediaFolders
    }
    func getActivityLogEntries(startIndex: Int, limit: Int, minDate: Date?) async throws -> (entries: [ActivityLogEntry], total: Int) {
        if shouldThrow { throw stubbedError }
        return (stubbedActivityLogEntries, stubbedActivityLogTotal)
    }
    func getSystemInfo() async throws -> SystemInfo {
        if shouldThrow { throw stubbedError }
        return stubbedSystemInfo
    }

    // MARK: - Admin P2

    var stubbedPlugins: [PluginInfo] = []
    var stubbedPackages: [PackageInfo] = []
    var stubbedTasks: [TaskInfo] = []
    var stubbedEncodingOptions: EncodingOptions = EncodingOptions()

    func getInstalledPlugins() async throws -> [PluginInfo] {
        if shouldThrow { throw stubbedError }
        return stubbedPlugins
    }
    func enablePlugin(id: String, version: String) async throws {
        if shouldThrow { throw stubbedError }
    }
    func disablePlugin(id: String, version: String) async throws {
        if shouldThrow { throw stubbedError }
    }
    func uninstallPlugin(id: String, version: String) async throws {
        if shouldThrow { throw stubbedError }
    }
    func getPluginCatalog() async throws -> [PackageInfo] {
        if shouldThrow { throw stubbedError }
        return stubbedPackages
    }
    func installPackage(name: String, assemblyGuid: String?, version: String?, repositoryURL: String?) async throws {
        if shouldThrow { throw stubbedError }
    }
    func getScheduledTasks(includeHidden: Bool) async throws -> [TaskInfo] {
        if shouldThrow { throw stubbedError }
        return stubbedTasks
    }
    func startTask(id: String) async throws {
        if shouldThrow { throw stubbedError }
    }
    func stopTask(id: String) async throws {
        if shouldThrow { throw stubbedError }
    }
    func getEncodingOptions() async throws -> EncodingOptions {
        if shouldThrow { throw stubbedError }
        return stubbedEncodingOptions
    }
    func updateEncodingOptions(_ options: EncodingOptions) async throws {
        if shouldThrow { throw stubbedError }
    }

    // MARK: - Admin P3a (Network / Logs / API Keys)

    var stubbedNetworkConfiguration: NetworkConfiguration = NetworkConfiguration()
    var stubbedServerLogs: [LogFile] = []
    var stubbedLogFileContents: String = ""
    var stubbedApiKeys: [AuthenticationInfo] = []

    func getNetworkConfiguration() async throws -> NetworkConfiguration {
        if shouldThrow { throw stubbedError }
        return stubbedNetworkConfiguration
    }
    func updateNetworkConfiguration(_ config: NetworkConfiguration) async throws {
        if shouldThrow { throw stubbedError }
    }
    func getServerLogs() async throws -> [LogFile] {
        if shouldThrow { throw stubbedError }
        return stubbedServerLogs
    }
    func getLogFileContents(name: String) async throws -> String {
        if shouldThrow { throw stubbedError }
        return stubbedLogFileContents
    }
    func getApiKeys() async throws -> [AuthenticationInfo] {
        if shouldThrow { throw stubbedError }
        return stubbedApiKeys
    }
    func createApiKey(app: String) async throws {
        if shouldThrow { throw stubbedError }
    }
    func revokeApiKey(key: String) async throws {
        if shouldThrow { throw stubbedError }
    }

    // MARK: - Admin P3b (Metadata)

    var stubbedRemoteResults: [RemoteSearchResult] = []

    func updateItem(id: String, item: BaseItemDto) async throws {
        if shouldThrow { throw stubbedError }
    }
    func refreshItem(id: String, metadataMode: MetadataRefreshMode, imageMode: MetadataRefreshMode, replaceAllMetadata: Bool, replaceAllImages: Bool) async throws {
        if shouldThrow { throw stubbedError }
    }
    func deleteItem(id: String) async throws {
        if shouldThrow { throw stubbedError }
    }
    func downloadRemoteImage(itemId: String, type: JellyfinAPI.ImageType, imageURL: String) async throws {
        if shouldThrow { throw stubbedError }
    }
    func deleteItemImage(id: String, type: JellyfinAPI.ImageType, index: Int?) async throws {
        if shouldThrow { throw stubbedError }
    }
    func searchRemoteMovies(query: MovieInfoRemoteSearchQuery) async throws -> [RemoteSearchResult] {
        if shouldThrow { throw stubbedError }
        return stubbedRemoteResults
    }
    func searchRemoteSeries(query: SeriesInfoRemoteSearchQuery) async throws -> [RemoteSearchResult] {
        if shouldThrow { throw stubbedError }
        return stubbedRemoteResults
    }
    func applyRemoteSearchResult(itemId: String, result: RemoteSearchResult, replaceAllImages: Bool) async throws {
        if shouldThrow { throw stubbedError }
    }

    // MARK: - Cache

    func clearCache() {}
    func applyContentRatingLimit(maxAge: Int) {}

    // Call counters — let tests assert which fetches a targeted refresh touches.
    private(set) var getResumeItemsCallCount = 0
    private(set) var getLatestMediaCallCount = 0
    private(set) var getGenresCallCount = 0
    /// Count of `getItems` calls scoped to favorites (`isFavorite == true`),
    /// distinguishing the Favorites-row fetch from genre-row fetches.
    private(set) var favoriteFetchCount = 0
    /// Every `getItems` call's `startIndex`/`limit`, in order — lets pagination
    /// tests assert the loader requested the right page (`PaginatedLoader`
    /// passes `items.count` as `startIndex`).
    private(set) var getItemsCalls: [(startIndex: Int?, limit: Int?)] = []

    func getResumeItems(userId: String, limit: Int) async throws -> [BaseItemDto] {
        getResumeItemsCallCount += 1
        if shouldThrow { throw stubbedError }
        return stubbedResumeItems
    }

    func getLatestMedia(userId: String, parentId: String?, limit: Int) async throws -> [BaseItemDto] {
        getLatestMediaCallCount += 1
        if shouldThrow { throw stubbedError }
        return stubbedLatestItems
    }

    func getItems(
        userId: String, parentId: String?, includeItemTypes: [BaseItemKind]?,
        sortBy: [ItemSortBy]?, sortOrder: [JellyfinAPI.SortOrder]?,
        genres: [String]?, years: [Int]?, isFavorite: Bool?,
        filters: [ItemFilter]?, limit: Int?, startIndex: Int?
    ) async throws -> (items: [BaseItemDto], totalCount: Int) {
        if isFavorite == true { favoriteFetchCount += 1 }
        getItemsCalls.append((startIndex: startIndex, limit: limit))
        if shouldThrow { throw stubbedError }
        if let handler = getItemsHandler {
            return try await handler(startIndex)
        }
        return (stubbedItems, stubbedTotalCount)
    }

    func getGenres(userId: String, includeItemTypes: [BaseItemKind]?) async throws -> [String] {
        getGenresCallCount += 1
        if shouldThrow { throw stubbedError }
        return stubbedGenres
    }

    func getUserViews(userId: String) async throws -> [BaseItemDto] {
        if shouldThrow { throw stubbedError }
        return stubbedUserViews
    }

    /// Count of `getItem` calls + an optional per-itemId handler so tests can
    /// inject fresh userData / delays / cancellation-sensitive behavior
    /// (mirrors `getEpisodesHandler`). Falls back to an empty `BaseItemDto`.
    private(set) var getItemCallCount = 0
    var getItemHandler: (@Sendable (String) async throws -> BaseItemDto)?
    func getItem(userId: String, itemId: String) async throws -> BaseItemDto {
        getItemCallCount += 1
        if let handler = getItemHandler {
            return try await handler(itemId)
        }
        if shouldThrow { throw stubbedError }
        return BaseItemDto()
    }

    private(set) var getSimilarItemsCallCount = 0
    func getSimilarItems(itemId: String, userId: String, limit: Int) async throws -> [BaseItemDto] {
        getSimilarItemsCallCount += 1
        return []
    }

    func searchItems(userId: String, searchTerm: String, includeItemTypes: [BaseItemKind], limit: Int) async throws -> [BaseItemDto] {
        if let handler = searchItemsHandler {
            return try await handler(searchTerm)
        }
        if shouldThrow { throw stubbedError }
        return stubbedSearchResults
    }

    private(set) var getSeasonsCallCount = 0
    func getSeasons(seriesId: String, userId: String) async throws -> [BaseItemDto] {
        getSeasonsCallCount += 1
        return []
    }
    private(set) var getEpisodesCallCount = 0
    func getEpisodes(seriesId: String, seasonId: String, userId: String) async throws -> [BaseItemDto] {
        getEpisodesCallCount += 1
        if let handler = getEpisodesHandler {
            return try await handler(seasonId)
        }
        return []
    }
    var stubbedNextUp: BaseItemDto?
    private(set) var getNextUpCallCount = 0
    func getNextUp(seriesId: String, userId: String) async throws -> BaseItemDto? {
        getNextUpCallCount += 1
        return stubbedNextUp
    }
    var stubbedNextUpItems: [BaseItemDto] = []
    private(set) var getNextUpEpisodesCallCount = 0
    func getNextUpEpisodes(userId: String, limit: Int) async throws -> [BaseItemDto] {
        getNextUpEpisodesCallCount += 1
        if shouldThrow { throw stubbedError }
        return stubbedNextUpItems
    }
    private(set) var markPlayedCalls: [String] = []
    private(set) var markUnplayedCalls: [String] = []
    func markItemUnplayed(itemId: String, userId: String) async throws { markUnplayedCalls.append(itemId) }
    func markItemPlayed(itemId: String, userId: String) async throws { markPlayedCalls.append(itemId) }
    func setFavorite(itemId: String, userId: String, favorite: Bool) async throws {}
    func getPersonItems(personId: String, userId: String, limit: Int) async throws -> [BaseItemDto] { [] }
    func getCollections(containingItemId: String, tmdbCollectionId: String?, userId: String) async throws -> [BaseItemDto] { [] }

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
        audioStreamIndex: Int?, subtitleStreamIndex: Int?,
        engine: VideoPlaybackEngine
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
