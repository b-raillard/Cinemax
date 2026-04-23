#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminNetworkViewModel {
    var edited: NetworkConfiguration?
    private var original: NetworkConfiguration?

    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var showSaveWarning = false

    var isDirty: Bool {
        guard let edited, let original else { return false }
        return edited != original
    }

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = edited == nil
        errorMessage = nil
        defer { isLoading = false }
        do {
            let config = try await apiClient.getNetworkConfiguration()
            edited = config
            original = config
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(using apiClient: any APIClientProtocol) async -> Bool {
        guard let edited else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await apiClient.updateNetworkConfiguration(edited)
            original = edited
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
#endif
