import Foundation
import Observation

/// Generic paginator that tracks items, offset, and hasLoadedAll state.
/// Usage: create one per paginated list, call loadMore(fetch:) with a trailing closure.
@MainActor @Observable
public final class PaginatedLoader<T: Sendable>: Sendable {
    public var items: [T] = []
    public var totalCount = 0
    /// Held for the whole duration of a `loadMore` / `refreshLoadedSpan` pass,
    /// and **owned by the loader alone**: an outside writer could otherwise
    /// raise the flag with no pass behind it to lower it again, and a caller
    /// queued behind that phantom pass would wait forever (see `acquireGuard`).
    public private(set) var isLoadingMore = false
    public private(set) var hasLoadedAll = false
    private let pageSize: Int

    /// Extracts a stable identity for de-duplication, when the element type has
    /// one. `nil` (the default) keeps the historical append-everything
    /// behaviour for element types with no identity to speak of.
    @ObservationIgnored
    private let identity: (@Sendable (T) -> String?)?

    /// How many elements the SERVER has handed us — the true pagination offset,
    /// which `items.count` stops being the moment a duplicate is rejected.
    ///
    /// Keeping the two apart is what makes de-duplication safe. Paging on
    /// `items.count` after dropping *k* duplicates would re-request those same
    /// *k* elements on every later page, and `hasLoadedAll` — derived from a
    /// count that can then never reach `totalCount` — would never become true,
    /// so the last card's `.onAppear` would keep firing for ever.
    @ObservationIgnored
    private var loadedCount = 0

    /// Bumped by `reset()`. A `loadMore` pass snapshots this before awaiting
    /// `fetch` and, on resume, only writes state (including `isLoadingMore`)
    /// if the snapshot still matches — otherwise a `reset()` (or a newer,
    /// still-in-flight pass) fired while this pass was suspended, and its
    /// result must be discarded rather than spliced/overwritten into the
    /// current state. `reset()` itself already clears `isLoadingMore` for any
    /// abandoned pass, so a stale pass must never touch it either.
    private var generation = 0

    private enum PendingCall { case loadMore, spanRefresh }

    /// Callers parked behind the in-flight pass, in arrival order — at most one
    /// per kind (see `acquireGuard`). Deliberately `@ObservationIgnored`: it is
    /// pure scheduling bookkeeping, and instrumenting it would invalidate every
    /// SwiftUI view observing the loader each time a call merely queues.
    @ObservationIgnored
    private var waiters: [(kind: PendingCall, continuation: CheckedContinuation<Bool, Never>)] = []

    public init(pageSize: Int = 40, identity: (@Sendable (T) -> String?)? = nil) {
        self.pageSize = pageSize
        self.identity = identity
    }

    /// Drops incoming elements already present in `existing`.
    ///
    /// Jellyfin paginates by offset, so any change to the underlying list
    /// between two pages shifts the window: an item inserted at the head under
    /// a `dateCreated` sort makes page N+1 re-deliver the tail of page N.
    /// `ForEach(items, id: \.id)` on duplicated ids is **undefined** in SwiftUI
    /// — it renders a single view for the duplicated identity, so a card
    /// silently vanishes from the grid while the header still counts it
    /// (measured on device 2026-08-24; defect N of the adversarial campaign).
    ///
    /// An element with no identity is KEPT: it cannot be proven to be a
    /// duplicate, and dropping it would be the same silent loss in reverse.
    private func deduplicated(_ incoming: [T], against existing: [T]) -> [T] {
        guard let identity else { return incoming }
        var seen = Set(existing.compactMap(identity))
        return incoming.filter { element in
            guard let id = identity(element) else { return true }
            return seen.insert(id).inserted
        }
    }

