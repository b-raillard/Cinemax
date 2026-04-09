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
    var isLoading = true
    var errorMessage: String?

    // The resolved type after loading (episode/season → series)
    var resolvedType: BaseItemKind = .movie

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

                async let similar = appState.apiClient.getSimilarItems(itemId: seriesId, userId: userId, limit: 12)
                similarItems = try await similar

                seasons = try await appState.apiClient.getSeasons(seriesId: seriesId, userId: userId)
                if let firstSeason = seasons.first, let seasonId = firstSeason.id {
                    selectedSeasonId = seasonId
                    episodes = try await appState.apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
                }
                nextUpEpisode = try? await appState.apiClient.getNextUp(seriesId: seriesId, userId: userId)
            } else {
                item = loadedItem
                resolvedType = effectiveType

                async let similar = appState.apiClient.getSimilarItems(itemId: itemId, userId: userId, limit: 12)
                similarItems = try await similar

                if effectiveType == .series {
                    seasons = try await appState.apiClient.getSeasons(seriesId: itemId, userId: userId)
                    if let firstSeason = seasons.first, let seasonId = firstSeason.id {
                        selectedSeasonId = seasonId
                        episodes = try await appState.apiClient.getEpisodes(seriesId: itemId, seasonId: seasonId, userId: userId)
                    }
                    nextUpEpisode = try? await appState.apiClient.getNextUp(seriesId: itemId, userId: userId)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func selectSeason(_ seasonId: String, seriesId: String, using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        selectedSeasonId = seasonId
        do {
            episodes = try await appState.apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
        } catch {
            // Keep existing episodes on error
        }
    }
}
