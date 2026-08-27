import Foundation
import Observation
import OSLog
import CinemaxKit
@preconcurrency import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Library")

// MARK: - Sort & Filter State

struct LibrarySortFilterState: Equatable {
    var sortBy: ItemSortBy = .dateCreated
    var sortAscending: Bool = false
    var selectedGenres: Set<String> = []
    var showUnwatchedOnly: Bool = false
    /// Selected decades, stored as the starting year (e.g. 1980 → "1980s"). Empty == no decade filter.
    var selectedDecades: Set<Int> = []

    var isFiltered: Bool { !selectedGenres.isEmpty || showUnwatchedOnly || !selectedDecades.isEmpty }
    var isNonDefault: Bool { sortBy != .dateCreated || sortAscending || isFiltered }

    /// Expands `selectedDecades` into every year covered. `nil` when no decade filter is active.
    var expandedYears: [Int]? {
        guard !selectedDecades.isEmpty else { return nil }
        return selectedDecades.sorted().flatMap { start in Array(start..<(start + 10)) }
    }
}

// MARK: - View Model

@MainActor @Observable
final class MediaLibraryViewModel {
    /// `nil` means "no `includeItemTypes` filter" — used for library tabs of
    /// Other / Mixed kind where items aren't reliably typed as movies or
    /// series. Concrete kinds (`.movie` / `.series`) keep the legacy
    /// behaviour: hero + genre rows + filtered grid scoped to that kind.
    let itemType: BaseItemKind?
    /// When set, all `getItems` calls scope to a specific Jellyfin library
    /// (a.k.a. user view) by passing this id as `parentId`. Used by the
    /// custom-menu library mode so each tab shows only its own library
    /// rather than the entire catalogue.
    let parentId: String?

    // Hero
    var heroItem: BaseItemDto?

    // Genre rows
    var genres: [String] = []
    var itemsByGenre: [String: [BaseItemDto]] = [:]

    // Filtered flat list
    let filteredLoader = PaginatedLoader<BaseItemDto>(pageSize: 40, identity: { $0.id })

    /// The letter the filtered grid is anchored on, or `nil` for the start of
    /// the list. Set by the A–Z jump bar — see `anchorGrid(atLetter:using:)`.
    private(set) var letterAnchor: String?

    /// Size of the filtered set with NO anchor applied.
    ///
    /// An anchored query reports how many titles sort at or after the anchor,
    /// which is not the size of the library: the header would have dropped from
    /// "503 films" to "210 films" the instant the user tapped M. The last
    /// unanchored total is kept so the header keeps telling the truth about the
    /// collection while the grid shows a slice of it.
    private(set) var unanchoredTotal = 0

    /// What the count header shows — see `unanchoredTotal`.
    var displayedTotalCount: Int {
        letterAnchor == nil ? filteredLoader.totalCount : unanchoredTotal
    }

    // Shared state
    var totalCount = 0
    var isLoading = true
    var errorMessage: String?

    // Sort & filter
    var sortFilter = LibrarySortFilterState()

    // Internal
    private let genreItemLimit = 12
    let genreLoadLimit = 8
    private var hasLoaded = false
    /// The in-flight initial load, owned by the view model rather than the
    /// SwiftUI `.task`. Switching tabs cancels the `.task` but NOT this task —
    /// the load finishes in the background and the data is ready when the user
    /// returns, instead of being torn down and restarted on every reappearance.
    /// Each restart re-fired ~10 requests (incl. an expensive server-side random
    /// sort); rapid tab switching during the skeleton turned that into a request
    /// storm that overloaded self-hosted servers (froze every client, not just
    /// this one) and — because the cancellation was misread as a failure — left
    /// the tab stuck on a blocking error screen.
    private var loadTask: Task<Void, Never>?
    /// The sort/filter state whose genre-row fan-out is already reflected in
    /// `itemsByGenre`. The browse view drives `reloadGenreItems` from a
    /// `.task(id: sortFilter)`, and `.task(id:)` fires on every *attach* — not
    /// only when the id changes — so returning from the filtered grid, a tvOS
    /// hosting-controller recreation after a menu edit, or a browse↔grid toggle
    /// each re-ran the whole `genreLoadLimit` fan-out for byte-identical
    /// results. Equality-guard idiom, same as `MenuConfigStore
    /// .refreshAvailableViews`. Stamped only after a clean pass, so a failed
    /// fan-out never latches it and a retry can always re-run.
    private var appliedGenreSortFilter: LibrarySortFilterState?

