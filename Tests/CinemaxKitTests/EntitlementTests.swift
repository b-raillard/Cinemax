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

    /// Lot B (spec 2026-10-22): every gate site asks `allows(_:tier:)`. Before
    /// the Pro launches nobody may lose anything — whatever the purchase and
    /// the founder facts, EVERY feature stays open.
    @Test("Avant le lancement, chaque fonction Pro reste ouverte, quels que soient achat et fondateur", arguments: [
        (false, false), (true, false), (false, true), (true, true),
    ])
    func everyFeatureOpenBeforeLaunch(isPro: Bool, isEarlyAdopter: Bool) {
        let tier = ProFeatureGate.tier(proLaunched: false, isPro: isPro, isEarlyAdopter: isEarlyAdopter, override: .automatic)
        for feature in ProFeatureID.allCases {
            #expect(ProFeatureGate.allows(feature, tier: tier), "\(feature)")
        }
    }

    @Test("Après le lancement : le gratuit est refusé, le Pro et le fondateur passent, pour chaque fonction")
    func everyFeatureAfterLaunch() {
        for feature in ProFeatureID.allCases {
            #expect(!ProFeatureGate.allows(feature, tier: .free), "\(feature)")
            #expect(ProFeatureGate.allows(feature, tier: .pro), "\(feature)")
            #expect(ProFeatureGate.allows(feature, tier: .founder), "\(feature)")
        }
    }

    /// The default icon is never paid; an alternate one is the Pro's. A tier
    /// that drops never takes an icon back (`setAlternateIconName` raises a
    /// system alert — the picker locks, it does not revert).
    @Test("Icônes : celle par défaut toujours permise, une autre seulement en Pro ou fondateur")
    func appIconChoice() {
        for tier in [ProTier.free, .pro, .founder] {
            #expect(ProFeatureGate.mayChooseAppIcon(alternateName: nil, tier: tier))
        }
        #expect(!ProFeatureGate.mayChooseAppIcon(alternateName: "AppIconRose", tier: .free))
        #expect(ProFeatureGate.mayChooseAppIcon(alternateName: "AppIconRose", tier: .pro))
        #expect(ProFeatureGate.mayChooseAppIcon(alternateName: "AppIconRose", tier: .founder))
        #expect(!ProFeatureGate.revertsAppIconWhenTierDrops)
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

// MARK: - Pro feature access (the gate sites' one entry point)

@MainActor
@Suite("Accès aux fonctions Pro")
struct ProFeatureAccessTests {

    private func access(launched: Bool, isPro: Bool = false, isEarlyAdopter: Bool = false) -> ProFeatureAccess {
        ProFeatureAccess {
            ProFeatureGate.tier(proLaunched: launched, isPro: isPro, isEarlyAdopter: isEarlyAdopter, override: .automatic)
        }
    }

    @Test("Avant le lancement, tout est admis et aucune feuille Pro ne s'ouvre")
    func beforeLaunchAdmitsEverything() {
        let gate = access(launched: false)
        for feature in ProFeatureID.allCases {
            #expect(gate.admit(feature))
        }
        #expect(gate.upsell == nil)
    }

    @Test("Gratuit après le lancement : refusé, et la feuille de CETTE fonction s'ouvre")
    func freeRaisesTheSheet() {
        let gate = access(launched: true)
        #expect(!gate.admit(.administration))
        #expect(gate.upsell == .administration)
        #expect(!gate.allows(.playOn))
        #expect(gate.upsell == .administration, "allows() only asks, it never opens a sheet")
    }

    @Test("Pro et fondateur après le lancement : admis, sans feuille")
    func paidAndFoundersPass() {
        for gate in [access(launched: true, isPro: true), access(launched: true, isEarlyAdopter: true)] {
            #expect(gate.admit(.playOn))
            #expect(gate.upsell == nil)
        }
    }

    /// « Lire sur… » has three senders (the iOS fiche chip, the tvOS fiche
    /// button, the card menu) and ONE gate: the root presenter they all go
    /// through.
    @Test("« Lire sur… » : refusé en gratuit → feuille Pro, pas de sélecteur ; permis → sélecteur")
    func remotePlayGoesThroughTheGate() {
        let intent = RemotePlayIntent(itemId: "a", title: "A", startPositionTicks: nil, mediaSourceId: nil)

        let free = access(launched: true)
        let refused = CardActionPresenter(access: free)
        refused.present(remotePlay: intent)
        #expect(refused.remotePlay == nil)
        #expect(free.upsell == .playOn)

        let open = access(launched: false)
        let allowed = CardActionPresenter(access: open)
        allowed.present(remotePlay: intent)
        #expect(allowed.remotePlay == intent)
        #expect(open.upsell == nil)
    }

    #if os(iOS)
    /// User decision 2026-10-22: the admin's per-item menu (fiche pill,
    /// poster corner) stays VISIBLE to a free admin, locked — it shows the
    /// feature exists; its tap raises the Pro sheet instead of the menu.
    @Test("Menu Admin d'une fiche : caché hors admin, cadenas pour l'admin gratuit, ouvert sinon")
    func adminShortcutIsLockedNotHidden() {
        #expect(AdminShortcutPresence.resolve(isAdmin: false, allowsAdministration: true) == .hidden)
        #expect(AdminShortcutPresence.resolve(isAdmin: false, allowsAdministration: false) == .hidden)
        #expect(AdminShortcutPresence.resolve(isAdmin: true, allowsAdministration: false) == .locked)
        #expect(AdminShortcutPresence.resolve(isAdmin: true, allowsAdministration: true) == .open)

        let free = access(launched: true)
        #expect(AdminShortcutPresence.resolve(isAdmin: true, access: free) == .locked)
        #expect(free.upsell == nil, "drawing the lock never opens the sheet")
        #expect(AdminShortcutPresence.resolve(isAdmin: true, access: access(launched: false)) == .open)
        #expect(AdminShortcutPresence.resolve(isAdmin: true, access: nil) == .open)
    }
    #endif

    @Test("Lire une vidéo depuis une carte ne passe JAMAIS par la porte Pro")
    func playbackIsNeverGated() {
        let free = access(launched: true)
        let presenter = CardActionPresenter(access: free)
        presenter.present(playback: CardPlaybackRequest(
            itemId: "a", title: "A", startTime: nil,
            previousEpisode: nil, nextEpisode: nil, episodeNavigator: nil
        ))
        #expect(presenter.playback != nil)
        #expect(free.upsell == nil)
    }
}
