import Foundation
import Observation

/// Free or Pro, for the whole app. A process singleton hosted by
/// `AppNavigation` (`sharedEntitlements`) and injected through the environment.
///
/// A FOUNDATION: no StoreKit, no purchase UI, and nothing reads `state` to
/// hide a feature yet — only Settings → Debug displays it. Plain stored
/// properties + explicit mutators — no `didSet` on an `@Observable` (root RULE).
@MainActor @Observable
final class EntitlementStore {
    private(set) var state: EntitlementState = .free
    /// A purchase made on this device.
    private(set) var localRecord: CloudEntitlementRecord?
    /// The record found in the shared iCloud store — this device's own
    /// purchase once mirrored, or the other platform's.
    private(set) var cloudRecord: CloudEntitlementRecord?
    /// The « Simuler Pro » switch. Always `false` in a Release build.
    private(set) var debugOverride = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let mirror: CloudEntitlementMirror
    @ObservationIgnored private var externalChangesTask: Task<Void, Never>?

    /// `defaults` is a test seam (`UserDefaults.isolatedForTesting()`); `cloud`
    /// too (`InMemoryCloudKeyValueStore`). The app runs on `.standard` and the
    /// real iCloud key-value store.
    init(
        defaults: UserDefaults = .standard,
        cloud: any CloudKeyValueStore = UbiquitousCloudKeyValueStore()
    ) {
        self.defaults = defaults
        self.mirror = CloudEntitlementMirror(store: cloud)
        refresh()
        externalChangesTask = Task { [weak self, mirror] in
            for await _ in mirror.externalChanges() {
                guard let self else { return }
                self.refresh()
            }
        }
    }

    deinit {
        externalChangesTask?.cancel()
    }

    /// Re-reads every input and re-resolves. Launch, return to the foreground,
    /// and every change iCloud pushes in. Writes a property only when it moved,
    /// so an idle refresh re-renders nothing.
    func refresh() {
        mirror.synchronize()
        let local = defaults.data(forKey: SettingsKey.entitlementLocalRecord)
            .flatMap(CloudEntitlementRecord.decode)
        if local != localRecord { localRecord = local }
        let cloud = mirror.read()
        if cloud != cloudRecord { cloudRecord = cloud }
        #if DEBUG
        let override = defaults.bool(forKey: SettingsKey.debugSimulatePro)
        if override != debugOverride { debugOverride = override }
        #endif
        resolve()
    }

    /// Records a purchase made on this device: locally, then in the iCloud
    /// mirror so the other platform's app sees it.
    func recordPurchase(_ record: CloudEntitlementRecord) {
        guard let data = record.encoded() else { return }
        defaults.set(data, forKey: SettingsKey.entitlementLocalRecord)
        mirror.write(record)
        if localRecord != record { localRecord = record }
        if cloudRecord != record { cloudRecord = record }
        resolve()
    }

    /// Forgets this device's purchase. The iCloud mirror is left alone: it may
    /// be the other platform's record, and it is not this device's to erase.
    func clearLocal() {
        defaults.removeObject(forKey: SettingsKey.entitlementLocalRecord)
        if localRecord != nil { localRecord = nil }
        resolve()
    }

    #if DEBUG
    /// Settings → Debug → « Simuler Pro ». Persisted, DEBUG builds only.
    func setDebugOverride(_ value: Bool) {
        defaults.set(value, forKey: SettingsKey.debugSimulatePro)
        if value != debugOverride { debugOverride = value }
        resolve()
    }
    #endif

    private func resolve() {
        let resolved = EntitlementPolicy.resolve(
            localRecord: localRecord,
            cloudRecord: cloudRecord,
            debugOverride: debugOverride
        )
        if resolved != state { state = resolved }
    }
}
