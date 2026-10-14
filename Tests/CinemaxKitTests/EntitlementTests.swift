import Foundation
import Testing
@testable import Cinemax

private func record(
    writer: String = "com.cinemax.ios",
    transaction: String = "2000000123456789"
) -> CloudEntitlementRecord {
    CloudEntitlementRecord(
        productID: "com.cinemax.pro",
        originalTransactionID: transaction,
        // A fractional date: the round trip must keep it exactly.
        purchaseDate: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456),
        signedTransaction: "eyJhbGciOiJFUzI1NiJ9.payload.signature",
        writerBundleID: writer
    )
}

@Suite("Entitlement policy")
struct EntitlementPolicyTests {
    @Test("A purchase recorded on this device is Pro by purchase, whatever else is present")
    func localRecordWins() {
        let state = EntitlementPolicy.resolve(localRecord: record(), cloudRecord: record(writer: "com.cinemax.tvos"), debugOverride: true)
        #expect(state == .pro(.purchase))
        #expect(state.isPro)
    }

    @Test("Without a local purchase, the iCloud mirror is Pro by mirror")
    func cloudRecordMirrors() {
        let state = EntitlementPolicy.resolve(localRecord: nil, cloudRecord: record(writer: "com.cinemax.tvos"), debugOverride: true)
        #expect(state == .pro(.cloudMirror))
    }

    /// The only test whose expectation depends on the build configuration:
    /// the Debug branch runs in every `xcodebuild test` (tests build Debug);
    /// the Release branch documents — and would lock, in a Release test
    /// build — that the stored override is ignored there.
    @Test("« Simuler Pro » is Pro in a DEBUG build only")
    func debugOverrideOnlyInDebug() {
        let state = EntitlementPolicy.resolve(localRecord: nil, cloudRecord: nil, debugOverride: true)
        #if DEBUG
        #expect(state == .pro(.debugOverride))
        #else
        #expect(state == .free)
        #endif
    }

    @Test("Nothing at all is Free")
    func nothingIsFree() {
        let state = EntitlementPolicy.resolve(localRecord: nil, cloudRecord: nil, debugOverride: false)
        #expect(state == .free)
        #expect(!state.isPro)
        #expect(state.source == nil)
    }
}

@Suite("Entitlement record + iCloud mirror")
@MainActor
struct CloudEntitlementMirrorTests {
    @Test("A record written to the mirror reads back identical")
    func mirrorRoundTrip() {
        let store = InMemoryCloudKeyValueStore()
        let mirror = CloudEntitlementMirror(store: store)
        #expect(mirror.read() == nil)
        mirror.write(record())
        #expect(store.values[CloudEntitlementMirror.key] != nil)
        #expect(mirror.read() == record())
    }

