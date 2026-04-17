import SwiftUI
import CinemaxKit
import JellyfinAPI

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

    /// Generation counter to discard stale season results on rapid selection.
    private var seasonGeneration: Int = 0

    let itemId: String
    let itemType: BaseItemKind

    init(itemId: String, itemType: BaseItemKind) {
        self.itemId = itemId
        self.itemType = itemType
    }

    func load(using appState: AppState) async {
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
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
    private func rebuildNavigationMaps(apiClient: any APIClientProtocol, userId: String) {
        episodeNavigationMap = [:]
        for episode in episodes {
            guard let id = episode.id else { continue }
            episodeNavigationMap[id] = buildEpisodeNavigation(for: id, in: episodes, apiClient: apiClient, userId: userId)
        }
        nextUpNavigationMap = [:]
        for episode in nextUpEpisodes {
            guard let id = episode.id else { continue }
            nextUpNavigationMap[id] = buildEpisodeNavigation(for: id, in: nextUpEpisodes, apiClient: apiClient, userId: userId)
        }
    }
}
