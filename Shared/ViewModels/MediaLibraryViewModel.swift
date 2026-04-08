import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - Sort & Filter State

struct LibrarySortFilterState: Equatable {
    var sortBy: ItemSortBy = .dateCreated
    var sortAscending: Bool = false
    var selectedGenres: Set<String> = []

    var isFiltered: Bool { !selectedGenres.isEmpty }
    var isNonDefault: Bool { sortBy != .dateCreated || sortAscending || isFiltered }
}

// MARK: - View Model

@MainActor @Observable
final class MediaLibraryViewModel {
    let itemType: BaseItemKind

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

    init(itemType: BaseItemKind) {
        self.itemType = itemType
    }

    func loadInitial(using appState: AppState) async {
        guard !hasLoaded, let userId = appState.currentUserId else { return }
        hasLoaded = true
        isLoading = true
        errorMessage = nil

        do {
            async let genresResult = appState.apiClient.getGenres(
                userId: userId,
                includeItemTypes: [itemType]
            )
            async let countResult = appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [itemType],
                sortBy: [.random],
                sortOrder: [.ascending],
                limit: 1
            )

            let fetchedGenres = try await genresResult
            let countData = try await countResult

            genres = fetchedGenres
            totalCount = countData.totalCount

            let heroResult = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [itemType],
                sortBy: [.random],
                sortOrder: [.ascending],
                limit: 20
            )
            heroItem = heroResult.items.randomElement()

            try await fetchGenreItems(using: appState, userId: userId, genres: fetchedGenres)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func fetchGenreItems(using appState: AppState, userId: String, genres genreList: [String]) async throws {
        struct GenreResult: @unchecked Sendable {
            let genre: String
            let items: [BaseItemDto]
        }
        let genresToLoad = Array(genreList.prefix(genreLoadLimit))
        try await withThrowingTaskGroup(of: GenreResult.self) { group in
            for genre in genresToLoad {
                group.addTask {
                    let result = try await appState.apiClient.getItems(
                        userId: userId,
                        includeItemTypes: [self.itemType],
                        sortBy: [self.sortFilter.sortBy],
                        sortOrder: self.sortFilter.sortAscending ? [.ascending] : [.descending],
                        genres: [genre],
                        limit: self.genreItemLimit
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
        let currentItemType = itemType
        await filteredLoader.loadMore { startIndex in
            let genres = currentSortFilter.selectedGenres.isEmpty ? nil : Array(currentSortFilter.selectedGenres)
            let result = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [currentItemType],
                sortBy: [currentSortFilter.sortBy],
                sortOrder: currentSortFilter.sortAscending ? [.ascending] : [.descending],
                genres: genres,
                limit: 40,
                startIndex: startIndex
            )
            return (items: result.items, total: result.totalCount)
        }
    }
}
