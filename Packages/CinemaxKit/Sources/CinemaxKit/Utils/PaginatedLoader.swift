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

    /// Re-pulls everything the user has already paged in — as ONE request of
    /// `items.count` — and replaces the list in place.
    ///
    /// Distinct from `reset()` + a page-0 `loadMore`, which is what a
    /// notification-driven reload used to do: that collapsed a grid the user had
    /// scrolled deep into back to a single page, **visibly jumping to the top
    /// under their finger**. It became a live regression once the cards in these
    /// grids gained a context menu whose own watched/favorite toggles raise
    /// those very notifications — the reload now fires while the user is looking
    /// at the list, not only after they navigate away and back.
    ///
    /// Item identity is preserved for everything still present, so scroll
    /// position and per-card `@State` survive. `hasLoadedAll` is re-derived from
    /// the fresh total, so a set that shrank (an un-favorited item) correctly
    /// stops asking for more.
    ///
    /// No-op when nothing has been paged in yet (the caller should do a normal
    /// load) or while a `loadMore` is in flight — same discipline as `loadMore`
    /// itself, and it keeps the two from interleaving writes.
    public func refreshLoadedSpan(
        fetch: (_ startIndex: Int, _ limit: Int) async throws -> (items: [T], total: Int)
    ) async {
        guard !items.isEmpty, !isLoadingMore else { return }
        isLoadingMore = true
        let generationAtStart = generation
        let span = items.count
        do {
            let result = try await fetch(0, span)
            guard generationAtStart == generation else { return }
            items = result.items
            totalCount = result.total
            hasLoadedAll = items.count >= result.total
            isLoadingMore = false
        } catch {
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
