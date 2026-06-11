import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "MediaDetail")

@MainActor @Observable
final class MediaDetailViewModel {
    var item: BaseItemDto?
    var similarItems: [BaseItemDto] = []
    var seasons: [BaseItemDto] = []
    var episodes: [BaseItemDto] = []
    var selectedSeasonId: String?
    var nextUpEpisode: BaseItemDto?
    /// Episodes from the next-up episode's season, when it differs from the currently displayed season.
    /// Used so episodeNavigation can build prev/next refs for the resume action button.
    var nextUpEpisodes: [BaseItemDto] = []
    /// Precomputed episode navigation map — O(1) lookups by episode ID.
    var episodeNavigationMap: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] = [:]
    /// Same map but for nextUpEpisodes (cross-season next-up).
    var nextUpNavigationMap: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] = [:]
    var isLoading = true
    var errorMessage: String?

    // The resolved type after loading (episode/season → series)
    var resolvedType: BaseItemKind = .movie

    /// User favorite state (heart). Mirrors `item.userData.isFavorite`,
    /// flipped optimistically by `toggleFavorite`.
    var isFavorite = false

    /// BoxSet collection containing this movie ("Part of: …") and its other
    /// members. Empty when the item belongs to no collection (or the server
    /// can't resolve one — see `LibraryAPI.getCollections`).
    var collectionName: String?
    var collectionItems: [BaseItemDto] = []

    /// Generation counter to discard stale season results on rapid selection.
    private var seasonGeneration: Int = 0

    let itemId: String
    let itemType: BaseItemKind

    init(itemId: String, itemType: BaseItemKind) {
        self.itemId = itemId
        self.itemType = itemType
    }

    func load(using appState: AppState, loc: LocalizationManager) async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true

        do {
            let loadedItem = try await appState.apiClient.getItem(userId: userId, itemId: itemId)

            // Resolve episodes/seasons to their parent series for full detail
            let effectiveType = loadedItem.type ?? itemType
            if effectiveType == .episode || effectiveType == .season,
               let seriesId = loadedItem.seriesID {
                let seriesItem = try await appState.apiClient.getItem(userId: userId, itemId: seriesId)
                item = seriesItem
                resolvedType = .series

                try await loadSeriesDetail(seriesId: seriesId, apiClient: appState.apiClient, userId: userId)
            } else {
                item = loadedItem
                resolvedType = effectiveType

                if effectiveType == .series {
                    try await loadSeriesDetail(seriesId: itemId, apiClient: appState.apiClient, userId: userId)
                } else {
                    async let similar = appState.apiClient.getSimilarItems(itemId: itemId, userId: userId, limit: 12)
                    similarItems = try await similar
                }
            }
        } catch {
            logger.error("MediaDetail load failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = loc.userFacingMessage(for: error)
        }

        isFavorite = item?.userData?.isFavorite ?? false
        // Collections are a movie-only garnish — resolved after the main load
        // so a slow boxset lookup never delays the detail render.
        if resolvedType == .movie, item != nil {
            Task { await loadCollection(using: appState) }
        }

        isLoading = false
    }

    /// Optimistic heart toggle — reverted if the server call fails.
    func toggleFavorite(using appState: AppState) async {
        guard let userId = appState.currentUserId, let id = item?.id else { return }
        let target = !isFavorite
        isFavorite = target
        do {
            try await appState.apiClient.setFavorite(itemId: id, userId: userId, favorite: target)
        } catch {
            logger.error("Favorite toggle failed: \(error.localizedDescription, privacy: .public)")
            isFavorite = !target
        }
    }

    private func loadCollection(using appState: AppState) async {
        guard let userId = appState.currentUserId, let id = item?.id else { return }
        let tmdbCollectionId = item?.providerIDs?
            .first { $0.key.caseInsensitiveCompare("TmdbCollection") == .orderedSame }?
            .value
        guard let boxset = (try? await appState.apiClient.getCollections(
            containingItemId: id, tmdbCollectionId: tmdbCollectionId, userId: userId
        ))?.first, let boxsetId = boxset.id else { return }
        let members = (try? await appState.apiClient.getItems(
            userId: userId,
            parentId: boxsetId,
            sortBy: [.premiereDate],
            sortOrder: [.ascending],
            limit: 20
        ).items) ?? []
        let others = members.filter { $0.id != id }
        guard !others.isEmpty else { return }
        collectionName = boxset.name
        collectionItems = others
    }

    /// Fans out the series-level fetches in parallel — similar, seasons, and next-up
    /// have no dependencies on each other. Episode lists depend on the resolved
    /// season IDs, so a second (parallel) stage fetches the current season's and
    /// the next-up season's episodes together when they differ.
    private func loadSeriesDetail(
        seriesId: String,
        apiClient: any APIClientProtocol,
        userId: String
    ) async throws {
        async let similarTask = apiClient.getSimilarItems(itemId: seriesId, userId: userId, limit: 12)
        async let seasonsTask = apiClient.getSeasons(seriesId: seriesId, userId: userId)
        async let nextUpTask = apiClient.getNextUp(seriesId: seriesId, userId: userId)

        similarItems = try await similarTask
        seasons = try await seasonsTask
        nextUpEpisode = try? await nextUpTask

        guard let seasonId = seasons.first?.id else {
            rebuildNavigationMaps(apiClient: apiClient, userId: userId)
            return
        }
        selectedSeasonId = seasonId

        let nextUpSeasonId = nextUpEpisode?.seasonID
        if let nextUpSeasonId, nextUpSeasonId != seasonId {
            async let currentEpisodesTask = apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
            async let nextUpEpisodesTask = apiClient.getEpisodes(seriesId: seriesId, seasonId: nextUpSeasonId, userId: userId)
            episodes = try await currentEpisodesTask
            nextUpEpisodes = (try? await nextUpEpisodesTask) ?? []
        } else {
            episodes = try await apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
        }

        rebuildNavigationMaps(apiClient: apiClient, userId: userId)
    }

    func selectSeason(_ seasonId: String, seriesId: String, using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        selectedSeasonId = seasonId
        seasonGeneration += 1
        let expectedGeneration = seasonGeneration
        do {
            let newEpisodes = try await appState.apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
            guard seasonGeneration == expectedGeneration else { return }
            episodes = newEpisodes
            rebuildNavigationMaps(apiClient: appState.apiClient, userId: userId)
        } catch {
            // Keep existing episodes on error
        }
    }

    /// Rebuilds the precomputed episode navigation maps from current episode lists.
    /// Precomputes the refs + id→index pair once per list so per-episode
    /// population is O(1) instead of re-running compactMap+firstIndex inside
    /// `buildEpisodeNavigation` on every call.
    private func rebuildNavigationMaps(apiClient: any APIClientProtocol, userId: String) {
        episodeNavigationMap = Self.makeNavigationMap(
            from: episodes, apiClient: apiClient, userId: userId
        )
        nextUpNavigationMap = Self.makeNavigationMap(
            from: nextUpEpisodes, apiClient: apiClient, userId: userId
        )
    }

    private static func makeNavigationMap(
        from episodes: [BaseItemDto],
        apiClient: any APIClientProtocol,
        userId: String
    ) -> [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] {
        guard !episodes.isEmpty else { return [:] }
        let (refs, indexByID) = precomputeEpisodeRefs(episodes)
        var map: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] = [:]
        map.reserveCapacity(refs.count)
        for ref in refs {
            map[ref.id] = buildEpisodeNavigation(
                for: ref.id, refs: refs, indexByID: indexByID,
                apiClient: apiClient, userId: userId
            )
        }
        return map
    }
}
