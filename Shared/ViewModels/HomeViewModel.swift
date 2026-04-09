import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class HomeViewModel {
    var heroItem: BaseItemDto?
    var resumeItems: [BaseItemDto] = []
    var latestItems: [BaseItemDto] = []
    /// Episode navigation keyed by episode item ID. Populated after resumeItems loads.
    var resumeNavigation: [String: (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)] = [:]
    var isLoading = true
    var errorMessage: String?

    func load(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true
        errorMessage = nil

        enum Section { case resume([BaseItemDto]); case latest([BaseItemDto]) }

        await withTaskGroup(of: Section?.self) { group in
            group.addTask {
                (try? await appState.apiClient.getResumeItems(userId: userId, limit: 20))
                    .map { .resume($0) }
            }
            group.addTask {
                (try? await appState.apiClient.getLatestMedia(userId: userId, limit: 20))
                    .map { .latest($0) }
            }
            for await result in group {
                switch result {
                case .resume(let items): resumeItems = items
                case .latest(let items): latestItems = items
                case nil: break
                }
            }
        }

        heroItem = resumeItems.first ?? latestItems.first

        // For each unique season referenced by resume episodes, fetch the episode list once
        // so we can compute prev/next refs and build a navigator for the player.
        let episodeItems = resumeItems.filter { $0.type == .episode }
        if !episodeItems.isEmpty {
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

            for item in episodeItems {
                guard let id = item.id, let seasonId = item.seasonID else { continue }
                guard let eps = seasonEpisodes[seasonId] else { continue }
                let nav = buildEpisodeNavigation(
                    for: id, in: eps,
                    apiClient: appState.apiClient, userId: userId
                )
                resumeNavigation[id] = nav
            }
        }

        isLoading = false
    }
}
