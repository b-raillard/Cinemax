import Foundation
import JellyfinAPI
import CinemaxKit

// MARK: - Mock API Client

final class MockAPIClient: APIClientProtocol, @unchecked Sendable {

    // MARK: - Call tracking

    /// Serializes every mutation of the call-recording state below. View
    /// models fan out concurrent TaskGroup calls into this mock (Home
    /// phase-1, the genre-row chunk-of-6, the season-episode dedupe), and an
    /// unsynchronized `Array.append` / `+= 1` from parallel tasks corrupts
    /// the heap — intermittent SIGSEGV in `Array.append` mid-suite. Tests
    /// READ the recorded state only after awaiting the work (task joins give
    /// happens-before), so locking the writes is sufficient.
    private let recordLock = NSLock()

    var connectCalled = false
    var authenticateCalled = false
    var reconnectCalled = false

    // MARK: - Stubs

    var stubbedServerInfo = ServerInfo(name: "Mock Server", serverID: "mock-id", version: "10.0.0", url: URL(string: "http://localhost:8096")!)
    var stubbedSession = UserSession(userID: "user1", username: "Test User", accessToken: "mock-token", serverID: "mock-id")
    var stubbedResumeItems: [BaseItemDto] = []
    var stubbedLatestItems: [BaseItemDto] = []
    var stubbedSearchResults: [BaseItemDto] = []
    var stubbedPersonResults: [BaseItemDto] = []
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

    /// Called by `searchPersons(userId:searchTerm:limit:)` when set, so a test
    /// can fail the person fetch independently of the title fetch. Falls back to
    /// `stubbedPersonResults`.
    var searchPersonsHandler: (@Sendable (String) async throws -> [BaseItemDto])?

    /// Called by `getItems(...)` when set, keyed on `startIndex`, so pagination
    /// tests can return a different page per call. Falls back to the flat
    /// `stubbedItems`/`stubbedTotalCount` pair when nil.
    var getItemsHandler: (@Sendable (Int?) async throws -> ([BaseItemDto], Int))?

    // MARK: - Error control

    var shouldThrow = false
    var stubbedError: Error = MockError.genericFailure

    // MARK: - APIClientProtocol

    func connectToServer(url: URL) async throws -> ServerInfo {
        recordLock.withLock { connectCalled = true }
        if shouldThrow { throw stubbedError }
        return stubbedServerInfo
    }

    func fetchServerInfo() async throws -> ServerInfo {
        if shouldThrow { throw stubbedError }
        return stubbedServerInfo
    }

    /// Every `reconnect` the code performed, in order — the multi-server switch
    /// tests assert both the count (one commit, not a storm) and the target.
    private(set) var reconnectedURLs: [URL] = []
    private(set) var reconnectedTokens: [String] = []

    func reconnect(url: URL, accessToken: String) {
        recordLock.withLock {
            reconnectCalled = true
            reconnectedURLs.append(url)
            reconnectedTokens.append(accessToken)
        }
    }

    func authenticate(username: String, password: String) async throws -> UserSession {
        recordLock.withLock { authenticateCalled = true }
        if shouldThrow { throw stubbedError }
        return stubbedSession
    }

