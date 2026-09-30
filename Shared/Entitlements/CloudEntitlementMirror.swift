import Foundation

/// Reads and writes the ONE entitlement record kept in the shared iCloud
/// key-value store, under `CloudEntitlementMirror.key`.
///
/// A convenience across platforms, never the source of truth on the platform
/// the purchase was made on (that will be StoreKit — see `CLAUDE.md` here).
@MainActor
final class CloudEntitlementMirror {
    /// Versioned in the KEY as well as in the record: a future format that
    /// cannot stay backward-readable moves to `…v2` and leaves this one for
    /// the builds still reading it.
    static let key = "entitlement.pro.v1"

    private let store: any CloudKeyValueStore

    init(store: any CloudKeyValueStore) {
        self.store = store
    }

    /// `nil` when absent or unreadable by this build (`CloudEntitlementRecord.decode`).
    func read() -> CloudEntitlementRecord? {
        store.data(forKey: Self.key).flatMap(CloudEntitlementRecord.decode)
    }

    func write(_ record: CloudEntitlementRecord) {
        guard let data = record.encoded() else { return }
        store.set(data, forKey: Self.key)
        store.synchronize()
    }

    /// Called at launch (`EntitlementStore.init`) and on every return to the
    /// foreground (`EntitlementStore.refresh()`, from `AppNavigation`).
    @discardableResult
    func synchronize() -> Bool {
        store.synchronize()
    }

    func externalChanges() -> AsyncStream<Void> {
        store.externalChanges()
    }
}
