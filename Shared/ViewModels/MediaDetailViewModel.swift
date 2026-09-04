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

    /// What a BoxSet CONTAINS — the opposite direction from `collectionItems`,
    /// which answers "which other films share this one's collection".
    ///
    /// A collection's fiche used to borrow a work's chrome wholesale: title,
    /// Lecture, favorite / watched / playlist, "Similar titles" — with no year,
    /// runtime, genre or overview (a BoxSet carries none), and, worse, no list
    /// of what it holds, which is the only thing anyone opens it for.
    var collectionChildren: [BaseItemDto] = []

    /// Jellyfin sessions this user can send the item to ("Play on…"). Resolved
    /// after the main load, like `loadCollection`, so a slow or failing
    /// `/Sessions` never delays the detail render. Empty ⇒ no affordance drawn,
    /// which is the ordinary case: a session only exists while Jellyfin is
    /// actually running on the other device.
    var remoteTargets: [RemotePlayTarget] = []
    /// Trailers the server holds for this item. Empty is the ordinary case —
    /// most libraries have none — and the button renders only when it isn't,
    /// which is what teaches the user the precondition.
    var localTrailers: [BaseItemDto] = []

    /// The version the user picked from the detail screen's version row, when
    /// the item carries several media sources. `nil` ⇒ play whatever
    /// `MediaSourceQuality` ranks highest.
    ///
    /// Deliberately **session-scoped and not persisted**: the standing "always
    /// give me the smaller file" preference is already served by `render4K`'s
    /// bitrate cap, so what's left is genuinely a one-off ("play the other cut
    /// just now"). Reverts to the ranked default next time the screen is
    /// opened. Plain stored property with no `didSet` — see the `@Observable`
    /// RULE in CLAUDE.md.
    var selectedMediaSourceId: String?

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

    /// Whether a clean load has already populated this screen. Same latch as
    /// `HomeViewModel` / `MediaLibraryViewModel`, and it exists for the same
    /// reason here: SwiftUI re-runs `.task` when the screen reappears after the
    /// player is popped on iOS.
    private var hasLoaded = false

    /// First load. Idempotent — safe to call from `.task` on every appearance.
    ///
    /// Without the latch the reappearance re-ran the FULL `load()`: measured on
    /// device 2026-08-19, it fired 39 ms before the targeted post-playback
    /// refresh, flipping `isLoading` (which swaps the body for the spinner and
    /// drops the user's scroll position) and re-fetching seasons, episodes,
    /// similar titles and remote targets to display what the targeted refresh
    /// was about to fetch properly. Playback now announces its own userData
    /// change, so a reappearance needs no reload at all — the tier-2 observer
    /// does the small, correct amount of work.
    ///
    /// A failed load leaves the latch clear so the next appearance (or Retry)
    /// tries again.
    func loadInitial(using appState: AppState, loc: LocalizationManager, cardActions: CardActionPresenter? = nil) async {
        if hasLoaded { return }
        await load(using: appState, loc: loc, cardActions: cardActions)
    }

    func load(using appState: AppState, loc: LocalizationManager, cardActions: CardActionPresenter? = nil) async {
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
                } else if effectiveType != .boxSet {
                    // A collection has nothing to be "similar" to — its own
                    // members are what the screen shows in that slot, and they
                    // load as a side task below. Asking anyway spent a request
                    // to fill a row the fiche no longer renders.
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
        // The mirror image, for a collection's OWN fiche: what it contains.
        if resolvedType == .boxSet, item != nil {
            Task { await loadCollectionChildren(using: appState) }
        }
        // Same discipline for the "Play on…" probe: a side task, so `/Sessions`
        // being slow or unreachable costs the render nothing. Every item kind is
        // sendable, so there's no type guard here.
        Task { await loadRemoteTargets(using: appState, cardActions: cardActions) }
        // tvOS only: `localTrailers` has exactly one consumer, the tvOS action
        // row's trailer button. iOS opens a `remoteTrailers` link instead, so
        // dispatching here would issue a request per detail-screen open whose
        // result nothing reads.
        #if os(tvOS)
        Task { await loadLocalTrailers(using: appState) }
        #endif

        hasLoaded = errorMessage == nil
        isLoading = false
    }

    /// Targeted refresh after the player dismisses (tvOS dismiss path). Unlike
    /// `load()` it flips NO `isLoading` (so the screen never flashes back to a
    /// spinner) and re-fetches ONLY the userData-bearing slices: a movie's
    /// userData, or a series' item (userData) + next-up + the visible season's
    /// episodes — fetched concurrently. Similar items and seasons are NOT
    /// re-fetched (watching doesn't change them). All fetches hit the caches
    /// `reportPlaybackStopped` just invalidated, so they return fresh data.
    /// Shares `loadGeneration` with `load()` so the two can't interleave.
    ///
    /// The movie branch goes through `fetchUserData`, which on Jellyfin ≥ 10.10
    /// reads `GET /UserItems/{id}/UserData` instead of the whole item — playback
    /// changes nothing else about a movie, and the full DTO carries overview,
    /// people, chapters and media sources we already have. Older servers fall
    /// back to `getItem` inside that helper, so this branch is version-agnostic.
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
            }

            // Cross-season next-up (mirrors `loadSeriesDetail`'s cross-season
            // branch): when the refreshed next-up episode lives in a season
            // other than the one on screen, `nextUpNavigationMap` needs that
            // season's episode list to resolve prev/next for it — otherwise
            // the in-player Next Up prev/next buttons silently disappear.
            // When it matches (or there's no next-up), `loadSeriesDetail`
            // never populates `nextUpEpisodes` for that pass either — clear
            // it here so a stale cross-season list from a PRIOR refresh can't
            // leave dangling nav entries pointing at the wrong season.
            let nextUpSeasonId = refreshedNextUp?.seasonID
            if let nextUpSeasonId, nextUpSeasonId != seasonId {
                let refreshedNextUpEpisodes = (try? await apiClient.getEpisodes(
                    seriesId: id, seasonId: nextUpSeasonId, userId: userId
                )) ?? []
                guard loadGeneration == generation else { return }
                nextUpEpisodes = refreshedNextUpEpisodes
            } else {
                nextUpEpisodes = []
            }

            rebuildNavigationMaps()
            isFavorite = item?.userData?.isFavorite ?? false
            isPlayed = item?.userData?.isPlayed ?? false
        } else {
            let refreshedUserData = try? await apiClient.fetchUserData(itemId: id, userId: userId)
            guard loadGeneration == generation else { return }
            if let refreshedUserData {
                // Splice onto the item we already hold rather than replacing it:
                // `fetchUserData` returns only the userData slice on servers that
                // support the lightweight read, so there is no fresh item to
                // assign — and nothing else about a movie changed anyway.
                item?.userData = refreshedUserData
                isFavorite = refreshedUserData.isFavorite ?? false
                isPlayed = refreshedUserData.isPlayed ?? false
            }
        }

        // Defensive no-op in the normal flow (this function never flips
        // `isLoading` true), but recovers a stranded spinner if a superseded
        // `load()` pass were ever able to return without clearing it.
        guard loadGeneration == generation else { return }
        isLoading = false
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
            // `object: self` identifies the sender so this screen's own tier-2
            // observer can skip it: these toggles already refresh exactly what
            // they changed, and re-entering `refreshAfterPlayback` here would
            // spend three requests re-reading what we just wrote.
            NotificationCenter.default.post(name: .cinemaxItemUserDataChanged, object: self)
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
            NotificationCenter.default.post(name: .cinemaxItemUserDataChanged, object: self)
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
            NotificationCenter.default.post(name: .cinemaxItemUserDataChanged, object: self)
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
            rebuildNavigationMaps()
        }
    }

    /// Loads a BoxSet's members.
    ///
    /// Side task off the critical path and silent on failure, like
    /// `loadCollection` and `loadRemoteTargets`: the hero paints first, and a
    /// collection that comes back empty renders no section rather than an error
    /// over an otherwise-fine screen.
    ///
    /// Sorted by release date so the set reads in the order it was made — the
    /// one ordering a collection has that an alphabetical list destroys.
    private func loadCollectionChildren(using appState: AppState) async {
        guard resolvedType == .boxSet,
              let userId = appState.currentUserId,
              let id = item?.id else { return }
        let members = (try? await appState.apiClient.getItems(
            userId: userId,
            parentId: id,
            sortBy: [.premiereDate],
            sortOrder: [.ascending],
            limit: 100
        ).items) ?? []
        guard !members.isEmpty else { return }
        collectionChildren = members
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

    /// Side task, same discipline as `loadRemoteTargets`: having no trailer is
    /// the ordinary outcome, so a failed probe degrades to "no button" and
    /// never to an error over an otherwise-fine screen.
    func loadLocalTrailers(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        let id = item?.id ?? itemId
        let generation = loadGeneration
        guard let trailers = try? await appState.apiClient.getLocalTrailers(itemId: id, userId: userId) else { return }
        guard generation == loadGeneration else { return }
        localTrailers = trailers
    }

    /// Discovers the sessions the "Play on…" affordance can target.
    ///
    /// **Deliberately silent on failure**: having no target is the ordinary case,
    /// so a failed probe must degrade to "no button" — never to an error state
    /// over an otherwise-fine detail screen. Logged at debug level only.
    ///
    /// Internal rather than private: the picker sheet re-runs the same probe
    /// when it opens (its snapshot has to be fresh at the moment a command is
    /// sent), and the tests exercise this path directly.
    func loadRemoteTargets(using appState: AppState, cardActions: CardActionPresenter? = nil) async {
        guard let userId = appState.currentUserId else { return }
        let generation = loadGeneration
        do {
            let sessions = try await appState.apiClient.getControllableSessions(userId: userId)
            remoteTargets = RemotePlayTarget.resolve(
                sessions: sessions,
                currentUserId: userId,
                excludingDeviceId: KeychainService.getOrCreateDeviceID()
            )
            // The context menu can't probe before it draws: it reads this
            // count, written only by a real probe. No speculative request is
            // added here.
            //
            // **Guarded on change.** This is root-hosted state that every live
            // card's menu reads, and `@Observable` fires `withMutation` even
            // when the value is identical — so an unguarded write on every
            // detail-screen open (and every retry) invalidated the menu
            // modifier of every card still mounted behind it, each of which
            // then rebuilt. The equality guard is what actually removes that.
            //
            // The generation check covers the narrower case the rest of this
            // view model guards: a superseded pass on THIS instance (a retry, a
            // `refreshAfterPlayback`) must not write. It deliberately does not
            // claim to catch a popped screen — that screen's view model never
            // bumps its generation again, and its `Task` holds `self` alive
            // until the await returns.
            if loadGeneration == generation,
               cardActions?.knownRemoteTargetCount != remoteTargets.count {
                cardActions?.knownRemoteTargetCount = remoteTargets.count
            }
        } catch {
            // Unchanged: having no target is the ordinary case, a failed probe
            // degrades to "no button", never to an error screen.
            // `knownRemoteTargetCount` is deliberately NOT reset to 0 here — a
            // network failure doesn't prove there's no target, and overwriting
            // it would make the menu entry disappear after a mere hiccup.
            logger.debug("Remote targets probe failed: \(error.localizedDescription, privacy: .public)")
            remoteTargets = []
        }
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
            rebuildNavigationMaps()
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

        rebuildNavigationMaps()
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
            rebuildNavigationMaps()
        } catch {
            // Keep existing episodes on error
        }
    }

    /// Rebuilds the precomputed episode navigation maps from current episode lists.
    /// Precomputes the refs + id→index pair once per list so per-episode
    /// population is O(1) instead of re-running compactMap+firstIndex inside
    /// `buildEpisodeNavigation` on every call.
    private func rebuildNavigationMaps() {
        episodeNavigationMap = Self.makeNavigationMap(from: episodes)
        nextUpNavigationMap = Self.makeNavigationMap(from: nextUpEpisodes)
    }

    private static func makeNavigationMap(
        from episodes: [BaseItemDto]
    ) -> [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] {
        guard !episodes.isEmpty else { return [:] }
        let (refs, indexByID) = precomputeEpisodeRefs(episodes)
        var map: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] = [:]
        map.reserveCapacity(refs.count)
        for ref in refs {
            map[ref.id] = buildEpisodeNavigation(
                for: ref.id, refs: refs, indexByID: indexByID
            )
        }
        return map
    }
}
