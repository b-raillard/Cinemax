import Foundation

/// Thread-safe in-memory TTL cache for API responses.
final class APICache: @unchecked Sendable {
    private struct Entry {
        let value: Any
        let expiry: Date
    }
    private var store: [String: Entry] = [:]
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

    /// Number of entries physically retained (live or not). Test-only hook for
    /// asserting that `set` actually sweeps expired entries rather than letting
    /// the store grow — production code never reads this.
    var storedKeyCount: Int { lock.withLock { store.count } }
}