    @Test("A record of an unknown version is ignored, not trapped on")
    func unknownVersionIsIgnored() throws {
        let future = CloudEntitlementRecord(
            version: 2, productID: "com.cinemax.pro", originalTransactionID: "1",
            purchaseDate: .now, writerBundleID: "com.cinemax.tvos"
        )
        let data = try #require(future.encoded())
        #expect(CloudEntitlementRecord.decode(data) == nil)

        // A newer shape that dropped a field this build requires: same answer.
        let reshaped = Data(#"{"version":3,"grant":"lifetime"}"#.utf8)
        #expect(CloudEntitlementRecord.decode(reshaped) == nil)
        // Not a record at all.
        #expect(CloudEntitlementRecord.decode(Data("garbage".utf8)) == nil)

        let store = InMemoryCloudKeyValueStore()
        store.set(data, forKey: CloudEntitlementMirror.key)
        #expect(CloudEntitlementMirror(store: store).read() == nil)
    }

    @Test("A version-1 record without a signed transaction decodes")
    func optionalJWS() throws {
        let data = Data(#"""
        {"version":1,"productID":"com.cinemax.pro","originalTransactionID":"42",
         "purchaseDate":812345678,"writerBundleID":"com.cinemax.ios"}
        """#.utf8)
        let decoded = try #require(CloudEntitlementRecord.decode(data))
        #expect(decoded.signedTransaction == nil)
        #expect(decoded.originalTransactionID == "42")
    }
}

@Suite("Entitlement store")
@MainActor
struct EntitlementStoreTests {
    @Test("Starts Free with nothing stored, and synchronizes iCloud at launch")
    func startsFree() {
        let cloud = InMemoryCloudKeyValueStore()
        let store = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud)
        #expect(store.state == .free)
        #expect(cloud.synchronizeCount >= 1)
    }

    @Test("recordPurchase writes the local record AND the iCloud mirror")
    func recordPurchaseWritesBoth() throws {
        let defaults = UserDefaults.isolatedForTesting()
        let cloud = InMemoryCloudKeyValueStore()
        let store = EntitlementStore(defaults: defaults, cloud: cloud)

        store.recordPurchase(record())

        #expect(store.state == .pro(.purchase))
        let local = try #require(defaults.data(forKey: SettingsKey.entitlementLocalRecord))
        #expect(CloudEntitlementRecord.decode(local) == record())
        #expect(CloudEntitlementMirror(store: cloud).read() == record())

        // A relaunch on the same device reads it back.
        let relaunched = EntitlementStore(defaults: defaults, cloud: cloud)
        #expect(relaunched.state == .pro(.purchase))
    }

    @Test("A change pushed from the other device updates the state")
    func externalChangeUpdatesState() async throws {
        let cloud = InMemoryCloudKeyValueStore()
        let store = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud)
        #expect(store.state == .free)
        #expect(await eventually { cloud.hasListeners })

        let data = try #require(record(writer: "com.cinemax.tvos").encoded())
        cloud.simulateExternalChange(data, forKey: CloudEntitlementMirror.key)

        #expect(await eventually { store.state == .pro(.cloudMirror) })
        #expect(store.state == .pro(.cloudMirror))
    }

    @Test("clearLocal forgets this device's purchase but leaves the mirror")
    func clearLocalKeepsMirror() {
        let cloud = InMemoryCloudKeyValueStore()
        let store = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud)
        store.recordPurchase(record())
        store.clearLocal()
        #expect(store.localRecord == nil)
        #expect(store.state == .pro(.cloudMirror))
    }

    #if DEBUG
    @Test("« Simuler Pro » persists through the defaults seam")
    func debugOverridePersists() {
        let defaults = UserDefaults.isolatedForTesting()
        let store = EntitlementStore(defaults: defaults, cloud: InMemoryCloudKeyValueStore())
        store.setDebugOverride(true)
        #expect(store.state == .pro(.debugOverride))
        #expect(defaults.bool(forKey: SettingsKey.debugSimulatePro))
        #expect(EntitlementStore(defaults: defaults, cloud: InMemoryCloudKeyValueStore()).state == .pro(.debugOverride))
        store.setDebugOverride(false)
        #expect(store.state == .free)
    }
    #endif
}

// MARK: - Pro feature gate

@Suite("Porte des fonctions Pro")
struct ProFeatureGateTests {

    @Test("Avant le lancement de Pro, tout le monde passe (fondateur)", arguments: [
        (false, false), (true, false), (false, true), (true, true),
    ])
    func beforeLaunch(isPro: Bool, isEarlyAdopter: Bool) {
        let tier = ProFeatureGate.tier(proLaunched: false, isPro: isPro, isEarlyAdopter: isEarlyAdopter, override: .automatic)
        #expect(tier != .free)
        #expect(tier == (isPro ? .pro : .founder))
    }

    @Test("Après le lancement : Pro acheté, fondateur, sinon gratuit")
    func afterLaunch() {
        #expect(ProFeatureGate.tier(proLaunched: true, isPro: true, isEarlyAdopter: false, override: .automatic) == .pro)
        #expect(ProFeatureGate.tier(proLaunched: true, isPro: false, isEarlyAdopter: true, override: .automatic) == .founder)
        #expect(ProFeatureGate.tier(proLaunched: true, isPro: false, isEarlyAdopter: false, override: .automatic) == .free)
    }

    @Test("Le choix Debug l'emporte sur tout")
    func override() {
        for launched in [false, true] {
            #expect(ProFeatureGate.tier(proLaunched: launched, isPro: true, isEarlyAdopter: true, override: .free) == .free)
            #expect(ProFeatureGate.tier(proLaunched: launched, isPro: false, isEarlyAdopter: false, override: .pro) == .pro)
            #expect(ProFeatureGate.tier(proLaunched: launched, isPro: false, isEarlyAdopter: false, override: .founder) == .founder)
        }
    }

    #if PRO_PREVIEW
    @Test("Une build aperçu se comporte comme si le Pro était lancé, sans fondateurs")
    func previewBuildIsLaunched() {
        #expect(ProFeatureGate.proLaunched)
        #expect(ProFeatureGate.recognisesFounders == false)
    }
    #else
    @Test("Le Pro n'est pas lancé dans cette version ; les fondateurs sont reconnus")
    func notLaunchedYet() {
        #expect(ProFeatureGate.proLaunched == false)
        #expect(ProFeatureGate.recognisesFounders)
    }
    #endif

    @Test("« Lancé » ouvre le vrai parcours : gratuit, puis Pro une fois acheté, fondateur reconnu")
    func launchedOverride() {
        #expect(ProFeatureGate.tier(proLaunched: false, isPro: false, isEarlyAdopter: false, override: .launched) == .free)
        #expect(ProFeatureGate.tier(proLaunched: false, isPro: true, isEarlyAdopter: false, override: .launched) == .pro)
        #expect(ProFeatureGate.tier(proLaunched: false, isPro: false, isEarlyAdopter: true, override: .launched) == .founder)
    }

    @Test("Le choix Debug parcourt automatique → lancé → gratuit → Pro → fondateur → automatique")
    func overrideCycle() {
        #expect(ProTierOverride.automatic.next == .launched)
        #expect(ProTierOverride.launched.next == .free)
        #expect(ProTierOverride.free.next == .pro)
        #expect(ProTierOverride.pro.next == .founder)
        #expect(ProTierOverride.founder.next == .automatic)
    }

    #if DEBUG
    @MainActor
    @Test("Le choix Debug est persistant et observable")
    func storeOverride() {
        let defaults = UserDefaults.isolatedForTesting()
        let store = EntitlementStore(defaults: defaults, cloud: InMemoryCloudKeyValueStore())
        #expect(store.proTierOverride == .automatic)
        store.setProTierOverride(.free)
        #expect(store.proTierOverride == .free)
        let reopened = EntitlementStore(defaults: defaults, cloud: InMemoryCloudKeyValueStore())
        #expect(reopened.proTierOverride == .free)
    }
    #endif
}