    /// Takes the guard, **waiting for its turn** rather than giving up when a
    /// pass is already in flight.
    ///
    /// `loadMore` and `refreshLoadedSpan` share `isLoadingMore` and must not
    /// interleave their writes, but the arriving call used to be dropped in
    /// silence — no queue, no re-arming, no trace. That cost the user real
    /// state in both directions (characterised in the `Rafr L2`/`L3` adversarial
    /// scenarios, locked by `PaginatedLoaderInterlockTests`):
    ///
    /// - a second watched-toggle raised while the first refresh was in flight
    ///   was lost, leaving the item on screen in an "unwatched only" grid the
    ///   server already knew was stale — **the screen contradicting the server,
    ///   with nothing to signal it**;
    /// - a `loadMore` raised during a refresh was lost, and since it is driven
    ///   by the last card's `.onAppear` — a card that has already appeared —
    ///   **nothing ever fired it again**: pagination stayed stuck until the user
    ///   scrolled two screens back up.
    ///
    /// Returns `true` when the caller now OWNS the guard. The flag is handed
    /// over directly (never cleared in between), so no third call can slip into
    /// the gap. Returns `false` when the caller must give up without writing:
    /// either an identical call is already queued — they ask for the same work,
    /// so they coalesce — or `reset()` fired while this one was parked, meaning
    /// its request describes a list that no longer exists.
    ///
    /// Parking is bounded by the in-flight pass itself, which always ends in
    /// `handOverOrRelease()` (or in `reset()` draining the queue) — hence
    /// `isLoadingMore` being `private(set)`: an outside writer could raise the
    /// flag with no pass behind it and strand every later caller. A parked
    /// caller does not observe `Task` cancellation; it resumes when its turn
    /// comes, and its own `fetch` is where cancellation surfaces.
    private func acquireGuard(_ kind: PendingCall) async -> Bool {
        guard isLoadingMore else {
            isLoadingMore = true
            return true
        }
        guard !waiters.contains(where: { $0.kind == kind }) else { return false }
        return await withCheckedContinuation { continuation in
            waiters.append((kind, continuation))
        }
    }

    /// Hands the guard to the first waiter, or releases it when none is queued.
    private func handOverOrRelease() {
        guard !waiters.isEmpty else {
            isLoadingMore = false
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    /// Appends the next page. No-op if all loaded; queued behind any pass
    /// already in flight.
    public func loadMore(fetch: (Int) async throws -> (items: [T], total: Int)) async {
        guard !hasLoadedAll else { return }
        guard await acquireGuard(.loadMore) else { return }
        // Re-read after the wait: the pass we queued behind may have loaded the
        // tail of the list while we were parked.
        guard !hasLoadedAll else { handOverOrRelease(); return }
        let generationAtStart = generation
        do {
            let result = try await fetch(loadedCount)
            guard generationAtStart == generation else { return }
            let fresh = deduplicated(result.items, against: items)
            if items.isEmpty {
                items = fresh
            } else {
                items.append(contentsOf: fresh)
            }
            // Count what the SERVER sent, not what we retained — see `loadedCount`.
            loadedCount += result.items.count
            totalCount = result.total
            // An empty page is the end of the list whatever the reported total
            // says: without this, a server over-reporting `totalRecordCount`
            // leaves the last card asking for more for ever.
            hasLoadedAll = loadedCount >= result.total || result.items.isEmpty
            handOverOrRelease()
        } catch {
            // Caller can observe isLoadingMore returning to false with no new items
            guard generationAtStart == generation else { return }
            handOverOrRelease()
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
    /// load). While another pass is in flight it queues behind it rather than
    /// giving up — see `acquireGuard` — and reads the span **after** its turn
    /// comes, so a page that landed in the meantime is covered too.
    public func refreshLoadedSpan(
        fetch: (_ startIndex: Int, _ limit: Int) async throws -> (items: [T], total: Int)
    ) async {
        guard !items.isEmpty else { return }
        guard await acquireGuard(.spanRefresh) else { return }
        guard !items.isEmpty else { handOverOrRelease(); return }
        let generationAtStart = generation
        // The span the SERVER knows about, which is what index 0 has to cover —
        // it exceeds `items.count` by exactly the duplicates already rejected.
        let span = max(loadedCount, items.count)
        do {
            let result = try await fetch(0, span)
            guard generationAtStart == generation else { return }
            // Replaces rather than appends, so nothing is already on screen to
            // compare against — but the page itself can carry duplicates.
            items = deduplicated(result.items, against: [])
            loadedCount = result.items.count
            totalCount = result.total
            hasLoadedAll = loadedCount >= result.total || result.items.isEmpty
            handOverOrRelease()
        } catch {
            guard generationAtStart == generation else { return }
            handOverOrRelease()
        }
    }

    public func reset() {
        generation += 1
        items = []
        loadedCount = 0
        totalCount = 0
        isLoadingMore = false
        hasLoadedAll = false
        // Every parked caller described the list we just threw away: wake them
        // so they return without writing, rather than replaying onto a list that
        // no longer exists — or worse, never returning at all.
        let parked = waiters
        waiters = []
        for waiter in parked { waiter.continuation.resume(returning: false) }
    }
}