    /// The filter the paginated grid was last loaded for. Same role as
    /// `appliedGenreSortFilter` one line up, for the *filtered* half of the
    /// screen: `applyFilter` no-ops when it is asked to re-apply the filter the
    /// grid already shows. See its doc comment for why that is load-bearing.
    private var appliedFilterStamp: LibrarySortFilterState?

    init(itemType: BaseItemKind?, parentId: String? = nil) {
        self.itemType = itemType
        self.parentId = parentId
    }

    /// First load. Idempotent — safe to call from `.task` on every appearance:
    /// a no-op once loaded, and it *joins* (rather than restarts) a load already
    /// running in the background.
    func loadInitial(using appState: AppState, loc: LocalizationManager) async {
        if hasLoaded { return }
        if loadTask == nil {
            // `[weak self]` breaks the self → loadTask → closure → self cycle;
            // the task also clears `loadTask` when it finishes.
            loadTask = Task { [weak self] in
                guard let self else { return }
                let succeeded = await self.performLoad(using: appState, loc: loc)
                if succeeded { self.hasLoaded = true }
                self.loadTask = nil
            }
        }
        // Non-throwing await: a cancelled `.task` (tab switch) won't interrupt
        // this — it simply waits for the background load to complete, so the
        // prefetch that follows at the call site still fires with data in hand.
        await loadTask?.value
    }

    /// User-driven reload (pull-to-refresh, Retry, catalogue refresh). Bypasses
    /// the `hasLoaded` latch and supersedes any background initial load.
    func reload(using appState: AppState, loc: LocalizationManager) async {
        // Drain (cancel AND await) any load already running before taking over.
        // `cancel()` only *requests* cancellation, so without the await the old
        // load would keep running and its writes (isLoading / heroItem /
        // itemsByGenre, plus its trailing `loadTask = nil`) could interleave
        // with — and clobber — ours as last-writer-wins. The cancelled load
        // early-returns without touching state, so draining it is cheap.
        //
        // **A LOOP, not a single drain.** Two reloads can suspend on the SAME
        // in-flight task; when they wake (in order) the first registers its own
        // task, and a straight-line drain then had the second null that fresh
        // registration out and start a *parallel* `performLoad` — two heroes and
        // two 8-row genre fan-outs racing last-writer-wins on `itemsByGenre`,
        // i.e. exactly the race this registration exists to close. Re-reading
        // `loadTask` after each await makes the second reload observe the
        // sibling's task and drain that instead. The identity check is what
        // guarantees termination: a task body clears the slot itself, so a value
        // still equal to the one we just awaited would otherwise loop forever.
        while let inFlight = loadTask {
            inFlight.cancel()
            await inFlight.value
            if loadTask == inFlight { loadTask = nil }
        }

        // Every explicit refresh funnels through here (pull-to-refresh, Retry,
        // and both `.cinemaxShouldRefreshCatalogue` / `.cinemaxItemUserDataChanged`
        // tiers), and each one must re-fetch even when the sort/filter state is
        // unchanged. `performLoad` calls `fetchGenreItems` directly rather than
        // through the guarded `reloadGenreItems`, so it already bypasses the
        // guard — clearing the stamp here keeps that explicit.
        appliedGenreSortFilter = nil
        appliedFilterStamp = nil
        letterAnchor = nil

        // Register OUR pass in `loadTask` too, not just the initial load's.
        // Without this a second `reload` arriving while this one is in flight
        // found `loadTask == nil`, sailed past the drain above and ran a
        // *parallel* `performLoad` — two heroes and two 8-row genre fan-outs
        // (~18 requests) racing to last-writer-wins on `itemsByGenre`. Easy to
        // reach now that a card's own context menu raises the tier-2
        // notification this answers: toggle one card, then another.
        loadTask = Task { [weak self] in
            guard let self else { return }
            let succeeded = await self.performLoad(using: appState, loc: loc)
            if succeeded { self.hasLoaded = true }
            // Unchanged for a *failed* load (the error screen owns the state
            // either way), but skipped for a superseded one: a newer reload has
            // already drained us and is about to fetch this itself.
            if !Task.isCancelled, self.sortFilter.isFiltered {
                await self.applyFilter(using: appState)
            }
            // Safe to clear unconditionally: a successor only registers after
            // draining us to completion, so at this point the slot still holds
            // this task (and its drain loop's identity check tolerates either
            // ordering anyway).
            self.loadTask = nil
        }
        await loadTask?.value
    }

