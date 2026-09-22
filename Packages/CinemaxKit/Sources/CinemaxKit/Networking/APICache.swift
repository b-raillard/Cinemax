import Foundation

/// Thread-safe in-memory TTL cache for API responses.
final class APICache: @unchecked Sendable {
    private struct Entry {
        let value: Any
        let expiry: Date
    }
    private var store: [String: Entry] = [:]
    /// In-flight `Task`s keyed by cache key, held as `Any` because the value
    /// type (`Task<T, Error>`) is generic per call site. Guarded by the same
    /// `lock` as `store`. `Task` is unconditionally `Sendable`, and the class is
    /// already `@unchecked Sendable`, so no per-field annotation is needed.
    private var inFlight: [String: (id: UInt64, task: Any)] = [:]
    private var nextInFlightId: UInt64 = 0
    private let lock = NSLock()

    // MARK: Stale-write guard
    //
    // A fetch that was already on the wire when `invalidate` / `clear` ran
    // carries the PRE-mutation answer, and its `set` used to land after the
    // sweep — re-caching exactly the value the sweep existed to drop (a watched
    // toggle whose refresh then re-read the old mark for the next 10 s). So a
    // miss remembers the invalidation epoch it happened at, every sweep is
    // logged with its prefix, and `set` refuses a value whose miss predates a
    // sweep that covers its key. A `set` with no recorded miss (a test, a
    // prime) is stored as before.
    private var epoch: UInt64 = 0
    /// `(epoch, prefix)` of each recent sweep; `""` is `clear()`.
    private var sweeps: [(epoch: UInt64, prefix: String)] = []
    private var missEpoch: [String: UInt64] = [:]
    private static let sweepLogLimit = 128
    private static let missLimit = 2_000

    func get<T>(_ key: String) -> T? {
        lock.withLock {
            if let entry = store[key], entry.expiry > Date(), let value = entry.value as? T {
                return value
            }
            if missEpoch.count >= Self.missLimit { missEpoch.removeAll() }
            missEpoch[key] = epoch
            return nil
        }
    }

    /// Whether a value fetched after a miss at `missAt` would now be stale for
    /// `key`. Called under the lock.
    private func isStale(key: String, missAt: UInt64) -> Bool {
        guard missAt < epoch else { return false }
        // The log no longer reaches back to the miss: we cannot prove the value
        // is still fresh, so we do not cache it (costs one refetch, never truth).
        guard let oldest = sweeps.first, oldest.epoch <= missAt + 1 else { return true }
        return sweeps.contains { $0.epoch > missAt && key.hasPrefix($0.prefix) }
    }

    private func recordSweep(prefix: String) {
        epoch &+= 1
        sweeps.append((epoch: epoch, prefix: prefix))
        if sweeps.count > Self.sweepLogLimit { sweeps.removeFirst(sweeps.count - Self.sweepLogLimit) }
        // A fetch still on the wire for a swept key must not be JOINED by a
        // caller arriving after the sweep: drop it from the table so the next
        // `coalesce` starts fresh. The orphan finishes on its own and its `set`
        // is refused by the guard above.
        inFlight = inFlight.filter { !$0.key.hasPrefix(prefix) }
    }

    func set<T>(_ key: String, value: T, ttl: TimeInterval) {
        lock.withLock {
            // `get` filters expired entries lazily but never removes them, so
            // without this sweep the store grows unbounded over a long session
            // (every distinct cache key — and there are per-user / per-limit /
            // per-rating-age variants — lingers until the next full `clear`).
            // All TTLs are ≤10 min, so an opportunistic purge on each write
            // keeps the live set tiny. O(n) over a small dictionary.
            let now = Date()
            store = store.filter { $0.value.expiry > now }
            if let missAt = missEpoch.removeValue(forKey: key), isStale(key: key, missAt: missAt) {
                return
            }
            store[key] = Entry(value: value, expiry: now.addingTimeInterval(ttl))
        }
    }

    func invalidate(prefix: String) {
        lock.withLock {
            store = store.filter { !$0.key.hasPrefix(prefix) }
            recordSweep(prefix: prefix)
        }
    }

    func clear() {
        lock.withLock {
            store.removeAll()
            recordSweep(prefix: "")
        }
    }

    /// Single-flight coalescing: while an operation for `key` is in flight, a
    /// concurrent call joins it and awaits the *same* result instead of firing a
    /// second `operation`. The in-flight entry is registered synchronously under
    /// the lock (before any suspension) so a racing caller always observes it,
    /// and is removed the moment the operation finishes — on success AND on
    /// failure, so a thrown error never poisons later retries. Distinct from
    /// `get`/`set`: this coalesces the *fetch*, not the cached value; callers
    /// layer it under their own TTL `get`/`set`.
    ///
    /// `T: Sendable` because the shared result is delivered to every awaiting
    /// task — a genuine cross-domain send. Callers whose payload isn't Sendable
    /// (e.g. an SDK DTO) coalesce at `T == Void` and have the operation write the
    /// value into this cache, then read it back via `get` (see `getItem`).
    func coalesce<T: Sendable>(key: String, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let task: Task<T, Error> = lock.withLock {
            if let existing = inFlight[key]?.task as? Task<T, Error> {
                return existing
            }
            nextInFlightId &+= 1
            let id = nextInFlightId
            let created = Task<T, Error> {
                // Drop the in-flight entry before returning so a later call for
                // the same key starts fresh. Keyed on `id`: a sweep may already
                // have replaced this entry with a newer fetch, which must stay.
                defer { self.removeInFlight(key: key, id: id) }
                return try await operation()
            }
            inFlight[key] = (id: id, task: created as Any)
            return created
        }
        return try await task.value
    }

    private func removeInFlight(key: String, id: UInt64) {
        lock.withLock {
            if inFlight[key]?.id == id { inFlight.removeValue(forKey: key) }
        }
    }

    /// Number of entries physically retained (live or not). Test-only hook for
    /// asserting that `set` actually sweeps expired entries rather than letting
    /// the store grow — production code never reads this.
    var storedKeyCount: Int { lock.withLock { store.count } }
}
