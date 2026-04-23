import Foundation
import JellyfinAPI

// MARK: - Domain sub-protocols
//
// The API surface is split into four cohesive domains so that narrow consumers
// (e.g. `PlaybackReporter`, `SkipSegmentController`) can depend on just the slice
// they need instead of the full `APIClientProtocol`. Every existing call site
// that takes `APIClientProtocol` keeps working — it still composes all four.

/// Server connection, identity, and cache management.
public protocol ServerAPI: Sendable {
    func connectToServer(url: URL) async throws -> ServerInfo
    func fetchServerInfo() async throws -> ServerInfo
    func reconnect(url: URL, accessToken: String)
    /// Drops every cached response (used by Settings → Server → Refresh Catalogue).
    func clearCache()
    /// Installs a maximum content age (years) applied to every subsequent item
    /// query — content rated above that age is hidden. Pass `0` to disable.
    /// `maxOfficialRating` is used on endpoints that support it (`/Items`);
    /// the rest are filtered client-side via `ContentRatingClassifier` so the
    /// limit holds uniformly across Home, Library, Search, Similar, Next Up,
    /// and Episodes.
    func applyContentRatingLimit(maxAge: Int)
}

/// Authentication, user listing, and active-session queries.
public protocol AuthAPI: Sendable {
    func authenticate(username: String, password: String) async throws -> UserSession
    func getPublicUsers() async throws -> [UserDto]
    func getUsers() async throws -> [UserDto]
    func getActiveSessions(activeWithinSeconds: Int) async throws -> [SessionInfoDto]
    /// Lists devices registered on the server. For non-admin users the server
    /// returns only the caller's own devices; admins receive every device.
    func getDevices() async throws -> [DeviceInfoDto]
    /// Revokes every access token tied to `deviceId`, logging that device out.
    func deleteDevice(id: String) async throws
}

/// Library queries: items, genres, search, series/seasons/episodes.
public protocol LibraryAPI: Sendable {
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

    func getSeasons(seriesId: String, userId: String) async throws -> [BaseItemDto]
    func getEpisodes(seriesId: String, seasonId: String, userId: String) async throws -> [BaseItemDto]
    func getNextUp(seriesId: String, userId: String) async throws -> BaseItemDto?

    /// Clears the user's played/progress state for the given item. Used by
    /// Privacy & Security → Clear Continue Watching to drop resume points
    /// without leaking what was being watched.
    func markItemUnplayed(itemId: String, userId: String) async throws
}

/// Playback: stream resolution, intro/outro segments, and Jellyfin progress reporting.
public protocol PlaybackAPI: Sendable {
    func getPlaybackInfo(
        itemId: String,
        userId: String,
        maxBitrate: Int,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async throws -> PlaybackInfo

    func getMediaSegments(itemId: String, includeSegmentTypes: [MediaSegmentType]?) async throws -> [MediaSegmentDto]

    /// Reports that playback has started. Fire-and-forget; errors are silently ignored.
    func reportPlaybackStart(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, playMethod: PlayMethod) async
    /// Reports current playback position. Fire-and-forget; errors are silently ignored.
    func reportPlaybackProgress(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, isPaused: Bool, playMethod: PlayMethod) async
    /// Reports that playback has stopped at the given position. Fire-and-forget; errors are silently ignored.
    func reportPlaybackStopped(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?) async
}

/// Admin-only operations: user management, activity log, system info, media
/// folders. Calls return 401/403 when the authenticated user isn't an
/// administrator — view models gate entry on `AppState.isAdministrator` so the
/// privileged surfaces never render for non-admins in the first place.
///
/// Device and session listing already live on `AuthAPI` (the server returns the
/// full fleet when the caller is admin, the caller's own devices otherwise), so
/// admin screens reuse those methods rather than duplicating them here.
public protocol AdminAPI: Sendable {
    /// Fetch a single user by id. Used by the admin user detail screen to
    /// re-hydrate the full `UserDto` (including `policy` and `configuration`)
    /// before editing.
    func getUserByID(id: String) async throws -> UserDto
    /// Create a new user. `password` is optional — Jellyfin allows passwordless
    /// accounts guarded by server policy.
    func createUserByName(name: String, password: String?) async throws -> UserDto
    /// Replace a user's profile (name, auto-login flag, etc.). Policy and
    /// password live on their own dedicated endpoints.
    func updateUser(id: String, user: UserDto) async throws
    /// Replace a user's policy (permissions, library access, parental rating).
    func updateUserPolicy(id: String, policy: UserPolicy) async throws
    /// Set a user's password. `resetPassword: true` clears without replacing —
    /// the user is prompted to set a new one on their next login.
    func updateUserPassword(id: String, newPassword: String, resetPassword: Bool) async throws
    /// Permanently delete a user. Callers must confirm client-side; the server
    /// also enforces "cannot delete the last admin".
    func deleteUser(id: String) async throws

    /// Lists every media folder (library) on the server. Used by the user
    /// access tab to render the per-library grant checklist.
    func getMediaFolders() async throws -> [BaseItemDto]

    /// Paginated activity log. `minDate` filters to entries newer than the
    /// given timestamp; pass `nil` to fetch everything.
    func getActivityLogEntries(startIndex: Int, limit: Int, minDate: Date?) async throws -> (entries: [ActivityLogEntry], total: Int)

    /// Server system info (version, OS, hardware) — admin-only because it
    /// exposes paths and architecture.
    func getSystemInfo() async throws -> SystemInfo
}

// MARK: - Aggregate

/// Umbrella protocol kept as the default dependency type — view models and
/// screens that touch multiple domains (e.g. `HomeViewModel`,
/// `MediaDetailViewModel`) depend on this. Leaf components should prefer the
/// narrower sub-protocol they actually need.
public typealias APIClientProtocol = ServerAPI & AuthAPI & LibraryAPI & PlaybackAPI & AdminAPI

// MARK: - Default arguments

public extension LibraryAPI {
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
    func searchItems(userId: String, searchTerm: String, limit: Int = 20) async throws -> [BaseItemDto] {
        try await searchItems(userId: userId, searchTerm: searchTerm, limit: limit)
    }
}

public extension AuthAPI {
    func getActiveSessions(activeWithinSeconds: Int = 60) async throws -> [SessionInfoDto] {
        try await getActiveSessions(activeWithinSeconds: activeWithinSeconds)
    }
}

public extension AdminAPI {
    func getActivityLogEntries(startIndex: Int = 0, limit: Int = 50, minDate: Date? = nil) async throws -> (entries: [ActivityLogEntry], total: Int) {
        try await getActivityLogEntries(startIndex: startIndex, limit: limit, minDate: minDate)
    }
    func createUserByName(name: String, password: String? = nil) async throws -> UserDto {
        try await createUserByName(name: name, password: password)
    }
    func updateUserPassword(id: String, newPassword: String, resetPassword: Bool = false) async throws {
        try await updateUserPassword(id: id, newPassword: newPassword, resetPassword: resetPassword)
    }
}

public extension PlaybackAPI {
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

extension JellyfinAPIClient: ServerAPI, AuthAPI, LibraryAPI, PlaybackAPI, AdminAPI {}
