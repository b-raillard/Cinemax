import Foundation
import Observation

/// Generic paginator that tracks items, offset, and hasLoadedAll state.
/// Usage: create one per paginated list, call loadMore(fetch:) with a trailing closure.
@MainActor @Observable
public final class PaginatedLoader<T: Sendable>: Sendable {
    public var items: [T] = []
    public var totalCount = 0
    public var isLoadingMore = false
    public private(set) var hasLoadedAll = false
    private let pageSize: Int

    public init(pageSize: Int = 40) {
        self.pageSize = pageSize
    }

    /// Appends the next page. No-op if already loading or all loaded.
    public func loadMore(fetch: (Int) async throws -> (items: [T], total: Int)) async {
        guard !hasLoadedAll, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await fetch(items.count)
            if items.isEmpty {
                items = result.items
            } else {
                items.append(contentsOf: result.items)
            }
            totalCount = result.total
            hasLoadedAll = items.count >= result.total
        } catch {
            // Caller can observe isLoadingMore returning to false with no new items
        }
    }

    public func reset() {
        items = []
        totalCount = 0
        isLoadingMore = false
        hasLoadedAll = false
    }
}
