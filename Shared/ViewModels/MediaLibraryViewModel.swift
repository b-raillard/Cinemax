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
    let filteredLoader = PaginatedLoader<BaseItemDto>(pageSize: 40)

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
        // Drain (cancel AND await) any background initial load before taking
        // over. `cancel()` only *requests* cancellation, so without the await
        // the old load would keep running and its writes (isLoading / heroItem
        // / itemsByGenre, plus its trailing `loadTask = nil`) could interleave
        // with — and clobber — ours as last-writer-wins. The cancelled load
        // early-returns without touching state, so draining it is cheap.
        let inFlight = loadTask
        inFlight?.cancel()
        await inFlight?.value
        loadTask = nil

        let succeeded = await performLoad(using: appState, loc: loc)
        if succeeded { hasLoaded = true }
        if sortFilter.isFiltered {
            await applyFilter(using: appState)
        }
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
            async let genresResult = appState.apiClient.getGenres(
                userId: userId,
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

            // Progressive render: the hero (and its `totalCount`) are ready, so
            // drop the skeleton now. The genre rows fetched below fill in off
            // their own `@Observable` slice (`itemsByGenre`) as each lands.
            isLoading = false
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
    }

    func reloadGenreItems(using appState: AppState) async {
        guard !genres.isEmpty, let userId = appState.currentUserId else { return }
        try? await fetchGenreItems(using: appState, userId: userId, genres: genres)
    }

    func applyFilter(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        filteredLoader.reset()
        await loadMoreFiltered(using: appState, userId: userId)
    }

    func loadMoreFiltered(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        await loadMoreFiltered(using: appState, userId: userId)
    }

    private func loadMoreFiltered(using appState: AppState, userId: String) async {
        let currentSortFilter = sortFilter
        let typeFilter: [BaseItemKind]? = itemType.map { [$0] }
        let parentScopeID = parentId
        await filteredLoader.loadMore { startIndex in
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
                limit: 40,
                startIndex: startIndex
            )
            return (items: result.items, total: result.totalCount)
        }
    }
}
