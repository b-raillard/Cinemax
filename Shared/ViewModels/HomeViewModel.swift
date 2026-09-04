import Foundation
import Observation
import OSLog
import CinemaxKit
@preconcurrency import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Home")

/// Presentation state for a single genre row on Home. `.failed` surfaces a
/// retry chip instead of silently skipping the row, so transient server
/// errors don't just make content disappear.
enum GenreRowState: Equatable {
    case items([BaseItemDto])
    case failed
}

struct GenreRow: Identifiable, Equatable {
    let genre: String
    var state: GenreRowState
    var id: String { genre }
}

@MainActor @Observable
final class HomeViewModel {
    var heroItem: BaseItemDto?
    var resumeItems: [BaseItemDto] = []
    var latestItems: [BaseItemDto] = []
    /// User-hearted movies/series, most recently favorited first.
    var favoriteItems: [BaseItemDto] = []

    /// The user's playlists, for the Home rail.
    ///
    /// Before this rail existed the app could CREATE a playlist and then never
    /// show it again: `getPlaylists` had exactly one caller — the "add to a
    /// playlist" sheet — and the only screen listing playlists was reachable
    /// solely from a `.custom + .library` menu on a server that exposes a
    /// Playlists view. On the default five-tab menu there was no path at all.
    var playlists: [BaseItemDto] = []
    /// Episodes the server expects to air soon. A calendar, not a queue —
    /// nothing here is playable yet, which is why its cards carry no Play and
    /// no context menu.
    var upcomingItems: [BaseItemDto] = []
    /// The user's collections (BoxSets). On the default five tabs a collection
    /// was reachable only through a `.custom + .library` menu on a server that
    /// exposes a Collections view — the same shape that made playlists
    /// unfindable before their own rail.
    var collections: [BaseItemDto] = []
    /// Next unwatched episode for every in-progress series — the global
    /// "Next Up" rail. Distinct from `resumeItems` (mid-episode resume points).
    var nextUpItems: [BaseItemDto] = []
    /// Ordered genre rows. `.failed` rows render a retry chip; rows that
    /// succeed but return zero items are dropped.
    var genreRows: [GenreRow] = []
    /// Episode navigation keyed by episode item ID. Populated after resumeItems loads.
    var resumeNavigation: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] = [:]
    /// Episode navigation for the Next Up rail, keyed by episode item ID. Mirrors
    /// `resumeNavigation` so Next Up cards also get prev/next episode buttons in
    /// the player. Populated after nextUpItems loads.
    var nextUpNavigation: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] = [:]
    /// Other users currently watching something on this server. Excludes the logged-in user.
    var activeSessions: [SessionInfoDto] = []
    /// Watch Together groups open on the server. Governed by the server's own
    /// `UserPolicy.syncPlayAccess`, NOT by `isAdministrator` — which is what
    /// lets a regular account see (and join) a session at all.
    var syncPlayGroups: [SyncPlayGroup] = []

    /// The merged "En direct" row: groups folded into one card each, then
    /// whoever is watching alone. See `LiveSessionsRow` for why the two sources
    /// share a row rather than sitting in two.
    var liveEntries: [LiveSessionsRow.Entry] {
        LiveSessionsRow.build(
            groups: syncPlayGroups,
            sessions: activeSessions,
            currentUserName: currentUserName
        )
    }
    /// Set alongside the fetch so the merge can drop the viewer from every card.
    private var currentUserName: String?
    /// Gates the full-screen skeleton — flips false once the phase-1 fetches
    /// (resume/latest/favorites/next-up) land and the hero is chosen, so the
    /// hero + rails render while genre rows and the episode-nav maps keep
    /// filling in off their own `@Observable` slices.
    var isLoading = true
    /// True only after the *entire* load (genre rows + nav maps included)
    /// completes. `HomeScreen` gates the all-empty `EmptyStateView` on this so
    /// it can't flash mid-load while later phases are still populating.
    var isFullyLoaded = false
    var errorMessage: String?

    /// How many cards "Recently Added" shows, and how many of them may be
    /// shows-that-just-got-episodes. The cap is what keeps the second source a
    /// *signal* rather than the row's content — an active TV library produces
    /// new episodes far faster than new titles, and letting it fill the row
    /// would recreate the crowding this split exists to fix.
    /// `nonisolated` because `mergeRecentlyAdded` is, and a nonisolated function
    /// can't read a main-actor-isolated `static let` — safe here, both are `Int`.
    nonisolated static let recentlyAddedLimit = 20
    nonisolated static let newEpisodeShowsLimit = 6

    /// Interleaves the two "Recently Added" sources.
    ///
    /// **The union cannot be sorted into one timeline.** A grouped series
    /// carries its OWN creation date, not the date of the episode that made it
    /// surface — so sorting by `dateCreated` would bury every long-owned show
    /// that just got a new season, which is precisely the signal the second
    /// source exists to carry. Shows with new episodes therefore lead (capped),
    /// new titles fill the rest, and a show present in both keeps its lead
    /// position.
    ///
    /// `nonisolated` + pure so the ordering rule is unit-testable without a
    /// view model or an API — same treatment as `buildNavigationMap`.
    nonisolated static func mergeRecentlyAdded(
        showsWithNewEpisodes: [BaseItemDto],
        newTitles: [BaseItemDto]
    ) -> [BaseItemDto] {
        var seen = Set<String>()
        var merged: [BaseItemDto] = []
        merged.reserveCapacity(recentlyAddedLimit)
        for item in showsWithNewEpisodes.prefix(newEpisodeShowsLimit) + newTitles {
            // An id-less item can't be deduplicated, but it is still shown:
            // dropping it would silently shrink the row, and the card layer
            // already degrades gracefully without an id.
            if let id = item.id, !seen.insert(id).inserted { continue }
            merged.append(item)
            if merged.count == recentlyAddedLimit { break }
        }
        return merged
    }

    /// Guards `loadInitial` so tab remounts (tvOS recreates hosting controllers
    /// when the bar layout shifts) don't re-hit the API and re-shuffle the
    /// genre rows. Same pattern as `MediaLibraryViewModel.hasLoaded`.
    private var hasLoaded = false

    /// First load — no-op if content is already loaded (screen remount).
    func loadInitial(using appState: AppState) async {
        guard !hasLoaded else { return }
        await load(using: appState)
    }

    /// Re-runs the full home load (equivalent to calling `load` again). Exposed
    /// for pull-to-refresh and `.cinemaxShouldRefreshCatalogue` — bypasses the
    /// `hasLoaded` guard.
    func reload(using appState: AppState) async {
        activeSessions = []
        await load(using: appState)
    }

    /// Internal (not private) so `HomeViewModelTests` can drive it directly
    /// via `@testable` — app code goes through `loadInitial`/`reload`.
    func load(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        hasLoaded = true
        isLoading = true
        isFullyLoaded = false
        errorMessage = nil

        enum Section {
            case resume([BaseItemDto]); case latest([BaseItemDto]); case favorites([BaseItemDto])
            case nextUp([BaseItemDto]); case playlists([BaseItemDto])
            case upcoming([BaseItemDto]); case collections([BaseItemDto])
        }

        await withTaskGroup(of: Section?.self) { group in
            group.addTask {
                do {
                    return .resume(try await appState.apiClient.getResumeItems(userId: userId, limit: 20))
                } catch {
                    logger.warning("Home resume fetch failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                // "Recently added" has TWO sources, because no single query
                // expresses both halves of what the row means.
                //
                // `/Items/Latest` alone was the bug: it scans raw items —
                // episodes included — and groups them under their series, so a
                // library ingesting one show's back catalogue filled the whole
                // scan with its episodes and they collapsed into a SINGLE card.
                // But that grouping is also the *feature*: it's what makes a
                // long-owned series resurface when a new season lands.
                //
                // So: new titles by date added, plus shows that just received
                // episodes, each fetched with its own budget. No single show can
                // crowd the row out, and that holds regardless of whether the
                // server applies its limit before or after grouping.
                //
                // Each source degrades on its own — one failing leaves the other
                // populating the row rather than blanking it.
                let newTitles = try? await appState.apiClient.getItems(
                    userId: userId,
                    includeItemTypes: [.movie, .series],
                    sortBy: [.dateCreated],
                    sortOrder: [.descending],
                    limit: Self.recentlyAddedLimit
                ).items
                let showsWithNewEpisodes = try? await appState.apiClient.getSeriesWithRecentEpisodes(
                    userId: userId, limit: Self.newEpisodeShowsLimit
                )
                if newTitles == nil && showsWithNewEpisodes == nil {
                    logger.warning("Home latest fetch failed: both sources errored")
                    return nil
                }
                return .latest(HomeViewModel.mergeRecentlyAdded(
                    showsWithNewEpisodes: showsWithNewEpisodes ?? [],
                    newTitles: newTitles ?? []
                ))
            }
            group.addTask {
                do {
                    return .favorites(try await appState.apiClient.getItems(
                        userId: userId,
                        includeItemTypes: [.movie, .series],
                        sortBy: [.dateCreated],
                        sortOrder: [.descending],
                        isFavorite: true,
                        limit: 20
                    ).items)
                } catch {
                    logger.warning("Home favorites fetch failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                do {
                    return .nextUp(try await appState.apiClient.getNextUpEpisodes(userId: userId, limit: 20))
                } catch {
                    logger.warning("Home next-up fetch failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                do {
                    return .playlists(try await appState.apiClient.getPlaylists(userId: userId))
                } catch {
                    logger.warning("Home playlists fetch failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                do {
                    return .upcoming(try await appState.apiClient.getUpcomingEpisodes(userId: userId, limit: 20))
                } catch {
                    logger.warning("Home upcoming fetch failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                do {
                    // No `parentId`: the user's collections wherever they live,
                    // rather than those of one library.
                    return .collections(try await appState.apiClient.getItems(
                        userId: userId,
                        includeItemTypes: [.boxSet],
                        sortBy: [.sortName],
                        sortOrder: [.ascending],
                        limit: 20
                    ).items)
                } catch {
                    logger.warning("Home collections fetch failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            for await result in group {
                switch result {
                case .resume(let items): resumeItems = items
                case .latest(let items): latestItems = items
                case .favorites(let items): favoriteItems = items
                case .nextUp(let items): nextUpItems = items
                case .playlists(let items): playlists = items
                case .upcoming(let items): upcomingItems = items
                case .collections(let items): collections = items
                case nil: break
                }
            }
        }

        heroItem = resumeItems.first ?? latestItems.first

        // Progressive render: the hero + rails are ready, so drop the skeleton
        // now. Genre rows, active sessions, and the episode-nav maps keep filling
        // in below off their own `@Observable` slices (the nav maps only gate the
        // in-player prev/next buttons — nothing on the initial paint).
        isLoading = false

        // Genre rows + active sessions depend on nothing from the episode-nav
        // phase below — run them concurrently with the navigation builds (each
        // method only mutates its own state slice, serialized on the main actor).
        async let genreRowsDone: Void = loadGenreRows(userId: userId, appState: appState)
        async let sessionsDone: Void = loadActiveSessions(userId: userId, appState: appState)

        // Build prev/next episode navigation for BOTH episode rails — Continue
        // Watching and Next Up. Fetch every referenced season's episode list
        // exactly once across BOTH rails (overlapping seasons were fetched twice
        // before), then derive each map from the shared season→episodes dict.
        let resumeEpisodes = resumeItems.filter { $0.type == .episode }
        let nextUpEpisodes = nextUpItems.filter { $0.type == .episode }
        let seasonEpisodes = await fetchSeasonEpisodes(
            for: resumeEpisodes + nextUpEpisodes, userId: userId, appState: appState
        )
        resumeNavigation = buildNavigationMap(for: resumeEpisodes, seasonEpisodes: seasonEpisodes)
        nextUpNavigation = buildNavigationMap(for: nextUpEpisodes, seasonEpisodes: seasonEpisodes)

        _ = await (genreRowsDone, sessionsDone)

        isFullyLoaded = true
    }

    /// Fetches the episode list for every unique season referenced by
    /// `episodeItems`, exactly once. Shared across the Continue Watching and Next
    /// Up rails so a season referenced by both is fetched a single time (the
    /// `getEpisodes` 10s cache backs this up across separate calls too).
    private func fetchSeasonEpisodes(
        for episodeItems: [BaseItemDto],
        userId: String,
        appState: AppState
    ) async -> [String: [BaseItemDto]] {
        guard !episodeItems.isEmpty else { return [:] }

        // Dedup first — one entry per unique season across BOTH rails.
        var seen = Set<String>()
        var seasons: [(seasonId: String, seriesId: String)] = []
        for item in episodeItems {
            guard let seasonId = item.seasonID,
                  let seriesId = item.seriesID,
                  !seen.contains(seasonId) else { continue }
            seen.insert(seasonId)
            seasons.append((seasonId: seasonId, seriesId: seriesId))
        }

        // Bound the fan-out to chunks of 6, matching every other fan-out in the
        // app (`loadGenreRows` below, `MediaLibraryViewModel.fetchGenreItems`).
        // The two rails carry up to 20 items each, so an unchunked group could
        // fire ~40 concurrent `getEpisodes` at a self-hosted server — while the
        // genre fan-out is running alongside it.
        let concurrencyLimit = 6
        var seasonEpisodes: [String: [BaseItemDto]] = [:]
        for start in stride(from: 0, to: seasons.count, by: concurrencyLimit) {
            let chunk = seasons[start..<min(start + concurrencyLimit, seasons.count)]
            await withTaskGroup(of: (String, [BaseItemDto])?.self) { group in
                for season in chunk {
                    group.addTask {
                        guard let eps = try? await appState.apiClient.getEpisodes(
                            seriesId: season.seriesId, seasonId: season.seasonId, userId: userId
                        ) else { return nil }
                        return (season.seasonId, eps)
                    }
                }
                for await result in group {
                    if let (seasonId, eps) = result { seasonEpisodes[seasonId] = eps }
                }
            }
        }
        return seasonEpisodes
    }

    /// Builds a prev/next episode-navigation map keyed by episode item ID for a
    /// set of episode items, deriving each episode's prev/next from the shared
    /// `seasonEpisodes` dict. Precomputes refs + id→index per referenced season
    /// so each lookup is O(1). Pure (no fetching) — the season episode lists are
    /// resolved once up front by `fetchSeasonEpisodes`.
    private func buildNavigationMap(
        for episodeItems: [BaseItemDto],
        seasonEpisodes: [String: [BaseItemDto]]
    ) -> [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] {
        guard !episodeItems.isEmpty else { return [:] }

        var precomputed: [String: (refs: [EpisodeRef], indexByID: [String: Int])] = [:]
        for item in episodeItems {
            guard let seasonId = item.seasonID,
                  precomputed[seasonId] == nil,
                  let eps = seasonEpisodes[seasonId] else { continue }
            precomputed[seasonId] = precomputeEpisodeRefs(eps)
        }

        var navigation: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] = [:]
        for item in episodeItems {
            guard let id = item.id,
                  let seasonId = item.seasonID,
                  let pre = precomputed[seasonId] else { continue }
            navigation[id] = buildEpisodeNavigation(
                for: id, refs: pre.refs, indexByID: pre.indexByID
            )
        }
        return navigation
    }

    // MARK: - Continue Watching context-menu mutations

    /// Removes an item from Continue Watching. There is no dedicated
    /// "hide from resume" endpoint in Jellyfin — the standard client mechanism
    /// is to clear the item's played/progress state (`markItemUnplayed`), which
    /// resets its resume position so `/UserItems/Resume` stops returning it.
    /// Optimistic removal → server call → success toast, restoring the card on
    /// failure.
    ///
    /// This was two functions, a wrapper passing a `successKey` into a shared
    /// body, back when a "mark as watched" sibling existed. That sibling moved
    /// into the shared card menu, leaving one caller and one constant key — so
    /// the indirection is gone with it.
    func removeResumeItem(
        _ item: BaseItemDto,
        using appState: AppState,
        toast: ToastCenter,
        loc: LocalizationManager
    ) async {
        guard let userId = appState.currentUserId, let id = item.id,
              let index = resumeItems.firstIndex(where: { $0.id == id }) else { return }

        // Optimistic removal so the rail updates instantly.
        let removed = resumeItems.remove(at: index)
        resumeNavigation[id] = nil

        do {
            try await appState.apiClient.markItemUnplayed(itemId: id, userId: userId)
            toast.success(loc.localized("home.continueWatching.removed"))
            // One item's userData changed — post the lighter tier-2 notification.
            // Home's own `.cinemaxItemUserDataChanged` handler re-fetches the
            // resume rail exactly once (via `refreshUserDataRails`), which also
            // catches server truth like a series' next-up episode surfacing once
            // the current one is watched; other screens react per the two-tier
            // scheme. No explicit `refreshResume` here — that would double-fetch.
            NotificationCenter.default.post(name: .cinemaxItemUserDataChanged, object: nil)
        } catch {
            logger.error("Resume item mutation failed: \(error.localizedDescription, privacy: .public)")
            // Restore at (clamped) original position and surface the error.
            resumeItems.insert(removed, at: min(index, resumeItems.count))
            toast.error(loc.userFacingMessage(for: error))
        }
    }

    /// Re-fetches just the Continue Watching rail from the server — used after
    /// a context-menu mutation so the rail reflects server truth without
    /// re-running the whole Home load (which would re-shuffle the genre rows).
    private func refreshResume(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        if let items = try? await appState.apiClient.getResumeItems(userId: userId, limit: 20) {
            resumeItems = items
        }
    }

    /// Lightweight refresh of just the Favorites row — fired by
    /// `.cinemaxFavoritesChanged` after a heart toggle, so the row reflects
    /// the change without re-running the whole Home load (which would
    /// re-shuffle genre rows).
    func refreshFavorites(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        do {
            favoriteItems = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.movie, .series],
                sortBy: [.dateCreated],
                sortOrder: [.descending],
                isFavorite: true,
                limit: 20
            ).items
        } catch {
            logger.warning("Favorites refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Lightweight refresh of just the Playlists row — fired by
    /// `.cinemaxPlaylistsChanged` after a create-or-add, so a playlist the user
    /// just made appears without a full Home reload. Without it the rail that
    /// exists to make playlists findable would itself be the last place to
    /// learn about a new one.
    func refreshPlaylists(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        do {
            playlists = try await appState.apiClient.getPlaylists(userId: userId)
        } catch {
            logger.warning("Playlists refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Targeted refresh of only the userData-dependent rails — Continue Watching
    /// (resume), Next Up, and Favorites — fired by `.cinemaxItemUserDataChanged`
    /// after a per-item watched / resume toggle anywhere in the app. Mirrors
    /// `refreshResume` / `refreshFavorites`: single fetches mutating only those
    /// `@Observable` slices, NO genre fan-out / latest / sessions.
    ///
    /// It *does* fill in episode navigation for whatever card these fetches
    /// bring in — see `fillMissingEpisodeNavigation`. It used to skip that on
    /// the grounds that the maps "only gate the in-player prev/next buttons and
    /// tolerate brief staleness". Both halves were wrong: a nil navigator also
    /// silences autoplay-next and the end-of-series card, and a card that has
    /// just ENTERED a rail has no entry at all rather than a stale one.
    func refreshUserDataRails(using appState: AppState) async {
        async let resume: Void = refreshResume(using: appState)
        async let nextUp: Void = refreshNextUp(using: appState)
        async let favorites: Void = refreshFavorites(using: appState)
        _ = await (resume, nextUp, favorites)
        await fillMissingEpisodeNavigation(using: appState)
    }

    /// Builds episode navigation for the rail cards that don't have any yet.
    ///
    /// `load()` builds both maps in one pass over the rails as they were then;
    /// this covers every card that enters a rail LATER, through
    /// `refreshUserDataRails` — which is the ordinary path, not an edge case:
    /// finishing an episode posts the tier-2 notification, the rails refetch,
    /// and the very next thing the user taps is the freshly-arrived card.
    /// Measured on device 2026-08-21: that card played with **3** transport
    /// buttons where a full Home reload gave it **5**, and the same card's
    /// context menu — which resolves its own navigation — gave 5 throughout.
    ///
    /// Deliberately scoped to the **missing** entries. An existing one stays
    /// valid (navigation depends on the season's episode list, not on the
    /// card's userData), so re-deriving the whole map on every watched toggle
    /// anywhere in the app would re-fetch every referenced season for nothing.
    /// With nothing new in the rails this is a no-op that issues no request.
    private func fillMissingEpisodeNavigation(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        let missingResume = resumeItems.filter { item in
            item.type == .episode && item.id.map { resumeNavigation[$0] == nil } == true
        }
        let missingNextUp = nextUpItems.filter { item in
            item.type == .episode && item.id.map { nextUpNavigation[$0] == nil } == true
        }
        guard !missingResume.isEmpty || !missingNextUp.isEmpty else { return }

        let seasonEpisodes = await fetchSeasonEpisodes(
            for: missingResume + missingNextUp, userId: userId, appState: appState
        )
        resumeNavigation.merge(
            buildNavigationMap(for: missingResume, seasonEpisodes: seasonEpisodes)
        ) { _, new in new }
        nextUpNavigation.merge(
            buildNavigationMap(for: missingNextUp, seasonEpisodes: seasonEpisodes)
        ) { _, new in new }
    }

    /// Re-fetches just the Next Up rail. Companion to `refreshResume` — used by
    /// `refreshUserDataRails` so a watched toggle surfaces the freshly-unlocked
    /// next-up episode without re-running the whole Home load.
    private func refreshNextUp(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        if let items = try? await appState.apiClient.getNextUpEpisodes(userId: userId, limit: 20) {
            nextUpItems = items
        }
    }

    /// Fetches active sessions and filters down to ones with a currently-playing item,
    /// excluding the logged-in user (their own "resume" already covers that).
    private func loadActiveSessions(userId: String, appState: AppState) async {
        currentUserName = appState.currentUser?.name

        // Two sources, two permissions — and that split is what makes the row
        // reachable by everyone. `/Sessions` stays admin-only: it is meant to be
        // elevated and even leaks every user's session to non-admins on some
        // servers (jellyfin#5210). `GET /SyncPlay/List` is governed by the
        // server's own per-user SyncPlay policy, so a regular account still
        // sees the sessions it is allowed to join.
        // Both permissions are read HERE, on the main actor, and only the
        // resulting scalars cross into the concurrent closures below —
        // `AppState` is main-actor isolated and cannot be touched from them.
        let isAdmin = appState.isAdministrator
        let mayJoin = LiveSessionsRow.canJoin(appState.currentUser?.policy?.syncPlayAccess)
        let client = appState.apiClient

        async let sessions: [SessionInfoDto] = {
            guard isAdmin else { return [] }
            let all = (try? await client.getActiveSessions(activeWithinSeconds: 60)) ?? []
            return all.filter { $0.nowPlayingItem != nil && ($0.userID ?? "") != userId }
        }()

        async let groups: [SyncPlayGroup] = {
            guard mayJoin else { return [] }
            return (try? await client.syncPlayListGroups()) ?? []
        }()

        // Each source fails on its own: a dead `/Sessions` must not take the
        // groups down with it, and vice versa.
        activeSessions = await sessions
        syncPlayGroups = await groups
    }

    /// Re-fetches only the genre rows — fired from `HomeScreen` when the user
    /// changes their genre selection in Settings (the `home.selectedGenres`
    /// `@AppStorage` flips). Bypasses the `hasLoaded` guard so the change is
    /// reflected live without re-running the whole Home load.
    func reloadGenreRows(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        await loadGenreRows(userId: userId, appState: appState)
    }

    private func loadGenreRows(userId: String, appState: AppState) async {
        let allGenres: [String]
        do {
            allGenres = try await appState.apiClient.getGenres(
                userId: userId, includeItemTypes: [.movie, .series]
            )
        } catch {
            genreRows = []
            return
        }

        // Sort once so Home's row order matches the Settings picker order (both
        // use the same comparator) and stays coherent across launches.
        let sortedGenres = allGenres.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        guard !sortedGenres.isEmpty else {
            genreRows = []
            return
        }

        // User-configurable: the explicit picks (no cap), or a deterministic
        // default set when unconfigured. Each row's item fetch is still bounded
        // (limit 10) — we bound the fetch, not the number of rows.
        let picked = HomeGenrePreferences.effectiveGenres(available: sortedGenres)

        guard !picked.isEmpty else {
            genreRows = []
            return
        }

        // Fetch items for each picked genre. Since the row count is now
        // user-driven (no cap), bound the fan-out to chunks of 6 so a large
        // selection doesn't fire dozens of concurrent `getItems` at a
        // self-hosted server at once. Order is rebuilt from `picked` afterwards.
        // Distinguish failure (→ retry chip) from empty success (→ drop the row).
        enum FetchResult { case success([BaseItemDto]); case failure }
        let concurrencyLimit = 6
        var results: [String: FetchResult] = [:]
        for start in stride(from: 0, to: picked.count, by: concurrencyLimit) {
            let chunk = picked[start..<min(start + concurrencyLimit, picked.count)]
            await withTaskGroup(of: (String, FetchResult).self) { group in
                for genre in chunk {
                    group.addTask {
                        do {
                            let items = try await Self.fetchGenreItems(
                                genre: genre, userId: userId, appState: appState
                            )
                            return (genre, .success(items))
                        } catch {
                            return (genre, .failure)
                        }
                    }
                }
                for await (genre, result) in group {
                    results[genre] = result
                }
            }
        }

        genreRows = picked.compactMap { genre in
            switch results[genre] {
            case .success(let items) where !items.isEmpty:
                return GenreRow(genre: genre, state: .items(items))
            case .failure:
                return GenreRow(genre: genre, state: .failed)
            default:
                return nil
            }
        }
    }

    /// Re-fetches a single genre after the user taps its retry chip.
    /// Updates `genreRows` in place so only the affected row re-renders.
    /// The index is deliberately re-resolved by genre AFTER the await, in both
    /// the success and the failure path: `genreRows` can shrink or be replaced
    /// wholesale while the fetch is in flight (a pull-to-refresh runs
    /// `loadGenreRows`, a Settings genre-selection change runs
    /// `reloadGenreRows`, another retry chip can remove a row), and reusing the
    /// pre-await index crashes with `Fatal error: Index out of range` or writes
    /// into the wrong row. A nil lookup means the row is gone — the superseding
    /// load owns the state, so bail silently.
    func retryGenre(_ genre: String, using appState: AppState) async {
        guard let userId = appState.currentUserId,
              genreRows.contains(where: { $0.genre == genre }) else { return }
        do {
            let items = try await Self.fetchGenreItems(genre: genre, userId: userId, appState: appState)
            guard let index = genreRows.firstIndex(where: { $0.genre == genre }) else { return }
            if items.isEmpty {
                genreRows.remove(at: index)
            } else {
                genreRows[index].state = .items(items)
            }
        } catch {
            guard let index = genreRows.firstIndex(where: { $0.genre == genre }) else { return }
            genreRows[index].state = .failed
        }
    }

    nonisolated private static func fetchGenreItems(
        genre: String, userId: String, appState: AppState
    ) async throws -> [BaseItemDto] {
        let response = try await appState.apiClient.getItems(
            userId: userId,
            parentId: nil,
            includeItemTypes: [.movie, .series],
            sortBy: [.dateCreated],
            sortOrder: [.descending],
            genres: [genre],
            years: nil,
            isFavorite: nil,
            filters: nil,
            limit: 10,
            startIndex: nil
        )
        return response.items
    }
}