    var stubbedValidity: SessionValidity = .valid
    var validateSessionDelayMs: UInt64 = 0
    private(set) var validateSessionCallCount = 0
    func validateSession() async -> SessionValidity {
        recordLock.withLock { validateSessionCallCount += 1 }
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
    /// Called by `quickConnectAuthorized(secret:)` when set, with the 1-based
    /// poll index, so tests can throw for the first N polls (transient-failure
    /// resilience). Falls back to an immediate `true`.
    var quickConnectAuthorizedHandler: (@Sendable (Int) async throws -> Bool)?
    private var pollCount = 0
    /// Lock-guarded on READ too (unlike the other counters): the Quick Connect
    /// tests poll it live from the main actor while the VM's poll Task is still
    /// writing it, so "read only after awaiting the work" doesn't apply here.
    var quickConnectPollCount: Int { recordLock.withLock { pollCount } }
    func quickConnectAuthorized(secret: String) async throws -> Bool {
        let index = recordLock.withLock { () -> Int in
            pollCount += 1
            return pollCount
        }
        if let quickConnectAuthorizedHandler {
            return try await quickConnectAuthorizedHandler(index)
        }
        return true
    }
    func authenticateWithQuickConnect(secret: String) async throws -> UserSession {
        if shouldThrow { throw stubbedError }
        return stubbedSession
    }
    private(set) var authorizeQuickConnectCalls: [String] = []
    var stubbedAuthorizeQuickConnectResult = true
    func authorizeQuickConnect(code: String) async throws -> Bool {
        recordLock.withLock { authorizeQuickConnectCalls.append(code) }
        if shouldThrow { throw stubbedError }
        return stubbedAuthorizeQuickConnectResult
    }

    func getPublicUsers() async throws -> [UserDto] { [] }
    func getUsers() async throws -> [UserDto] { [] }
    func getActiveSessions(activeWithinSeconds: Int) async throws -> [SessionInfoDto] { [] }
    func getDevices() async throws -> [DeviceInfoDto] { [] }
    func deleteDevice(id: String) async throws {}

    // MARK: - Remote control ("Play on…")

    var stubbedControllableSessions: [SessionInfoDto] = []
    var controllableSessionsError: Error?
    private(set) var controllableSessionsCallCount = 0
    /// Every `playOnSession` call, in order. Read the fields individually — the
    /// tuple isn't `Equatable`.
    private(set) var playOnSessionCalls: [(sessionId: String, itemIds: [String], startPositionTicks: Int?, mediaSourceId: String?)] = []
    var playOnSessionError: Error?

    func getControllableSessions(userId: String) async throws -> [SessionInfoDto] {
        recordLock.withLock { controllableSessionsCallCount += 1 }
        if let controllableSessionsError { throw controllableSessionsError }
        return stubbedControllableSessions
    }

    func playOnSession(
        sessionId: String,
        itemIds: [String],
        startPositionTicks: Int?,
        mediaSourceId: String?
    ) async throws {
        recordLock.withLock {
            playOnSessionCalls.append((sessionId, itemIds, startPositionTicks, mediaSourceId))
        }
        if let playOnSessionError { throw playOnSessionError }
    }

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
    var stubbedRemoteImages: [RemoteImageCandidate] = []

    /// Optional barrier letting a test hold `getRemoteImages` mid-flight and
    /// supersede it. The race is a network round-trip wide, so it is not
    /// reachable by gesture automation — same reason `PaginatedLoaderInterlockTests`
    /// holds its window open explicitly instead of hoping to cross it.
    var remoteImagesGate: (@Sendable () async -> Void)?

    func getRemoteImages(
        itemId: String,
        type: JellyfinAPI.ImageType,
        includeAllLanguages: Bool,
        limit: Int,
        preferredLanguage: String?
    ) async throws -> [RemoteImageCandidate] {
        if let remoteImagesGate { await remoteImagesGate() }
        if shouldThrow { throw stubbedError }
        return stubbedRemoteImages
    }

    /// Records every applied artwork so a test can assert WHICH image was
    /// pinned, not merely that something was.
    var downloadedImages: [(itemId: String, type: JellyfinAPI.ImageType, imageURL: String)] = []

    func downloadRemoteImage(itemId: String, type: JellyfinAPI.ImageType, imageURL: String) async throws {
        if shouldThrow { throw stubbedError }
        downloadedImages.append((itemId: itemId, type: type, imageURL: imageURL))
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

    private(set) var clearCacheCallCount = 0
    private(set) var appliedRatingLimits: [Int] = []

    func clearCache() {
        recordLock.withLock { clearCacheCallCount += 1 }
    }

    func applyContentRatingLimit(maxAge: Int) {
        recordLock.withLock { appliedRatingLimits.append(maxAge) }
    }

    // Call counters — let tests assert which fetches a targeted refresh touches.
    private(set) var getResumeItemsCallCount = 0
    private(set) var getLatestMediaCallCount = 0
    /// The letter the last `/Items` page was anchored on — `nil` for an
    /// ordinary page. Drives the A–Z jump-bar tests (defect M).
    private(set) var lastNameAnchor: String?
    private(set) var getGenresCallCount = 0
    /// The scope the last `getGenres` was asked for — `nil` means server-wide.
    /// A scoped library must never ask server-wide (defect L).
    private(set) var lastGenresParentId: String?
    /// Count of `getItems` calls scoped to favorites (`isFavorite == true`),
    /// distinguishing the Favorites-row fetch from genre-row fetches.
    private(set) var favoriteFetchCount = 0
    /// Every `getItems` call's `startIndex`/`limit`, in order — lets pagination
    /// tests assert the loader requested the right page (`PaginatedLoader`
    /// passes `items.count` as `startIndex`).
    private(set) var getItemsCalls: [(startIndex: Int?, limit: Int?)] = []
    /// Full query shape of every `getItems` call, so a test can assert WHAT was
    /// asked for and not just how it was paginated. Kept separate from
    /// `getItemsCalls` so existing pagination assertions stay untouched.
    private(set) var getItemsQueries: [(
        includeItemTypes: [BaseItemKind]?,
        sortBy: [ItemSortBy]?,
        sortOrder: [JellyfinAPI.SortOrder]?,
        isFavorite: Bool?,
        limit: Int?
    )] = []

    func getResumeItems(userId: String, limit: Int) async throws -> [BaseItemDto] {
        recordLock.withLock { getResumeItemsCallCount += 1 }
        if shouldThrow { throw stubbedError }
        return stubbedResumeItems
    }

    func getLatestMedia(userId: String, parentId: String?, limit: Int) async throws -> [BaseItemDto] {
        recordLock.withLock { getLatestMediaCallCount += 1 }
        if shouldThrow { throw stubbedError }
        return stubbedLatestItems
    }

    /// Shows that just received episodes — the second source of Home's
    /// "Recently Added" row.
    var stubbedSeriesWithRecentEpisodes: [BaseItemDto] = []
    /// Dedicated flag, never `shouldThrow`: several suites turn that on while
    /// expecting this source to keep succeeding, and the row's whole point is
    /// that its two sources fail independently.
    var seriesWithRecentEpisodesShouldThrow = false
    private(set) var seriesWithRecentEpisodesCallCount = 0
    private(set) var seriesWithRecentEpisodesLimits: [Int] = []
    func getSeriesWithRecentEpisodes(userId: String, limit: Int) async throws -> [BaseItemDto] {
        recordLock.withLock {
            seriesWithRecentEpisodesCallCount += 1
            seriesWithRecentEpisodesLimits.append(limit)
        }
        if seriesWithRecentEpisodesShouldThrow { throw stubbedError }
        return stubbedSeriesWithRecentEpisodes
    }

    func getItems(
        userId: String, parentId: String?, includeItemTypes: [BaseItemKind]?,
        sortBy: [ItemSortBy]?, sortOrder: [JellyfinAPI.SortOrder]?,
        genres: [String]?, years: [Int]?, isFavorite: Bool?,
        filters: [ItemFilter]?, nameStartsWithOrGreater: String?,
        limit: Int?, startIndex: Int?
    ) async throws -> (items: [BaseItemDto], totalCount: Int) {
        recordLock.withLock {
            if isFavorite == true { favoriteFetchCount += 1 }
            lastNameAnchor = nameStartsWithOrGreater
            getItemsCalls.append((startIndex: startIndex, limit: limit))
            getItemsQueries.append((
                includeItemTypes: includeItemTypes, sortBy: sortBy,
                sortOrder: sortOrder, isFavorite: isFavorite, limit: limit
            ))
        }
        if shouldThrow { throw stubbedError }
        if let handler = getItemsHandler {
            return try await handler(startIndex)
        }
        // Home's "Recently Added" rail is a date-added query over movies and
        // series (it used to be `/Items/Latest`, which let one show's episode
        // import collapse the whole row into a single grouped card). Routed by
        // query shape so it keeps its own stub — the favorites rail issues the
        // same query plus `isFavorite`, which is what tells the two apart.
        if includeItemTypes == [.movie, .series], isFavorite == nil {
            return (stubbedLatestItems, stubbedLatestItems.count)
        }
        return (stubbedItems, stubbedTotalCount)
    }

    func getGenres(userId: String, parentId: String?, includeItemTypes: [BaseItemKind]?) async throws -> [String] {
        recordLock.withLock {
            getGenresCallCount += 1
            lastGenresParentId = parentId
        }
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
        recordLock.withLock { getItemCallCount += 1 }
        if let handler = getItemHandler {
            return try await handler(itemId)
        }
        if shouldThrow { throw stubbedError }
        return BaseItemDto()
    }

    /// When set, `getItemUserData` returns it — simulating a server new enough
    /// to expose `GET /UserItems/{id}/UserData`. Left nil, this type inherits
    /// `LibraryAPI`'s default (`nil` = unsupported), so every pre-existing test
    /// keeps exercising the full-item fallback inside `fetchUserData`.
    var stubbedItemUserData: UserItemDataDto?
    private(set) var getItemUserDataCallCount = 0
    func getItemUserData(itemId: String, userId: String) async throws -> UserItemDataDto? {
        recordLock.withLock { getItemUserDataCallCount += 1 }
        if shouldThrow { throw stubbedError }
        return stubbedItemUserData
    }

    /// Playlists served to the Home rail. `PlaylistAPI` ships default no-op
    /// implementations so hand-written mocks compile without stubbing the
    /// whole slice — this overrides only the read the rail depends on.
    var stubbedPlaylists: [BaseItemDto] = []
    private(set) var getPlaylistsCallCount = 0
    func getPlaylists(userId: String) async throws -> [BaseItemDto] {
        recordLock.withLock { getPlaylistsCallCount += 1 }
        if shouldThrow { throw stubbedError }
        return stubbedPlaylists
    }

    /// Playlist contents, in playlist order and carrying entry ids.
    var stubbedPlaylistItems: [BaseItemDto] = []
    /// Every `movePlaylistItem` call, in order.
    private(set) var moveCalls: [(entryId: String, newIndex: Int)] = []
    var shouldFailPlaylistMove = false
    func getPlaylistItems(playlistId: String, userId: String) async throws -> [BaseItemDto] {
        if shouldThrow { throw stubbedError }
        return stubbedPlaylistItems
    }
    func movePlaylistItem(playlistId: String, entryId: String, newIndex: Int) async throws {
        recordLock.withLock { moveCalls.append((entryId: entryId, newIndex: newIndex)) }
        if shouldFailPlaylistMove { throw stubbedError }
    }

    private(set) var getSimilarItemsCallCount = 0
    func getSimilarItems(itemId: String, userId: String, limit: Int) async throws -> [BaseItemDto] {
        recordLock.withLock { getSimilarItemsCallCount += 1 }
        return []
    }

    func searchItems(userId: String, searchTerm: String, includeItemTypes: [BaseItemKind], limit: Int) async throws -> [BaseItemDto] {
        if let handler = searchItemsHandler {
            return try await handler(searchTerm)
        }
        if shouldThrow { throw stubbedError }
        return stubbedSearchResults
    }

    private(set) var searchPersonsCallCount = 0
    func searchPersons(userId: String, searchTerm: String, limit: Int) async throws -> [BaseItemDto] {
        recordLock.withLock { searchPersonsCallCount += 1 }
        if let handler = searchPersonsHandler {
            return try await handler(searchTerm)
        }
        if shouldThrow { throw stubbedError }
        return stubbedPersonResults
    }

    private(set) var getSeasonsCallCount = 0
    var getSeasonsHandler: (@Sendable (String) async throws -> [BaseItemDto])?
    func getSeasons(seriesId: String, userId: String) async throws -> [BaseItemDto] {
        recordLock.withLock { getSeasonsCallCount += 1 }
        if let handler = getSeasonsHandler {
            return try await handler(seriesId)
        }
        return []
    }
    private(set) var getEpisodesCallCount = 0
    func getEpisodes(seriesId: String, seasonId: String, userId: String) async throws -> [BaseItemDto] {
        recordLock.withLock { getEpisodesCallCount += 1 }
        if let handler = getEpisodesHandler {
            return try await handler(seasonId)
        }
        return []
    }
    var stubbedNextUp: BaseItemDto?
    /// Drapeau **dédié**, distinct de `shouldThrow` : plusieurs suites existantes
    /// activent `shouldThrow` tout en laissant `getNextUp` réussir, et les faire
    /// basculer d'un coup changerait leur comportement sans rapport avec ce lot.
    var nextUpShouldThrow = false
    /// When set, `getNextUp` sleeps this long before returning — simulates a
    /// cold-cache / slow-server next-up probe so `CardPlayTargetResolver`'s
    /// deadline race is testable, without touching `nextUpShouldThrow`'s error
    /// path (same "dedicated flag" rationale as that one).
    var nextUpDelay: Duration?
    private(set) var getNextUpCallCount = 0
    /// Incremented only when the call runs all the way through — so a test can
    /// tell "the probe was started" from "the probe was allowed to finish". The
    /// distinction is the whole point of not cancelling the deadline's loser:
    /// `getNextUp` warms its 10 s cache on completion, not on entry.
    ///
    /// Note the `try?` on the sleep below deliberately swallows
    /// `CancellationError`, mirroring a non-cancellable await inside a real
    /// implementation — which is what makes this counter meaningful rather than
    /// a restatement of the cancellation.
    private(set) var getNextUpCompletedCount = 0
    func getNextUp(seriesId: String, userId: String) async throws -> BaseItemDto? {
        recordLock.withLock { getNextUpCallCount += 1 }
        if let nextUpDelay {
            try? await Task.sleep(for: nextUpDelay)
        }
        if nextUpShouldThrow { throw stubbedError }
        recordLock.withLock { getNextUpCompletedCount += 1 }
        return stubbedNextUp
    }
    var stubbedNextUpItems: [BaseItemDto] = []
    private(set) var getNextUpEpisodesCallCount = 0
    func getNextUpEpisodes(userId: String, limit: Int) async throws -> [BaseItemDto] {
        recordLock.withLock { getNextUpEpisodesCallCount += 1 }
        if shouldThrow { throw stubbedError }
        return stubbedNextUpItems
    }
    private(set) var markPlayedCalls: [String] = []
    private(set) var markUnplayedCalls: [String] = []
    func markItemUnplayed(itemId: String, userId: String) async throws { recordLock.withLock { markUnplayedCalls.append(itemId) } }
    func markItemPlayed(itemId: String, userId: String) async throws { recordLock.withLock { markPlayedCalls.append(itemId) } }
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
    func reportPlaybackStopped(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, liveStreamId: String?) async {}

    func getPlaybackInfo(
        itemId: String, userId: String, maxBitrate: Int,
        audioStreamIndex: Int?, subtitleStreamIndex: Int?,
        engine: VideoPlaybackEngine, mediaSourceId: String?
    ) async throws -> PlaybackInfo {
        if shouldThrow { throw stubbedError }
        return PlaybackInfo(
            url: URL(string: "http://localhost/stream")!,
            playSessionId: "session1",
            // Echo the requested version back so tests can assert the override
            // reached the API rather than being dropped in the plumbing.
            mediaSourceId: mediaSourceId ?? itemId,
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

    /// Mirrors `KeychainService.clearAll()`: the legacy trio only. The
    /// multi-server registry deliberately survives a logout.
    func clearAll() {
        savedAccessToken = nil
        savedServerURL = nil
        savedSession = nil
    }

    // MARK: - Multi-server registry (in-memory)

    var savedServers: [ServerEntry] = []
    var savedActiveServerId: String?

    func getServers() -> [ServerEntry] { savedServers }

    func saveServers(_ entries: [ServerEntry]) throws {
        if shouldThrowOnSave { throw MockError.genericFailure }
        savedServers = entries
    }

    func getActiveServerId() -> String? { savedActiveServerId }

    func saveActiveServerId(_ id: String?) { savedActiveServerId = id }

    // `migrateToMultiServerIfNeeded()` is deliberately NOT overridden — the
    // `SecureStorageProtocol` extension carries the one implementation, so a
    // migration test drives the exact code `KeychainService` runs in production.
}

// MARK: - Error

enum MockError: Error {
    case genericFailure
}
