import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class HomeViewModel {
    var heroItem: BaseItemDto?
    var resumeItems: [BaseItemDto] = []
    var latestItems: [BaseItemDto] = []
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
        isLoading = false
    }
}
