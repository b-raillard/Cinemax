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
    /// Settings → Debug « Palier simulé » (free / Pro / founder), read by
    /// `proTier(earlyAdopter:)`. Always `.automatic` in a Release build.
    private(set) var proTierOverride: ProTierOverride = .automatic

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
        let cloud = Self.trusted(mirror.read())
        if cloud != cloudRecord { cloudRecord = cloud }
        #if DEBUG
        let override = defaults.bool(forKey: SettingsKey.debugSimulatePro)
        if override != debugOverride { debugOverride = override }
        #endif
        #if DEBUG || PRO_PREVIEW
        let tier = defaults.string(forKey: SettingsKey.debugProTier).flatMap(ProTierOverride.init(rawValue:)) ?? .automatic
        if tier != proTierOverride { proTierOverride = tier }
        #endif
        resolve()
    }

    /// Records a purchase made on this device: locally, then in the iCloud
    /// mirror so the other platform's app sees it.
    /// `mirror: false` for a TEST purchase (sandbox, TestFlight, Xcode): it
    /// unlocks this device only, never the user's real other platform.
    func recordPurchase(_ record: CloudEntitlementRecord, mirror writesMirror: Bool = true) {
        guard let data = record.encoded() else { return }
        defaults.set(data, forKey: SettingsKey.entitlementLocalRecord)
        if localRecord != record { localRecord = record }
        if writesMirror {
            mirror.write(record)
            if cloudRecord != record { cloudRecord = record }
        }
        resolve()
    }

    /// The iCloud record this build trusts: a test purchase found there (an
    /// older build, or a tester's) unlocks nothing — the key-value store has
    /// no test / production split.
    private static func trusted(_ record: CloudEntitlementRecord?) -> CloudEntitlementRecord? {
        guard let record, record.isProduction else { return nil }
        return record
    }

    /// Forgets this device's purchase. The iCloud mirror is left alone: it may
    /// be the other platform's record, and it is not this device's to erase.
    func clearLocal() {
        defaults.removeObject(forKey: SettingsKey.entitlementLocalRecord)
        if localRecord != nil { localRecord = nil }
        resolve()
    }

    /// StoreKit no longer grants this app the Pro (refund, family-sharing
    /// exit — `ProPurchasePolicy`): the local record goes, and so does the
    /// iCloud mirror when THIS app wrote it, otherwise the other platform
    /// would stay Pro for ever on a refunded purchase. The other platform's
    /// record is never touched (it may be a purchase of its own) — the key is
    /// re-read right before deciding, since the other platform may have
    /// rewritten it after the last external-change notice was handled.
    func revokeOwnPurchase(ownBundleID: String) {
        defaults.removeObject(forKey: SettingsKey.entitlementLocalRecord)
        if localRecord != nil { localRecord = nil }
        mirror.synchronize()
        let current = mirror.read()
        if current?.writerBundleID == ownBundleID {
            mirror.remove()
            if cloudRecord != nil { cloudRecord = nil }
        } else {
            let trusted = Self.trusted(current)
            if trusted != cloudRecord { cloudRecord = trusted }
        }
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

    #if DEBUG || PRO_PREVIEW
    /// Settings → Debug → « Palier simulé ». Persisted, DEBUG and preview
    /// builds only (a preview is never submitted — `ProFeatureGate`).
    func setProTierOverride(_ value: ProTierOverride) {
        defaults.set(value.rawValue, forKey: SettingsKey.debugProTier)
        if value != proTierOverride { proTierOverride = value }
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
