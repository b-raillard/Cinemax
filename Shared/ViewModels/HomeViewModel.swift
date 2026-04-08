import Foundation
import Observation
import CinemaxKit
import JellyfinAPI

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

        do {
            async let resume = appState.apiClient.getResumeItems(userId: userId, limit: 20)
            async let latest = appState.apiClient.getLatestMedia(userId: userId, limit: 20)

            resumeItems = try await resume
            latestItems = try await latest

            // Pick first resume item or first latest as hero
            heroItem = resumeItems.first ?? latestItems.first
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
