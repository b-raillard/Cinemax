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

    /// Bumped by `reset()`. A `loadMore` pass snapshots this before awaiting
    /// `fetch` and, on resume, only writes state (including `isLoadingMore`)
    /// if the snapshot still matches — otherwise a `reset()` (or a newer,
    /// still-in-flight pass) fired while this pass was suspended, and its
    /// result must be discarded rather than spliced/overwritten into the
    /// current state. `reset()` itself already clears `isLoadingMore` for any
    /// abandoned pass, so a stale pass must never touch it either.
    private var generation = 0

    public init(pageSize: Int = 40) {
        self.pageSize = pageSize
    }

    /// Appends the next page. No-op if already loading or all loaded.
    public func loadMore(fetch: (Int) async throws -> (items: [T], total: Int)) async {
        guard !hasLoadedAll, !isLoadingMore else { return }
        isLoadingMore = true
        let generationAtStart = generation
        do {
            let result = try await fetch(items.count)
            guard generationAtStart == generation else { return }
            if items.isEmpty {
                items = result.items
            } else {
                items.append(contentsOf: result.items)
            }
            totalCount = result.total
            hasLoadedAll = items.count >= result.total
            isLoadingMore = false
        } catch {
            // Caller can observe isLoadingMore returning to false with no new items
            guard generationAtStart == generation else { return }
            isLoadingMore = false
        }
    }

    public func reset() {
        generation += 1
        items = []
        totalCount = 0
        isLoadingMore = false
        hasLoadedAll = false
    }
}
