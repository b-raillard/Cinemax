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
    private var inFlight: [String: Any] = [:]
    private let lock = NSLock()

    func get<T>(_ key: String) -> T? {
        lock.withLock {
            guard let entry = store[key], entry.expiry > Date() else { return nil }
            return entry.value as? T
        }
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
            store[key] = Entry(value: value, expiry: now.addingTimeInterval(ttl))
        }
    }

    func invalidate(prefix: String) {
        lock.withLock {
            store = store.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    func clear() {
        lock.withLock { store.removeAll() }
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
            if let existing = inFlight[key] as? Task<T, Error> {
                return existing
            }
            let created = Task<T, Error> {
                // Drop the in-flight entry before returning so a later call for
                // the same key starts fresh. No caller can create a competing
                // task in the meantime: `key` stays occupied until this runs.
                defer { self.removeInFlight(key: key) }
                return try await operation()
            }
            inFlight[key] = created
            return created
        }
        return try await task.value
    }

    private func removeInFlight(key: String) {
        lock.withLock { _ = inFlight.removeValue(forKey: key) }
    }

    /// Number of entries physically retained (live or not). Test-only hook for
    /// asserting that `set` actually sweeps expired entries rather than letting
    /// the store grow — production code never reads this.
    var storedKeyCount: Int { lock.withLock { store.count } }
}
