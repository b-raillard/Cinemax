import Foundation

/// The slice of `NSUbiquitousKeyValueStore` the entitlement mirror uses —
/// injectable so tests run on an in-memory store (`InMemoryCloudKeyValueStore`,
/// test sources) and never touch the real iCloud account.
@MainActor
protocol CloudKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    /// `nil` removes the key.
    func set(_ data: Data?, forKey key: String)
    /// Asks the store to exchange with iCloud. `false` = the store is not
    /// available (no iCloud account, missing entitlement) — never fatal.
    @discardableResult
    func synchronize() -> Bool
    /// One element per change pushed FROM iCloud (the other device wrote, the
    /// account changed). A fresh stream per call; it ends when its consumer
    /// is cancelled.
    func externalChanges() -> AsyncStream<Void>
}

/// The real store: `NSUbiquitousKeyValueStore.default`, i.e. the container
/// named by the `com.apple.developer.ubiquity-kvstore-identifier` entitlement —
/// `$(TeamIdentifierPrefix)com.cinemax.shared` in BOTH apps, which is what makes
/// it one store shared by the iOS and tvOS apps (RULE in `CLAUDE.md` here).
@MainActor
final class UbiquitousCloudKeyValueStore: CloudKeyValueStore {
    private let store = NSUbiquitousKeyValueStore.default

    func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        if let data {
            store.set(data, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    @discardableResult
    func synchronize() -> Bool {
        store.synchronize()
    }

    func externalChanges() -> AsyncStream<Void> {
        let name = NSUbiquitousKeyValueStore.didChangeExternallyNotification
        return AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: name) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
