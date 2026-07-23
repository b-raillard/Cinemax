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

        enum Section { case resume([BaseItemDto]); case latest([BaseItemDto]); case favorites([BaseItemDto]); case nextUp([BaseItemDto]) }

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
                do {
                    return .latest(try await appState.apiClient.getLatestMedia(userId: userId, limit: 20))
                } catch {
                    logger.warning("Home latest fetch failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
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
            for await result in group {
                switch result {
                case .resume(let items): resumeItems = items
                case .latest(let items): latestItems = items
                case .favorites(let items): favoriteItems = items
                case .nextUp(let items): nextUpItems = items
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
        resumeNavigation = buildNavigationMap(
            for: resumeEpisodes, seasonEpisodes: seasonEpisodes, userId: userId, appState: appState
        )
        nextUpNavigation = buildNavigationMap(
            for: nextUpEpisodes, seasonEpisodes: seasonEpisodes, userId: userId, appState: appState
        )

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

        var seasonEpisodes: [String: [BaseItemDto]] = [:]
        await withTaskGroup(of: (String, [BaseItemDto])?.self) { group in
            var seen = Set<String>()
            for item in episodeItems {
                guard let seasonId = item.seasonID,
                      let seriesId = item.seriesID,
                      !seen.contains(seasonId) else { continue }
                seen.insert(seasonId)
                group.addTask {
                    guard let eps = try? await appState.apiClient.getEpisodes(
                        seriesId: seriesId, seasonId: seasonId, userId: userId
                    ) else { return nil }
                    return (seasonId, eps)
                }
            }
            for await result in group {
                if let (seasonId, eps) = result { seasonEpisodes[seasonId] = eps }
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
        seasonEpisodes: [String: [BaseItemDto]],
        userId: String,
        appState: AppState
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
                for: id, refs: pre.refs, indexByID: pre.indexByID,
                apiClient: appState.apiClient, userId: userId
            )
        }
        return navigation
    }

    // MARK: - Continue Watching context-menu mutations

    /// Marks a Continue Watching item fully played. Jellyfin clears its resume
    /// position when an item is played, so it also drops out of the resume
    /// rail. Optimistically removes the card, shows a success toast, and
    /// re-fetches the rail in the background; on failure the item is restored
    /// and a user-facing error toast is shown.
    func markResumeItemPlayed(
        _ item: BaseItemDto,
        using appState: AppState,
        toast: ToastCenter,
        loc: LocalizationManager
    ) async {
        await mutateResumeItem(
            item, markPlayed: true,
            successKey: "home.continueWatching.markedWatched",
            using: appState, toast: toast, loc: loc
        )
    }

    /// Removes an item from Continue Watching. There is no dedicated
    /// "hide from resume" endpoint in Jellyfin — the standard client mechanism
    /// is to clear the item's played/progress state (`markItemUnplayed`), which
    /// resets its resume position so `/UserItems/Resume` stops returning it.
    func removeResumeItem(
        _ item: BaseItemDto,
        using appState: AppState,
        toast: ToastCenter,
        loc: LocalizationManager
    ) async {
        await mutateResumeItem(
            item, markPlayed: false,
            successKey: "home.continueWatching.removed",
            using: appState, toast: toast, loc: loc
        )
    }

    /// Shared body for both Continue Watching mutations: optimistic removal →
    /// server call → success toast + background rail refresh, restoring the
    /// card on failure.
    private func mutateResumeItem(
        _ item: BaseItemDto,
        markPlayed: Bool,
        successKey: String,
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
            if markPlayed {
                try await appState.apiClient.markItemPlayed(itemId: id, userId: userId)
            } else {
                try await appState.apiClient.markItemUnplayed(itemId: id, userId: userId)
            }
            toast.success(loc.localized(successKey))
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
            // Background refresh so the rail reflects server truth (e.g. a
            // series' next-up episode surfacing once the current one is
            // watched) without re-running the whole Home load.
            await refreshResume(using: appState)
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

    /// Fetches active sessions and filters down to ones with a currently-playing item,
    /// excluding the logged-in user (their own "resume" already covers that).
    private func loadActiveSessions(userId: String, appState: AppState) async {
        // "Watching Now" is admin-only. /Sessions is meant to be elevated and
        // even leaks every user's session to non-admins on some servers
        // (jellyfin#5210), so don't fetch it at all unless the caller is an
        // admin — the Home row and Settings toggle are likewise admin-gated.
        guard appState.isAdministrator else {
            activeSessions = []
            return
        }
        do {
            let all = try await appState.apiClient.getActiveSessions(activeWithinSeconds: 60)
            activeSessions = all.filter { session in
                session.nowPlayingItem != nil
                    && (session.userID ?? "") != userId
            }
        } catch {
            activeSessions = []
        }
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
    func retryGenre(_ genre: String, using appState: AppState) async {
        guard let userId = appState.currentUserId,
              let index = genreRows.firstIndex(where: { $0.genre == genre }) else { return }
        do {
            let items = try await Self.fetchGenreItems(genre: genre, userId: userId, appState: appState)
            if items.isEmpty {
                genreRows.remove(at: index)
            } else {
                genreRows[index].state = .items(items)
            }
        } catch {
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
