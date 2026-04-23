#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminPlaybackViewModel {
    /// Working copy. Bindings in the UI read/write this.
    var edited: EncodingOptions?
    /// Snapshot from the last successful load/save — compared against `edited`
    /// to decide `isDirty`. `EncodingOptions` is `Hashable` so structural
    /// equality Just Works.
    private var original: EncodingOptions?

    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    var isDirty: Bool {
        guard let edited, let original else { return false }
        return edited != original
    }

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = edited == nil
        errorMessage = nil
        defer { isLoading = false }
        do {
            let options = try await apiClient.getEncodingOptions()
            edited = options
            original = options
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
            try await apiClient.updateEncodingOptions(edited)
            original = edited
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
#endif