    /// Returns `true` only on a clean load. A real error sets `errorMessage`
    /// (caller leaves `hasLoaded` false so the next visit / Retry re-loads); a
    /// cancellation (tab switch or a superseding reload) leaves the current
    /// state untouched — no `isLoading` flip, no error flash — so the load that
    /// superseded it owns the screen. Both return `false`.
    @discardableResult
    private func performLoad(using appState: AppState, loc: LocalizationManager) async -> Bool {
        guard let userId = appState.currentUserId else { return false }
        isLoading = true
        errorMessage = nil

        let typeFilter: [BaseItemKind]? = itemType.map { [$0] }

        do {
            // Scoped to the SAME `parentId` as the hero/items query below.
            // While it wasn't, a library tab surfacing one Jellyfin view got the
            // WHOLE server's genre list — and the damage wasn't the ~30 dead
            // chips, it was `fetchGenreItems` only loading `prefix(genreLoadLimit)`
            // of that list: a scoped library whose own genres sit outside the
            // server's first 8 lost every genre row and collapsed to its hero
            // (defect L, measured 2026-08-24).
            async let genresResult = appState.apiClient.getGenres(
                userId: userId,
                parentId: parentId,
                includeItemTypes: typeFilter
            )

            // The hero query already returns the full `totalCount` (Jellyfin's
            // `totalRecordCount` is the count before `limit`), so a single fetch
            // covers both the count and the hero item. Sort by `dateCreated`
            // descending (newest first) rather than `.random`: a random sort is
            // an un-indexed full shuffle the server re-runs on every load, and
            // the coherent newest-first ordering is the intended behavior.
            async let heroResult = appState.apiClient.getItems(
                userId: userId,
                parentId: parentId,
                includeItemTypes: typeFilter,
                sortBy: [.dateCreated],
                sortOrder: [.descending],
                limit: 20
            )

            let fetchedGenres = try await genresResult
            let heroData = try await heroResult

            genres = fetchedGenres
            totalCount = heroData.totalCount
            heroItem = heroData.items.first
            // A new hero invalidates the previous one's navigation immediately,
            // so the Play button can never carry the old series' episode.
            heroPlay = nil

            // Progressive render: the hero (and its `totalCount`) are ready, so
            // drop the skeleton now. The genre rows fetched below fill in off
            // their own `@Observable` slice (`itemsByGenre`) as each lands.
            isLoading = false

            // Side task, off the critical path: the hero paints now and gains
            // its prev/next buttons (and the end-of-series card) a beat later.
            // Blocking the first paint on a next-up probe would be a poor trade
            // for something only end-of-episode behaviour depends on.
            Task { [weak self] in
                await self?.loadHeroNavigation(using: appState)
            }
        } catch {
            if Self.isCancellation(error) {
                logger.debug("Library load cancelled — leaving state for the superseding load")
                return false
            }
            logger.error("Library load failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = loc.userFacingMessage(for: error)
            isLoading = false
            return false
        }

        // Genre rows are non-critical to the first paint — a failure here just
        // drops them (the hero + browse-genres grid still render), rather than
        // replacing the already-visible content with a full error screen. A
        // cancellation still supersedes the load so it isn't marked succeeded.
        do {
            try await fetchGenreItems(using: appState, userId: userId, genres: genres)
        } catch {
            if Self.isCancellation(error) { return false }
            logger.error("Library genre rows failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    /// True for errors that only mean "this load was cancelled" (tab switch, a
    /// superseding reload, deinit) rather than a genuine failure. Cancelling a
    /// structured load surfaces either a Swift `CancellationError` or a
    /// URLSession `.cancelled` (-999) depending on where the cancel lands —
    /// neither should ever render the blocking error screen.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func fetchGenreItems(using appState: AppState, userId: String, genres genreList: [String]) async throws {
        struct GenreResult: @unchecked Sendable {
            let genre: String
            let items: [BaseItemDto]
        }
        let genresToLoad = Array(genreList.prefix(genreLoadLimit))
        // Snapshot @MainActor state before the @Sendable task group — reading
        // self.sortFilter/itemType inside addTask would race with sort/filter
        // UI mutations on the main actor (same pattern as loadMoreFiltered).
        let snapshot = sortFilter
        let typeFilter: [BaseItemKind]? = itemType.map { [$0] }
        let parentScopeID = parentId
        let limit = genreItemLimit
        // Bound the fan-out to chunks of 6 (matching Home's throttle) so a full
        // `genreLoadLimit` set doesn't fire every `getItems` at a self-hosted
        // server at once.
        let concurrencyLimit = 6
        for start in stride(from: 0, to: genresToLoad.count, by: concurrencyLimit) {
            let chunk = genresToLoad[start..<min(start + concurrencyLimit, genresToLoad.count)]
            try await withThrowingTaskGroup(of: GenreResult.self) { group in
                for genre in chunk {
                    group.addTask {
                        let result = try await appState.apiClient.getItems(
                            userId: userId,
                            parentId: parentScopeID,
                            includeItemTypes: typeFilter,
                            sortBy: [snapshot.sortBy],
                            sortOrder: snapshot.sortAscending ? [.ascending] : [.descending],
                            genres: [genre],
                            limit: limit
                        )
                        return GenreResult(genre: genre, items: result.items)
                    }
                }
                for try await entry in group {
                    itemsByGenre[entry.genre] = entry.items
                }
            }
        }
        // Reached only when every chunk completed without throwing (a failure or
        // cancellation propagates out above), so the stamp always describes rows
        // that actually landed.
        appliedGenreSortFilter = snapshot
    }

    /// Re-runs the genre-row fan-out for the current sort state. Driven by the
    /// browse view's `.task(id: sortFilter)`, which re-fires on every attach —
    /// so this no-ops when the fan-out already ran for this exact state. The
    /// explicit refresh paths don't come through here: they go through
    /// `reload(using:)` → `performLoad` → `fetchGenreItems`, which is ungated.
    func reloadGenreItems(using appState: AppState) async {
        guard !genres.isEmpty, let userId = appState.currentUserId else { return }
        guard appliedGenreSortFilter != sortFilter else { return }
        try? await fetchGenreItems(using: appState, userId: userId, genres: genres)
    }

    /// What the library hero's Play button opens, plus the episode navigation
    /// that goes with it.
    ///
    /// A series hero used to call `PlayLink(itemId:title:)` and nothing else,
    /// so the player got no `episodeNavigator` — and `handlePlaybackEnded`
    /// requires a non-nil one to show the end-of-series card, dismissing
    /// silently otherwise. That is the A7 bug: play a series from Home or the
    /// detail screen and the card appears; play it from the library hero and it
    /// never can. Same gap also costs the in-player prev/next episode buttons.
    struct HeroPlay: Equatable {
        let itemId: String
        let title: String
        let startSeconds: Double?
        let previous: EpisodeRef?
        let next: EpisodeRef?
        let navigator: EpisodeNavigator?

        static func == (lhs: HeroPlay, rhs: HeroPlay) -> Bool {
            lhs.itemId == rhs.itemId && lhs.startSeconds == rhs.startSeconds
                && lhs.previous?.id == rhs.previous?.id && lhs.next?.id == rhs.next?.id
                && (lhs.navigator == nil) == (rhs.navigator == nil)
        }
    }

    private(set) var heroPlay: HeroPlay?

    /// Re-derives `heroPlay` against current server state.
    ///
    /// `heroPlay` otherwise has exactly one writer — `performLoad`'s side task —
    /// and nothing revisits it: closing the player posts neither refresh
    /// notification, and `.task` is latched by `hasLoaded`. So the hero's Play
    /// button stayed pinned to whatever episode was resolved when the page first
    /// loaded, at the resume offset it had *then*. Measured on device
    /// (2026-08-14): after watching episode 2 to 2:02 and closing the player,
    /// Play on the same hero reopened episode 1 at 0:01 / -23:57.
    ///
    /// Callers are the two moments the answer can have moved: the screen
    /// re-appearing (returning from the player) and a tier-2 userData
    /// notification. Both fire often, so this stays cheap by construction — it
    /// is a no-op unless the hero is a series (a movie hero has no episode
    /// navigation to re-derive, and the Films tab must cost nothing), and
    /// `getNextUp` / `getSeasons` / `getEpisodes` are all 10 s-cached.
    ///
    /// Being a no-op while `heroItem` is still nil is what makes it safe to call
    /// from `.onAppear` while the initial load is in flight.
    func refreshHeroNavigation(using appState: AppState) async {
        guard heroItem?.type == .series else { return }
        await loadHeroNavigation(using: appState)
    }

    /// Resolves the hero's play target + episode navigation.
    ///
    /// Deliberately a side task after the main load, and **failing silently**,
    /// same discipline as `MediaDetailViewModel.loadRemoteTargets`: a series
    /// with no next-up legitimately has no navigation, so a failed probe must
    /// degrade to "no prev/next buttons and no end-of-series card" — today's
    /// behaviour — never to an error over an otherwise-fine hero.
    ///
    /// Targets the resolved EPISODE rather than the series so the navigator and
    /// the media always describe the same thing. `getNextUp` and `getEpisodes`
    /// are both 10 s-cached, so this is usually free.
    func loadHeroNavigation(using appState: AppState) async {
        guard let userId = appState.currentUserId,
              let hero = heroItem,
              hero.type == .series,
              let seriesId = hero.id else {
            logger.debug("""
                hero-nav skipped kind=\(String(describing: self.heroItem?.type), privacy: .public) \
                hasUser=\(appState.currentUserId != nil, privacy: .public)
                """)
            heroPlay = nil
            return
        }
        do {
            // Mirror the server's own rule (`resolvePlayableEpisode`): next-up
            // first, else the first episode of the first season. Without the
            // fallback a fully-watched series — precisely the one you reach the
            // END of — got no navigator, so the end-of-series card stayed
            // unreachable there. Verified on device: `getNextUp` returns nil
            // once every episode is played.
            let nextUp = try await appState.apiClient.getNextUp(seriesId: seriesId, userId: userId)
            let resolved: (episodeId: String, seasonId: String)?
            if let nextUp, let id = nextUp.id, let seasonId = nextUp.seasonID {
                resolved = (id, seasonId)
            } else {
                let seasons = try await appState.apiClient.getSeasons(seriesId: seriesId, userId: userId)
                let firstSeason = seasons
                    .sorted { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
                    .first
                if let seasonId = firstSeason?.id {
                    let firstEpisodes = try await appState.apiClient.getEpisodes(
                        seriesId: seriesId, seasonId: seasonId, userId: userId
                    )
                    let firstEpisode = firstEpisodes
                        .sorted { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
                        .first
                    resolved = firstEpisode?.id.map { ($0, seasonId) }
                } else {
                    resolved = nil
                }
            }
            guard let resolved else {
                logger.debug("hero-nav unresolved series=\(seriesId, privacy: .public)")
                heroPlay = nil
                return
            }
            let episodeId = resolved.episodeId
            let seasonId = resolved.seasonId
            let episodes = try await appState.apiClient.getEpisodes(
                seriesId: seriesId, seasonId: seasonId, userId: userId
            )
            let nav = buildEpisodeNavigation(for: episodeId, in: episodes)
            // Take the title and resume position from the episode as it appears
            // in the season list, so both resolution paths (next-up and the
            // first-episode fallback, where `nextUp` is nil) agree.
            let episode = episodes.first { $0.id == episodeId }
            heroPlay = HeroPlay(
                itemId: episodeId,
                title: episode?.name ?? hero.name ?? "",
                // Same SSOT as every other resume site: a residual position on
                // a played item is not a resume.
                startSeconds: CardPlayTargetResolver.resumeSeconds(
                    positionTicks: episode?.userData?.playbackPositionTicks ?? 0,
                    isPlayed: episode?.userData?.isPlayed ?? false
                ),
                previous: nav.previous, next: nav.next, navigator: nav.navigator
            )
            logger.debug("""
                hero-nav ready episode=\(episodeId, privacy: .public) \
                episodes=\(episodes.count, privacy: .public) \
                hasPrev=\(nav.previous != nil, privacy: .public) \
                hasNext=\(nav.next != nil, privacy: .public) \
                hasNavigator=\(nav.navigator != nil, privacy: .public)
                """)
        } catch {
            logger.notice("hero-nav failed: \(error.localizedDescription, privacy: .public)")
            heroPlay = nil
        }
    }

    /// Loads the filtered grid from page 0 — **once per filter**.
    ///
    /// Its caller is the grid's `.task(id: viewModel.sortFilter)`, and
    /// `.task(id:)` re-fires on every *attach*, not only on id change (same
    /// trap as the browse fan-out's `.task(id: sortFilter)` one screen over).
    /// The screen relies on `onAppear`/`onDisappear` for its `isVisible` flag,
    /// so the attach really does happen on every tab round-trip — and each one
    /// re-ran `filteredLoader.reset()` → page 0. Measured on device 2026-08-21:
    /// a "unwatched only" grid scrolled down to « Les Rayons et les Ombres /
    /// Le Parrain 3 / Dirty Dancing » was back on « La Petite Princesse », at
    /// the top, after a single trip through the Accueil tab. Locked by
    /// `MediaLibraryRefreshSpanTests`.
    ///
    /// **The stamp is on the filter, NOT on `isFiltered`** — the `guard
    /// sortFilter.isFiltered` shortcut is explicitly proscribed: this same
    /// function is what loads an iOS grid in sort-only state (`isNonDefault`
    /// true, `isFiltered` false), which would then never load at all.
    ///
    /// Stamped only once the load actually produced a list (or a legitimately
    /// empty one), so a failed fetch still retries on the next attach.
    func applyFilter(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        let snapshot = sortFilter
        guard appliedFilterStamp != snapshot else { return }
        // A different filter describes a different list, so an anchor taken on
        // the previous one means nothing. Cleared BEFORE the fetch so the first
        // page comes back unanchored — and note the stamp guard above is what
        // lets an anchor survive a tab round-trip, where the filter is
        // unchanged and `applyFilter` no-ops.
        letterAnchor = nil
        filteredLoader.reset()
        await loadMoreFiltered(using: appState, userId: userId)
        if !filteredLoader.items.isEmpty || filteredLoader.hasLoadedAll {
            appliedFilterStamp = snapshot
        }
    }

    func loadMoreFiltered(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        await loadMoreFiltered(using: appState, userId: userId)
    }

    /// Targeted refresh for a tier-2 `.cinemaxItemUserDataChanged`: re-pulls
    /// only what the user has already paged in, in place.
    ///
    /// The screen used to answer that notification with a full `reload`, which
    /// runs `applyFilter` → `filteredLoader.reset()` → page 0. The cards in
    /// this grid carry a context menu whose own watched/favorite toggles raise
    /// that very notification, so a grid scrolled several pages deep collapsed
    /// to 40 items **under the user's finger**. `refreshLoadedSpan` is the
    /// documented remedy and was wired on `FavoritesScreen` and
    /// `WatchedHistoryScreen` but not here — a missed surface, not a
    /// trade-off. Locked by `MediaLibraryRefreshSpanTests`.
    ///
    /// No-op when nothing has been paged in (the loader's own guard): a browse
    /// layout has no filtered page to refresh, and the tier-1 path still owns
    /// full reloads.
    func refreshUserData(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        let currentSortFilter = sortFilter
        let typeFilter: [BaseItemKind]? = itemType.map { [$0] }
        let parentScopeID = parentId
        let anchor = letterAnchor
        await filteredLoader.refreshLoadedSpan { startIndex, limit in
            try await self.fetchFilteredPage(
                using: appState, userId: userId, sortFilter: currentSortFilter,
                typeFilter: typeFilter, parentScopeID: parentScopeID,
                anchor: anchor, startIndex: startIndex, limit: limit
            )
        }
    }

    /// The one query, shared by pagination and by `refreshUserData` so the two
    /// can never disagree on sort/filter — same discipline as
    /// `FavoritesViewModel.page`.
    private func fetchFilteredPage(
        using appState: AppState, userId: String,
        sortFilter currentSortFilter: LibrarySortFilterState,
        typeFilter: [BaseItemKind]?, parentScopeID: String?,
        anchor: String?,
        startIndex: Int, limit: Int
    ) async throws -> (items: [BaseItemDto], total: Int) {
        let genres = currentSortFilter.selectedGenres.isEmpty ? nil : Array(currentSortFilter.selectedGenres)
        let filters: [ItemFilter]? = currentSortFilter.showUnwatchedOnly ? [.isUnplayed] : nil
        let years = currentSortFilter.expandedYears
        let result = try await appState.apiClient.getItems(
            userId: userId,
            parentId: parentScopeID,
            includeItemTypes: typeFilter,
            sortBy: [currentSortFilter.sortBy],
            sortOrder: currentSortFilter.sortAscending ? [.ascending] : [.descending],
            genres: genres,
            years: years,
            filters: filters,
            nameStartsWithOrGreater: anchor,
            limit: limit,
            startIndex: startIndex
        )
        return (items: result.items, total: result.totalCount)
    }

    private func loadMoreFiltered(using appState: AppState, userId: String) async {
        let currentSortFilter = sortFilter
        let typeFilter: [BaseItemKind]? = itemType.map { [$0] }
        let parentScopeID = parentId
        let anchor = letterAnchor
        await filteredLoader.loadMore { startIndex in
            try await self.fetchFilteredPage(
                using: appState, userId: userId, sortFilter: currentSortFilter,
                typeFilter: typeFilter, parentScopeID: parentScopeID,
                anchor: anchor, startIndex: startIndex, limit: 40
            )
        }
        // Only an unanchored page can speak for the whole set.
        if anchor == nil { unanchoredTotal = filteredLoader.totalCount }
    }

    /// Re-anchors the filtered grid at the first title sorting at or after
    /// `letter`, and lets pagination continue from there. `"#"` clears the
    /// anchor and returns to the start of the list.
    ///
    /// Jellyfin never reports an item's RANK, so an A–Z bar cannot "scroll to
    /// M" in an offset-paginated grid: M's first title may sit hundreds of
    /// items past everything paged in, and the bar's own lookup — which only
    /// ever searched the loaded pages — simply returned nothing, with no jump,
    /// no fetch and no message. Measured on device 2026-08-24 (defect M): on a
    /// 503-film catalogue whose first page ended in the B's, **C through Z were
    /// dead from the moment the screen opened**, i.e. the bar was inert exactly
    /// when pagination made it necessary.
    ///
    /// "Everything from M onward" is one request whatever the catalogue's size,
    /// which is why this re-anchors instead of paging forward to the letter.
    /// The cost is that titles before the anchor leave the grid — deliberate,
    /// and the reason `"#"` is always available to come back.
    ///
    /// Returns `false` only when there is nothing to do, so the caller never
    /// reports a jump that did not happen.
    @discardableResult
    func anchorGrid(atLetter letter: String, using appState: AppState) async -> Bool {
        guard let userId = appState.currentUserId else { return false }
        let target: String? = letter == "#" ? nil : letter.uppercased()
        // Already anchored there: the tap is honoured (the caller scrolls to
        // the top of the grid) but costs no request.
        guard target != letterAnchor else { return true }
        letterAnchor = target
        filteredLoader.reset()
        await loadMoreFiltered(using: appState, userId: userId)
        return true
    }
}
