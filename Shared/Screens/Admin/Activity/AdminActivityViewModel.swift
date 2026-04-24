#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminActivityViewModel {
    var entries: [ActivityLogEntry] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    var hasMore = true
    var totalCount = 0

    private let pageSize = 50

    var isEmpty: Bool {
        !isLoading && errorMessage == nil && entries.isEmpty
    }

    func loadInitial(using apiClient: any APIClientProtocol) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await apiClient.getActivityLogEntries(
                startIndex: 0, limit: pageSize, minDate: nil
            )
            entries = result.entries
            totalCount = result.total
            hasMore = entries.count < totalCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fires when the last visible row appears — infinite-scroll trigger.
    /// Guards against re-entry and no-op when we've already loaded everything.
    func loadMoreIfNeeded(currentItem entry: ActivityLogEntry, using apiClient: any APIClientProtocol) async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        guard entries.last?.id == entry.id else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await apiClient.getActivityLogEntries(
                startIndex: entries.count, limit: pageSize, minDate: nil
            )
            entries.append(contentsOf: result.entries)
            totalCount = result.total
            hasMore = entries.count < result.total
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reload(using apiClient: any APIClientProtocol) async {
        await loadInitial(using: apiClient)
    }
}
#endif
