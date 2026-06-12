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

    init(itemType: BaseItemKind?, parentId: String? = nil) {
        self.itemType = itemType
        self.parentId = parentId
    }

    func loadInitial(using appState: AppState, loc: LocalizationManager) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await performLoad(using: appState, loc: loc)
    }

    func reload(using appState: AppState, loc: LocalizationManager) async {
        await performLoad(using: appState, loc: loc)
        if sortFilter.isFiltered {
            await applyFilter(using: appState)
        }
    }

    private func performLoad(using appState: AppState, loc: LocalizationManager) async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true
        errorMessage = nil

        let typeFilter: [BaseItemKind]? = itemType.map { [$0] }

        do {
            async let genresResult = appState.apiClient.getGenres(
                userId: userId,
                includeItemTypes: typeFilter
            )

            // The hero query already returns the full `totalCount` (Jellyfin's
            // `totalRecordCount` is the count before `limit`), so there's no need
            // for a second random-sorted `limit: 1` call just for the title count
            // — a random sort is a full shuffle server-side, paying for it twice
            // per library load is pure waste.
            async let heroResult = appState.apiClient.getItems(
                userId: userId,
                parentId: parentId,
                includeItemTypes: typeFilter,
                sortBy: [.random],
                sortOrder: [.ascending],
                limit: 20
            )

            let fetchedGenres = try await genresResult
            let heroData = try await heroResult

            genres = fetchedGenres
            totalCount = heroData.totalCount
            heroItem = heroData.items.randomElement()

            try await fetchGenreItems(using: appState, userId: userId, genres: fetchedGenres)
        } catch {
            logger.error("Library load failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = loc.userFacingMessage(for: error)
        }

        isLoading = false
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
        try await withThrowingTaskGroup(of: GenreResult.self) { group in
            for genre in genresToLoad {
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
