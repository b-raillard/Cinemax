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
            store[key] = Entry(value: value, expiry: Date().addingTimeInterval(ttl))
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
}
