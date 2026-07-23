import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI
#if canImport(WidgetKit)
import WidgetKit
#endif

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

    /// User watched state (checkmark). Mirrors `item.userData.isPlayed`,
    /// flipped optimistically by `togglePlayed`. For a series this is true
    /// only when every episode has been played.
    var isPlayed = false

    /// BoxSet collection containing this movie ("Part of: …") and its other
    /// members. Empty when the item belongs to no collection (or the server
    /// can't resolve one — see `LibraryAPI.getCollections`).
    var collectionName: String?
    var collectionItems: [BaseItemDto] = []

    /// Generation counter to discard stale season results on rapid selection.
    private var seasonGeneration: Int = 0

    /// Generation counter shared by `load` and `refreshAfterPlayback` so a
    /// still-running full load and a post-playback refresh can't interleave and
    /// clobber each other's `@Observable` writes. Bumped at each entry; every
    /// pass re-checks it after each await cluster and bails (writing nothing,
    /// not even `isLoading`) once superseded.
    private var loadGeneration: Int = 0

    let itemId: String
    let itemType: BaseItemKind

    init(itemId: String, itemType: BaseItemKind) {
        self.itemId = itemId
        self.itemType = itemType
    }

    func load(using appState: AppState, loc: LocalizationManager) async {
        guard let userId = appState.currentUserId else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true

        do {
            let loadedItem = try await appState.apiClient.getItem(userId: userId, itemId: itemId)
            guard loadGeneration == generation else { return }

            // Resolve episodes/seasons to their parent series for full detail
            let effectiveType = loadedItem.type ?? itemType
            if effectiveType == .episode || effectiveType == .season,
               let seriesId = loadedItem.seriesID {
                let seriesItem = try await appState.apiClient.getItem(userId: userId, itemId: seriesId)
                guard loadGeneration == generation else { return }
                item = seriesItem
                resolvedType = .series

                try await loadSeriesDetail(seriesId: seriesId, apiClient: appState.apiClient, userId: userId, generation: generation)
                guard loadGeneration == generation else { return }
            } else {
                item = loadedItem
                resolvedType = effectiveType

                if effectiveType == .series {
                    try await loadSeriesDetail(seriesId: itemId, apiClient: appState.apiClient, userId: userId, generation: generation)
                    guard loadGeneration == generation else { return }
                } else {
                    async let similar = appState.apiClient.getSimilarItems(itemId: itemId, userId: userId, limit: 12)
                    let loadedSimilar = try await similar
                    guard loadGeneration == generation else { return }
                    similarItems = loadedSimilar
                }
            }
        } catch {
            guard loadGeneration == generation else { return }
            logger.error("MediaDetail load failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = loc.userFacingMessage(for: error)
        }

        guard loadGeneration == generation else { return }
        isFavorite = item?.userData?.isFavorite ?? false
        isPlayed = item?.userData?.isPlayed ?? false
        // Collections are a movie-only garnish — resolved after the main load
        // so a slow boxset lookup never delays the detail render.
        if resolvedType == .movie, item != nil {
            Task { await loadCollection(using: appState) }
        }

        isLoading = false
    }

    /// Targeted refresh after the player dismisses (tvOS dismiss path). Unlike
    /// `load()` it flips NO `isLoading` (so the screen never flashes back to a
    /// spinner) and re-fetches ONLY the userData-bearing slices: a movie's own
    /// item, or a series' item (userData) + next-up + the visible season's
    /// episodes — fetched concurrently. Similar items and seasons are NOT
    /// re-fetched (watching doesn't change them). All fetches hit the caches
    /// `reportPlaybackStopped` just invalidated, so they return fresh data.
    /// Shares `loadGeneration` with `load()` so the two can't interleave.
    func refreshAfterPlayback(using appState: AppState) async {
        guard let userId = appState.currentUserId, let id = item?.id else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let apiClient = appState.apiClient

        if resolvedType == .series {
            let seasonId = selectedSeasonId
            async let itemTask = apiClient.getItem(userId: userId, itemId: id)
            async let nextUpTask = apiClient.getNextUp(seriesId: id, userId: userId)
            async let episodesTask: [BaseItemDto]? = {
                guard let seasonId else { return nil }
                return try? await apiClient.getEpisodes(seriesId: id, seasonId: seasonId, userId: userId)
            }()

            let refreshedItem = try? await itemTask
            let refreshedNextUp = try? await nextUpTask
            let refreshedEpisodes = await episodesTask

            guard loadGeneration == generation else { return }
            if let refreshedItem { item = refreshedItem }
            nextUpEpisode = refreshedNextUp
            if let refreshedEpisodes {
                episodes = refreshedEpisodes
                rebuildNavigationMaps(apiClient: apiClient, userId: userId)
            }
            isFavorite = item?.userData?.isFavorite ?? false
            isPlayed = item?.userData?.isPlayed ?? false
        } else {
            guard let refreshedItem = try? await apiClient.getItem(userId: userId, itemId: id) else { return }
            guard loadGeneration == generation else { return }
            item = refreshedItem
            isFavorite = refreshedItem.userData?.isFavorite ?? false
            isPlayed = refreshedItem.userData?.isPlayed ?? false
        }
    }

    /// Optimistic heart toggle — reverted if the server call fails.
    func toggleFavorite(using appState: AppState) async {
        guard let userId = appState.currentUserId, let id = item?.id else { return }
        let target = !isFavorite
        isFavorite = target
        do {
            try await appState.apiClient.setFavorite(itemId: id, userId: userId, favorite: target)
            NotificationCenter.default.post(name: .cinemaxFavoritesChanged, object: nil)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: "CinemaxFavorites")
            #endif
        } catch {
            logger.error("Favorite toggle failed: \(error.localizedDescription, privacy: .public)")
            isFavorite = !target
        }
    }

    /// Optimistic watched toggle for the resolved item (a movie, or a whole
    /// series). Marking a series played cascades to its episodes server-side,
    /// so the visible season is re-fetched to catch up the per-episode marks.
    func togglePlayed(using appState: AppState) async {
        guard let userId = appState.currentUserId, let id = item?.id else { return }
        let target = !isPlayed
        isPlayed = target
        do {
            if target {
                try await appState.apiClient.markItemPlayed(itemId: id, userId: userId)
            } else {
                try await appState.apiClient.markItemUnplayed(itemId: id, userId: userId)
            }
            NotificationCenter.default.post(name: .cinemaxItemUserDataChanged, object: nil)
            if resolvedType == .series {
                await refreshVisibleEpisodes(seriesId: id, using: appState)
            }
        } catch {
            logger.error("Played toggle failed: \(error.localizedDescription, privacy: .public)")
            isPlayed = !target
        }
    }

    /// Marks an entire season as watched. `markItemPlayed` on a season id
    /// cascades to every episode server-side, so we optimistically flip all
    /// loaded episodes of the visible season to played, then re-fetch to catch
    /// up to server truth. Reverts + surfaces an error toast on failure.
    func markSeasonWatched(
        seasonId: String,
        seriesId: String,
        using appState: AppState,
        toast: ToastCenter,
        loc: LocalizationManager
    ) async {
        guard let userId = appState.currentUserId else { return }

        // Optimistic: flip every loaded episode of the visible season.
        let previous = episodes
        for id in episodes.compactMap(\.id) { setEpisodePlayed(id: id, played: true) }

        do {
            try await appState.apiClient.markItemPlayed(itemId: seasonId, userId: userId)
            toast.success(loc.localized("detail.season.markedWatched"))
            NotificationCenter.default.post(name: .cinemaxItemUserDataChanged, object: nil)
            await refreshVisibleEpisodes(seriesId: seriesId, using: appState)
        } catch {
            logger.error("Season mark-watched failed: \(error.localizedDescription, privacy: .public)")
            episodes = previous
            toast.error(loc.userFacingMessage(for: error))
        }
    }

    /// Optimistic per-episode watched toggle. Flips the local episode payload
    /// so the `Equatable` episode card re-renders immediately; reverts on a
    /// server failure.
    func toggleEpisodeWatched(_ episode: BaseItemDto, using appState: AppState) async {
        guard let userId = appState.currentUserId, let id = episode.id else { return }
        let target = !(episode.userData?.isPlayed ?? false)
        setEpisodePlayed(id: id, played: target)
        do {
            if target {
                try await appState.apiClient.markItemPlayed(itemId: id, userId: userId)
            } else {
                try await appState.apiClient.markItemUnplayed(itemId: id, userId: userId)
            }
            NotificationCenter.default.post(name: .cinemaxItemUserDataChanged, object: nil)
        } catch {
            logger.error("Episode watched toggle failed: \(error.localizedDescription, privacy: .public)")
            setEpisodePlayed(id: id, played: !target)
        }
    }

    /// Reflects a played-state change in the local episode arrays so the
    /// `Equatable` episode cards re-render. Marking played also clears the
    /// resume position so the in-progress bar disappears. Only mutates the
    /// existing `userData` (episodes always carry it — fetched with
    /// `enableUserData: true`).
    private func setEpisodePlayed(id: String, played: Bool) {
        func apply(to ep: inout BaseItemDto) {
            guard var userData = ep.userData else { return }
            userData.isPlayed = played
            if played { userData.playbackPositionTicks = 0 }
            ep.userData = userData
        }
        if let idx = episodes.firstIndex(where: { $0.id == id }) { apply(to: &episodes[idx]) }
        if let idx = nextUpEpisodes.firstIndex(where: { $0.id == id }) { apply(to: &nextUpEpisodes[idx]) }
        if nextUpEpisode?.id == id, var ep = nextUpEpisode {
            apply(to: &ep)
            nextUpEpisode = ep
        }
    }

    /// Re-fetches the currently selected season's episodes after a series-level
    /// played toggle cascades server-side. Silent on failure — the optimistic
    /// `isPlayed` flip already gave the user feedback.
    private func refreshVisibleEpisodes(seriesId: String, using appState: AppState) async {
        guard let userId = appState.currentUserId, let seasonId = selectedSeasonId else { return }
        if let refreshed = try? await appState.apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId) {
            episodes = refreshed
            rebuildNavigationMaps(apiClient: appState.apiClient, userId: userId)
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
        userId: String,
        generation: Int
    ) async throws {
        async let similarTask = apiClient.getSimilarItems(itemId: seriesId, userId: userId, limit: 12)
        async let seasonsTask = apiClient.getSeasons(seriesId: seriesId, userId: userId)
        async let nextUpTask = apiClient.getNextUp(seriesId: seriesId, userId: userId)

        let loadedSimilar = try await similarTask
        let loadedSeasons = try await seasonsTask
        let loadedNextUp = try? await nextUpTask
        guard loadGeneration == generation else { return }
        similarItems = loadedSimilar
        seasons = loadedSeasons
        nextUpEpisode = loadedNextUp

        guard let seasonId = loadedSeasons.first?.id else {
            rebuildNavigationMaps(apiClient: apiClient, userId: userId)
            return
        }
        selectedSeasonId = seasonId

        let nextUpSeasonId = loadedNextUp?.seasonID
        if let nextUpSeasonId, nextUpSeasonId != seasonId {
            async let currentEpisodesTask = apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
            async let nextUpEpisodesTask = apiClient.getEpisodes(seriesId: seriesId, seasonId: nextUpSeasonId, userId: userId)
            let loadedEpisodes = try await currentEpisodesTask
            let loadedNextUpEpisodes = (try? await nextUpEpisodesTask) ?? []
            guard loadGeneration == generation else { return }
            episodes = loadedEpisodes
            nextUpEpisodes = loadedNextUpEpisodes
        } else {
            let loadedEpisodes = try await apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
            guard loadGeneration == generation else { return }
            episodes = loadedEpisodes
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
