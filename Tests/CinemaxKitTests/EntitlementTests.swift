import CryptoKit
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
        let store = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud, vouches: { _ in true })
        #expect(store.state == .free)
        #expect(await eventually { cloud.hasListeners })

        let data = try #require(record(writer: "com.cinemax.tvos").encoded())
        cloud.simulateExternalChange(data, forKey: CloudEntitlementMirror.key)

        #expect(await eventually { store.state == .pro(.cloudMirror) })
        #expect(store.state == .pro(.cloudMirror))
    }

    @Test("Un achat miroité sans signature App Store valide ne débloque rien (audit SEC-02)")
    func unsignedMirrorIsIgnored() {
        let cloud = InMemoryCloudKeyValueStore()
        CloudEntitlementMirror(store: cloud).write(record(writer: "com.cinemax.tvos"))
        let store = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud)
        #expect(store.cloudRecord == nil)
        #expect(store.state == .free)
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

// MARK: - App Store signature (audit SEC-02)

@Suite("Signature App Store des miroirs iCloud")
@MainActor
struct AppStoreSignatureTests {
    private let testRoot = AppStoreSignature(anchor: Data(base64Encoded: JWSFixture.root) ?? Data())

    private func purchasePayload(_ jws: String, _ signature: AppStoreSignature) -> SignedPurchasePayload? {
        signature.payload(of: jws).flatMap { try? JSONDecoder().decode(SignedPurchasePayload.self, from: $0) }
    }

    private func mirrored(
        product: String = ProProduct.tvOSProductID,
        transaction: String = "2000000111",
        writer: String = "com.cinemax.tvos",
        jws: String? = JWSFixture.purchase
    ) -> CloudEntitlementRecord {
        CloudEntitlementRecord(
            productID: product, originalTransactionID: transaction,
            purchaseDate: Date(timeIntervalSince1970: 1_593_500_000),
            signedTransaction: jws, writerBundleID: writer, environment: "production"
        )
    }

    @Test("La racine épinglée est bien Apple Root CA - G3")
    func pinnedRootIsAppleRootG3() {
        let digest = SHA256.hash(data: AppStoreSignature.appleRootCAG3).map { String(format: "%02X", $0) }.joined()
        #expect(digest == "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179")
    }

    @Test("Un JWS signé par la chaîne se vérifie — à SA date de signature, la feuille ayant expiré depuis")
    func genuineJWSVerifies() {
        let payload = purchasePayload(JWSFixture.purchase, testRoot)
        #expect(payload == SignedPurchasePayload(
            bundleId: "com.cinemax.tvos", productId: ProProduct.tvOSProductID,
            originalTransactionId: "2000000111", environment: "Production", revocationDate: nil
        ))
    }

    @Test("Refusés : autre racine, charge modifiée, feuille sans marqueur, signé après l'expiration, n'importe quoi")
    func forgeriesAreRefused() throws {
        // The production anchor: Apple's root did not sign the test chain.
        #expect(AppStoreSignature.appStore.payload(of: JWSFixture.purchase) == nil)
        // A payload swapped under a genuine signature.
        var parts = JWSFixture.purchase.split(separator: ".").map(String.init)
        let forged = Data(#"{"bundleId":"com.cinemax.tvos","productId":"com.cinemax.tvos.pro","originalTransactionId":"666","environment":"Production","signedDate":1593561600000}"#.utf8)
        parts[1] = forged.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(testRoot.payload(of: parts.joined(separator: ".")) == nil)
        // A certificate of the same root without the App Store marker.
        #expect(testRoot.payload(of: JWSFixture.noMarker) == nil)
        // Evaluated at the signed date: the leaf had expired by 2022.
        #expect(testRoot.payload(of: JWSFixture.signedAfterLeafExpiry) == nil)
        // An app transaction is dated by its `receiptCreationDate` (no `signedDate`).
        #expect(testRoot.payload(of: JWSFixture.appTransaction) != nil)
        #expect(testRoot.payload(of: JWSFixture.appTransactionAfterLeafExpiry) == nil)
        #expect(testRoot.payload(of: "eyJhbGciOiJFUzI1NiJ9.payload.signature") == nil)
        #expect(testRoot.payload(of: "") == nil)
    }

    @Test("Un achat miroité n'est cru que si la charge signée garantit chaque champ qui débloque")
    func vouchingNeedsEveryGrantingField() {
        let genuine = SignedPurchasePayload(
            bundleId: "com.cinemax.tvos", productId: ProProduct.tvOSProductID,
            originalTransactionId: "2000000111", environment: "Production", revocationDate: nil
        )
        #expect(AppStoreSignature.vouches(for: mirrored(), payload: genuine))
        #expect(!AppStoreSignature.vouches(for: mirrored(), payload: nil))
        // Test purchase, refunded purchase.
        #expect(!AppStoreSignature.vouches(for: mirrored(), payload: SignedPurchasePayload(
            bundleId: "com.cinemax.tvos", productId: ProProduct.tvOSProductID,
            originalTransactionId: "2000000111", environment: "Sandbox", revocationDate: nil)))
        #expect(!AppStoreSignature.vouches(for: mirrored(), payload: SignedPurchasePayload(
            bundleId: "com.cinemax.tvos", productId: ProProduct.tvOSProductID,
            originalTransactionId: "2000000111", environment: "Production", revocationDate: 1_600_000_000_000)))
        // A genuine purchase of ANOTHER app, or of a product its app does not sell.
        let elsewhere = SignedPurchasePayload(
            bundleId: "com.example.other", productId: "com.example.other.pro",
            originalTransactionId: "2000000111", environment: "Production", revocationDate: nil)
        #expect(!AppStoreSignature.vouches(for: mirrored(product: "com.example.other.pro", writer: "com.example.other"), payload: elsewhere))
        #expect(!AppStoreSignature.vouches(for: mirrored(product: ProProduct.iOSProductID), payload: SignedPurchasePayload(
            bundleId: "com.cinemax.tvos", productId: ProProduct.iOSProductID,
            originalTransactionId: "2000000111", environment: "Production", revocationDate: nil)))
        // Record fields edited around a genuine JWS.
        #expect(!AppStoreSignature.vouches(for: mirrored(transaction: "666"), payload: genuine))
        #expect(!AppStoreSignature.vouches(for: mirrored(writer: "com.cinemax.ios"), payload: genuine))
        #expect(!AppStoreSignature.vouches(for: mirrored(product: ProProduct.iOSProductID), payload: genuine))
    }

    @Test("Le magasin croit l'achat de l'autre plateforme signé par la chaîne, pas le même record sans signature")
    func storeTrustsOnlyASignedMirror() {
        let cloud = InMemoryCloudKeyValueStore()
        let signature = testRoot
        CloudEntitlementMirror(store: cloud).write(mirrored())
        let store = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud, vouches: { signature.vouchesForPurchase($0) })
        #expect(store.state == .pro(.cloudMirror))

        CloudEntitlementMirror(store: cloud).write(mirrored(jws: nil))
        store.refresh()
        #expect(store.state == .free)
        CloudEntitlementMirror(store: cloud).write(mirrored(jws: JWSFixture.noMarker))
        store.refresh()
        #expect(store.state == .free)
    }

    @Test("Le statut fondateur publié est rebâti depuis la charge signée, jamais depuis les champs du record")
    func founderFactsComeFromThePayload() throws {
        let signature = testRoot
        // The record CLAIMS build 1.0 (a founder for any pivot); the signed
        // payload says 1.0.2.
        let published = AppTransactionSnapshot(
            originalAppVersion: "1.0", originalPurchaseDate: Date(timeIntervalSince1970: 0),
            environment: .production, signedTransaction: JWSFixture.appTransaction
        )
        let facts = try #require(signature.verifiedFounderFacts(published, expectedBundleID: "com.cinemax.tvos"))
        #expect(facts.originalAppVersion == "1.0.2")
        #expect(facts.originalPurchaseDate == Date(timeIntervalSince1970: 1_593_000_000))
        #expect(facts.environment == .production)
        // Another app's transaction, the purchase JWS, no JWS: nothing.
        #expect(signature.verifiedFounderFacts(published, expectedBundleID: "com.cinemax.ios") == nil)
        var purchase = published
        purchase.signedTransaction = JWSFixture.purchase
        #expect(signature.verifiedFounderFacts(purchase, expectedBundleID: "com.cinemax.tvos") == nil)
        purchase.signedTransaction = nil
        #expect(signature.verifiedFounderFacts(purchase, expectedBundleID: "com.cinemax.tvos") == nil)
        #expect(AppStoreSignature.founderFacts(
            payload: SignedAppTransactionPayload(bundleId: "com.cinemax.tvos", receiptType: "Sandbox", originalApplicationVersion: "1.0", originalPurchaseDate: 0),
            jws: "x", expectedBundleID: "com.cinemax.tvos"
        ) == nil)

        // Through the service: pivot 1.0.1 — the edited « 1.0 » would be a
        // founder, the signed 1.0.2 is not.
        let cloud = InMemoryCloudKeyValueStore()
        cloud.set(EarlyAdopterCacheRecord(transaction: published, fetchedAt: Date()).encoded(), forKey: EarlyAdopterPlatform.tvOS.mirrorKey)
        let phone = EarlyAdopterService(
            cache: SignatureTestCache(), configuration: .init(pivotBuild: BuildNumber("1.0.1"), pivotDate: nil),
            defaults: .isolatedForTesting(), cloud: cloud, platform: .iOS,
            verifyPublished: { signature.verifiedFounderFacts($0, expectedBundleID: $1) }
        )
        #expect(phone.otherPlatformTransaction?.originalAppVersion == "1.0.2")
        #expect(phone.otherPlatformStatus == .regular)
        // …and with no pivot (today), the same signed facts make a founder.
        let today = EarlyAdopterService(
            cache: SignatureTestCache(), configuration: .production,
            defaults: .isolatedForTesting(), cloud: cloud, platform: .iOS,
            verifyPublished: { signature.verifiedFounderFacts($0, expectedBundleID: $1) }
        )
        #expect(today.otherPlatformStatus == .earlyAdopter)
    }

    @Test("Chaque app vend son produit, et aucun autre identifiant n'en vend")
    func productPerBundle() {
        #expect(ProProduct.id(forBundleID: EarlyAdopterPlatform.iOS.bundleID) == ProProduct.iOSProductID)
        #expect(ProProduct.id(forBundleID: EarlyAdopterPlatform.tvOS.bundleID) == ProProduct.tvOSProductID)
        #expect(ProProduct.id(forBundleID: "com.cinemax.ios.widget") == nil)
        // The hard-coded ids are the real ones (the test host IS the app).
        #expect(Bundle.main.bundleIdentifier == EarlyAdopterPlatform.current.bundleID)
    }
}

@MainActor
private final class SignatureTestCache: EarlyAdopterCache {
    func load() -> EarlyAdopterCacheRecord? { nil }
    func save(_ record: EarlyAdopterCacheRecord) {}
}

/// Test App Store JWS fixtures, signed by a TEST PKI (openssl, 2026-11-13):
/// a root, an intermediate carrying Apple's WWDR marker OID, a leaf carrying
/// the App Store receipt-signing one (valid 2020-01-01 → 2021-01-01 only — so a
/// JWS signed in 2020 must still verify today), and a leaf without the marker.
/// Payloads: the tvOS app's Pro purchase and app transaction (original build
/// 1.0.2; like a real one it has no `signedDate`, only `receiptCreationDate`),
/// production, signed 2020-07-01; two more signed 2022-07-01.
private enum JWSFixture {
    static let root = "MIIBgzCCASigAwIBAgIUcnaL6nUSSHCccNSNZI8g/2lXCMgwCgYIKoZIzj0EAwIwHzEdMBsGA1UEAwwUSmVsbHlHbGFzcyBUZXN0IFJvb3QwHhcNMTkwMTAxMDAwMDAwWhcNNDUwMTAxMDAwMDAwWjAfMR0wGwYDVQQDDBRKZWxseUdsYXNzIFRlc3QgUm9vdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABHljfN9Fn9ECCJDGlSOpssny5lfPAQ2bWLjU3lR11WyAk3mIe578e7AawzYSEtECfLSyirMHKYzt0kl9N/iLhUujQjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBSHW8V/W2yGhv2LDH48Edf8iDRUGjAKBggqhkjOPQQDAgNJADBGAiEA6vzk5i5Kf6kUCqq8gfFGpyVnR3s6jtyIOEhFB8t0twMCIQDu1l33TT1n1fW3Vy9dvVa6GjYs788f1Jpjc6iChI7/CA=="
    static let purchase = "eyJhbGciOiJFUzI1NiIsIng1YyI6WyJNSUlCcHpDQ0FVMmdBd0lCQWdJQkF6QUtCZ2dxaGtqT1BRUURBakFuTVNVd0l3WURWUVFEREJ4S1pXeHNlVWRzWVhOeklGUmxjM1FnU1c1MFpYSnRaV1JwWVhSbE1CNFhEVEl3TURFd01UQXdNREF3TUZvWERUSXhNREV3TVRBd01EQXdNRm93SHpFZE1Cc0dBMVVFQXd3VVNtVnNiSGxIYkdGemN5QlVaWE4wSUd4bFlXWXdXVEFUQmdjcWhrak9QUUlCQmdncWhrak9QUU1CQndOQ0FBUjVFRlRZdXVneDgvamJnR2lzamR4clNiZ0IvcE1RaStTVEs3NlNRa2pLOVVhaFAra3REb1ZYKzZpRm5FYkU2SHlaZEcycTJyRlBYcVJublEzMHlNNXhvM0l3Y0RBTUJnTlZIUk1CQWY4RUFqQUFNQTRHQTFVZER3RUIvd1FFQXdJSGdEQWRCZ05WSFE0RUZnUVVPRER5QktZZmJDSW9LNXg1elNtdlF6cWdrVkV3SHdZRFZSMGpCQmd3Rm9BVWdOQ3o4WEZLamVHdktnTWoxNkUzVC9kZmJQOHdFQVlLS29aSWh2ZGpaQVlMQVFRQ0JRQXdDZ1lJS29aSXpqMEVBd0lEU0FBd1JRSWdDczV5TVM5MGt3NElmVFROZEdteTNMS2hZSldmV2I2cGhLY0k2dWJQWURjQ0lRQ1VyV2R0K2NNSWFzb1ZrOHNWaGtHbGoxMmJnNllNOHpVSGM2VityN25RN1E9PSIsIk1JSUJyVENDQVZPZ0F3SUJBZ0lCQWpBS0JnZ3Foa2pPUFFRREFqQWZNUjB3R3dZRFZRUUREQlJLWld4c2VVZHNZWE56SUZSbGMzUWdVbTl2ZERBZUZ3MHhPVEEyTURFd01EQXdNREJhRncwME1EQXhNREV3TURBd01EQmFNQ2N4SlRBakJnTlZCQU1NSEVwbGJHeDVSMnhoYzNNZ1ZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVd1dUQVRCZ2NxaGtqT1BRSUJCZ2dxaGtqT1BRTUJCd05DQUFUb0Q3SGR3b3hEU3cxYXZVREtNYnk2aGdkUEJLblAyZjliL25IbWtIZDlqeXN5NHRybGFlSzZya0pJc2M3ZEdOSjNpSmtzRGdabFIxdUVPbE9jMTN3WG8zZ3dkakFTQmdOVkhSTUJBZjhFQ0RBR0FRSC9BZ0VBTUE0R0ExVWREd0VCL3dRRUF3SUJCakFkQmdOVkhRNEVGZ1FVZ05DejhYRktqZUd2S2dNajE2RTNUL2RmYlA4d0h3WURWUjBqQkJnd0ZvQVVoMXZGZjF0c2hvYjlpd3grUEJIWC9JZzBWQm93RUFZS0tvWklodmRqWkFZQ0FRUUNCUUF3Q2dZSUtvWkl6ajBFQXdJRFNBQXdSUUloQU12SkJQREVGTXFBUVB0ajRUOTMzY2RadldoZVFzNVk5RUJIeStaRVNGU3pBaUI4amtFRHFDTndQZmEyU1FpS2svS3d1dFJkdUpnTWhTZVBFZ0hBemgxQndnPT0iLCJNSUlCZ3pDQ0FTaWdBd0lCQWdJVWNuYUw2blVTU0hDY2NOU05aSThnLzJsWENNZ3dDZ1lJS29aSXpqMEVBd0l3SHpFZE1Cc0dBMVVFQXd3VVNtVnNiSGxIYkdGemN5QlVaWE4wSUZKdmIzUXdIaGNOTVRrd01UQXhNREF3TURBd1doY05ORFV3TVRBeE1EQXdNREF3V2pBZk1SMHdHd1lEVlFRRERCUktaV3hzZVVkc1lYTnpJRlJsYzNRZ1VtOXZkREJaTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEEwSUFCSGxqZk45Rm45RUNDSkRHbFNPcHNzbnk1bGZQQVEyYldMalUzbFIxMVd5QWszbUllNTc4ZTdBYXd6WVNFdEVDZkxTeWlyTUhLWXp0MGtsOU4vaUxoVXVqUWpCQU1BOEdBMVVkRXdFQi93UUZNQU1CQWY4d0RnWURWUjBQQVFIL0JBUURBZ0VHTUIwR0ExVWREZ1FXQkJTSFc4Vi9XMnlHaHYyTERINDhFZGY4aURSVUdqQUtCZ2dxaGtqT1BRUURBZ05KQURCR0FpRUE2dnprNWk1S2Y2a1VDcXE4Z2ZGR3B5Vm5SM3M2anR5SU9FaEZCOHQwdHdNQ0lRRHUxbDMzVFQxbjFmVzNWeTlkdlZhNkdqWXM3ODhmMUpwamM2aUNoSTcvQ0E9PSJdfQ.eyJidW5kbGVJZCI6ImNvbS5jaW5lbWF4LnR2b3MiLCJwcm9kdWN0SWQiOiJjb20uY2luZW1heC50dm9zLnBybyIsIm9yaWdpbmFsVHJhbnNhY3Rpb25JZCI6IjIwMDAwMDAxMTEiLCJ0cmFuc2FjdGlvbklkIjoiMjAwMDAwMDExMSIsImVudmlyb25tZW50IjoiUHJvZHVjdGlvbiIsInR5cGUiOiJOb24tQ29uc3VtYWJsZSIsInB1cmNoYXNlRGF0ZSI6MTU5MzUwMDAwMDAwMCwib3JpZ2luYWxQdXJjaGFzZURhdGUiOjE1OTM1MDAwMDAwMDAsInNpZ25lZERhdGUiOjE1OTM1NjE2MDAwMDB9.lpb-i3iD56Mxm5P8b24F4-hzLUloYndnYhwZGDTsKjbv3n64VVAe1caNg9SvyIo1mTdaYyYTRmOSsVhmKBcoHQ"
    static let appTransaction = "eyJhbGciOiJFUzI1NiIsIng1YyI6WyJNSUlCcHpDQ0FVMmdBd0lCQWdJQkF6QUtCZ2dxaGtqT1BRUURBakFuTVNVd0l3WURWUVFEREJ4S1pXeHNlVWRzWVhOeklGUmxjM1FnU1c1MFpYSnRaV1JwWVhSbE1CNFhEVEl3TURFd01UQXdNREF3TUZvWERUSXhNREV3TVRBd01EQXdNRm93SHpFZE1Cc0dBMVVFQXd3VVNtVnNiSGxIYkdGemN5QlVaWE4wSUd4bFlXWXdXVEFUQmdjcWhrak9QUUlCQmdncWhrak9QUU1CQndOQ0FBUjVFRlRZdXVneDgvamJnR2lzamR4clNiZ0IvcE1RaStTVEs3NlNRa2pLOVVhaFAra3REb1ZYKzZpRm5FYkU2SHlaZEcycTJyRlBYcVJublEzMHlNNXhvM0l3Y0RBTUJnTlZIUk1CQWY4RUFqQUFNQTRHQTFVZER3RUIvd1FFQXdJSGdEQWRCZ05WSFE0RUZnUVVPRER5QktZZmJDSW9LNXg1elNtdlF6cWdrVkV3SHdZRFZSMGpCQmd3Rm9BVWdOQ3o4WEZLamVHdktnTWoxNkUzVC9kZmJQOHdFQVlLS29aSWh2ZGpaQVlMQVFRQ0JRQXdDZ1lJS29aSXpqMEVBd0lEU0FBd1JRSWdDczV5TVM5MGt3NElmVFROZEdteTNMS2hZSldmV2I2cGhLY0k2dWJQWURjQ0lRQ1VyV2R0K2NNSWFzb1ZrOHNWaGtHbGoxMmJnNllNOHpVSGM2VityN25RN1E9PSIsIk1JSUJyVENDQVZPZ0F3SUJBZ0lCQWpBS0JnZ3Foa2pPUFFRREFqQWZNUjB3R3dZRFZRUUREQlJLWld4c2VVZHNZWE56SUZSbGMzUWdVbTl2ZERBZUZ3MHhPVEEyTURFd01EQXdNREJhRncwME1EQXhNREV3TURBd01EQmFNQ2N4SlRBakJnTlZCQU1NSEVwbGJHeDVSMnhoYzNNZ1ZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVd1dUQVRCZ2NxaGtqT1BRSUJCZ2dxaGtqT1BRTUJCd05DQUFUb0Q3SGR3b3hEU3cxYXZVREtNYnk2aGdkUEJLblAyZjliL25IbWtIZDlqeXN5NHRybGFlSzZya0pJc2M3ZEdOSjNpSmtzRGdabFIxdUVPbE9jMTN3WG8zZ3dkakFTQmdOVkhSTUJBZjhFQ0RBR0FRSC9BZ0VBTUE0R0ExVWREd0VCL3dRRUF3SUJCakFkQmdOVkhRNEVGZ1FVZ05DejhYRktqZUd2S2dNajE2RTNUL2RmYlA4d0h3WURWUjBqQkJnd0ZvQVVoMXZGZjF0c2hvYjlpd3grUEJIWC9JZzBWQm93RUFZS0tvWklodmRqWkFZQ0FRUUNCUUF3Q2dZSUtvWkl6ajBFQXdJRFNBQXdSUUloQU12SkJQREVGTXFBUVB0ajRUOTMzY2RadldoZVFzNVk5RUJIeStaRVNGU3pBaUI4amtFRHFDTndQZmEyU1FpS2svS3d1dFJkdUpnTWhTZVBFZ0hBemgxQndnPT0iLCJNSUlCZ3pDQ0FTaWdBd0lCQWdJVWNuYUw2blVTU0hDY2NOU05aSThnLzJsWENNZ3dDZ1lJS29aSXpqMEVBd0l3SHpFZE1Cc0dBMVVFQXd3VVNtVnNiSGxIYkdGemN5QlVaWE4wSUZKdmIzUXdIaGNOTVRrd01UQXhNREF3TURBd1doY05ORFV3TVRBeE1EQXdNREF3V2pBZk1SMHdHd1lEVlFRRERCUktaV3hzZVVkc1lYTnpJRlJsYzNRZ1VtOXZkREJaTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEEwSUFCSGxqZk45Rm45RUNDSkRHbFNPcHNzbnk1bGZQQVEyYldMalUzbFIxMVd5QWszbUllNTc4ZTdBYXd6WVNFdEVDZkxTeWlyTUhLWXp0MGtsOU4vaUxoVXVqUWpCQU1BOEdBMVVkRXdFQi93UUZNQU1CQWY4d0RnWURWUjBQQVFIL0JBUURBZ0VHTUIwR0ExVWREZ1FXQkJTSFc4Vi9XMnlHaHYyTERINDhFZGY4aURSVUdqQUtCZ2dxaGtqT1BRUURBZ05KQURCR0FpRUE2dnprNWk1S2Y2a1VDcXE4Z2ZGR3B5Vm5SM3M2anR5SU9FaEZCOHQwdHdNQ0lRRHUxbDMzVFQxbjFmVzNWeTlkdlZhNkdqWXM3ODhmMUpwamM2aUNoSTcvQ0E9PSJdfQ.eyJidW5kbGVJZCI6ImNvbS5jaW5lbWF4LnR2b3MiLCJyZWNlaXB0VHlwZSI6IlByb2R1Y3Rpb24iLCJvcmlnaW5hbEFwcGxpY2F0aW9uVmVyc2lvbiI6IjEuMC4yIiwiYXBwbGljYXRpb25WZXJzaW9uIjoiMi41LjAiLCJvcmlnaW5hbFB1cmNoYXNlRGF0ZSI6MTU5MzAwMDAwMDAwMCwicmVjZWlwdENyZWF0aW9uRGF0ZSI6MTU5MzU2MTYwMDAwMH0.v-8jAoOyS-0-dYSZK7quOeqo5BuKU2z-d_68ni2YYRvBkP1dzcVBI0PSnU69SEOs_lLsoItd7nTVGILGLVd4ZQ"
    static let noMarker = "eyJhbGciOiJFUzI1NiIsIng1YyI6WyJNSUlCbWpDQ0FVQ2dBd0lCQWdJQkF6QUtCZ2dxaGtqT1BRUURBakFuTVNVd0l3WURWUVFEREJ4S1pXeHNlVWRzWVhOeklGUmxjM1FnU1c1MFpYSnRaV1JwWVhSbE1CNFhEVEl3TURFd01UQXdNREF3TUZvWERUSXhNREV3TVRBd01EQXdNRm93SkRFaU1DQUdBMVVFQXd3WlNtVnNiSGxIYkdGemN5QlVaWE4wSUd4bFlXWnViMjlwWkRCWk1CTUdCeXFHU000OUFnRUdDQ3FHU000OUF3RUhBMElBQklxVjJUaWhGcUJYMkRXc2dYMDRaV0ZPaVMzMEJpMWVjUys3a3VxTUFUWkxtdXVNajJhdGxLeXV1WnFNcnVnMklTamFSUGFwRFJGZE02dTJnc3FMamhtallEQmVNQXdHQTFVZEV3RUIvd1FDTUFBd0RnWURWUjBQQVFIL0JBUURBZ2VBTUIwR0ExVWREZ1FXQkJTOGphT1NxRmhBUFF1T0FZVis0U0d6cVRpQWp6QWZCZ05WSFNNRUdEQVdnQlNBMExQeGNVcU40YThxQXlQWG9UZFA5MTlzL3pBS0JnZ3Foa2pPUFFRREFnTklBREJGQWlFQWhSUFdRaUl4V3piL1F4dStFRFRIZSswTE1IZ2dMSkJjbW1uOHpoZm5iaUFDSUU5OUxvdDA1OU0vckM5NDd3dGNUM1IwZ2hBY3FZYkN6M0pwWFJvQ29YRzMiLCJNSUlCclRDQ0FWT2dBd0lCQWdJQkFqQUtCZ2dxaGtqT1BRUURBakFmTVIwd0d3WURWUVFEREJSS1pXeHNlVWRzWVhOeklGUmxjM1FnVW05dmREQWVGdzB4T1RBMk1ERXdNREF3TURCYUZ3MDBNREF4TURFd01EQXdNREJhTUNjeEpUQWpCZ05WQkFNTUhFcGxiR3g1UjJ4aGMzTWdWR1Z6ZENCSmJuUmxjbTFsWkdsaGRHVXdXVEFUQmdjcWhrak9QUUlCQmdncWhrak9QUU1CQndOQ0FBVG9EN0hkd294RFN3MWF2VURLTWJ5NmhnZFBCS25QMmY5Yi9uSG1rSGQ5anlzeTR0cmxhZUs2cmtKSXNjN2RHTkozaUprc0RnWmxSMXVFT2xPYzEzd1hvM2d3ZGpBU0JnTlZIUk1CQWY4RUNEQUdBUUgvQWdFQU1BNEdBMVVkRHdFQi93UUVBd0lCQmpBZEJnTlZIUTRFRmdRVWdOQ3o4WEZLamVHdktnTWoxNkUzVC9kZmJQOHdId1lEVlIwakJCZ3dGb0FVaDF2RmYxdHNob2I5aXd4K1BCSFgvSWcwVkJvd0VBWUtLb1pJaHZkalpBWUNBUVFDQlFBd0NnWUlLb1pJemowRUF3SURTQUF3UlFJaEFNdkpCUERFRk1xQVFQdGo0VDkzM2NkWnZXaGVRczVZOUVCSHkrWkVTRlN6QWlCOGprRURxQ053UGZhMlNRaUtrL0t3dXRSZHVKZ01oU2VQRWdIQXpoMUJ3Zz09IiwiTUlJQmd6Q0NBU2lnQXdJQkFnSVVjbmFMNm5VU1NIQ2NjTlNOWkk4Zy8ybFhDTWd3Q2dZSUtvWkl6ajBFQXdJd0h6RWRNQnNHQTFVRUF3d1VTbVZzYkhsSGJHRnpjeUJVWlhOMElGSnZiM1F3SGhjTk1Ua3dNVEF4TURBd01EQXdXaGNOTkRVd01UQXhNREF3TURBd1dqQWZNUjB3R3dZRFZRUUREQlJLWld4c2VVZHNZWE56SUZSbGMzUWdVbTl2ZERCWk1CTUdCeXFHU000OUFnRUdDQ3FHU000OUF3RUhBMElBQkhsamZOOUZuOUVDQ0pER2xTT3Bzc255NWxmUEFRMmJXTGpVM2xSMTFXeUFrM21JZTU3OGU3QWF3ellTRXRFQ2ZMU3lpck1IS1l6dDBrbDlOL2lMaFV1alFqQkFNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEZ1lEVlIwUEFRSC9CQVFEQWdFR01CMEdBMVVkRGdRV0JCU0hXOFYvVzJ5R2h2MkxESDQ4RWRmOGlEUlVHakFLQmdncWhrak9QUVFEQWdOSkFEQkdBaUVBNnZ6azVpNUtmNmtVQ3FxOGdmRkdweVZuUjNzNmp0eUlPRWhGQjh0MHR3TUNJUUR1MWwzM1RUMW4xZlczVnk5ZHZWYTZHallzNzg4ZjFKcGpjNmlDaEk3L0NBPT0iXX0.eyJidW5kbGVJZCI6ImNvbS5jaW5lbWF4LnR2b3MiLCJwcm9kdWN0SWQiOiJjb20uY2luZW1heC50dm9zLnBybyIsIm9yaWdpbmFsVHJhbnNhY3Rpb25JZCI6IjIwMDAwMDAxMTEiLCJ0cmFuc2FjdGlvbklkIjoiMjAwMDAwMDExMSIsImVudmlyb25tZW50IjoiUHJvZHVjdGlvbiIsInR5cGUiOiJOb24tQ29uc3VtYWJsZSIsInB1cmNoYXNlRGF0ZSI6MTU5MzUwMDAwMDAwMCwib3JpZ2luYWxQdXJjaGFzZURhdGUiOjE1OTM1MDAwMDAwMDAsInNpZ25lZERhdGUiOjE1OTM1NjE2MDAwMDB9.NbDIo183eie-FmtY7F_kb-Gyj-i0q3zSsHO0beI5UxBtMD8G3N9hfghQSofn0KV_JXeggkFJtKwHWu1YzUXfyQ"
    static let signedAfterLeafExpiry = "eyJhbGciOiJFUzI1NiIsIng1YyI6WyJNSUlCcHpDQ0FVMmdBd0lCQWdJQkF6QUtCZ2dxaGtqT1BRUURBakFuTVNVd0l3WURWUVFEREJ4S1pXeHNlVWRzWVhOeklGUmxjM1FnU1c1MFpYSnRaV1JwWVhSbE1CNFhEVEl3TURFd01UQXdNREF3TUZvWERUSXhNREV3TVRBd01EQXdNRm93SHpFZE1Cc0dBMVVFQXd3VVNtVnNiSGxIYkdGemN5QlVaWE4wSUd4bFlXWXdXVEFUQmdjcWhrak9QUUlCQmdncWhrak9QUU1CQndOQ0FBUjVFRlRZdXVneDgvamJnR2lzamR4clNiZ0IvcE1RaStTVEs3NlNRa2pLOVVhaFAra3REb1ZYKzZpRm5FYkU2SHlaZEcycTJyRlBYcVJublEzMHlNNXhvM0l3Y0RBTUJnTlZIUk1CQWY4RUFqQUFNQTRHQTFVZER3RUIvd1FFQXdJSGdEQWRCZ05WSFE0RUZnUVVPRER5QktZZmJDSW9LNXg1elNtdlF6cWdrVkV3SHdZRFZSMGpCQmd3Rm9BVWdOQ3o4WEZLamVHdktnTWoxNkUzVC9kZmJQOHdFQVlLS29aSWh2ZGpaQVlMQVFRQ0JRQXdDZ1lJS29aSXpqMEVBd0lEU0FBd1JRSWdDczV5TVM5MGt3NElmVFROZEdteTNMS2hZSldmV2I2cGhLY0k2dWJQWURjQ0lRQ1VyV2R0K2NNSWFzb1ZrOHNWaGtHbGoxMmJnNllNOHpVSGM2VityN25RN1E9PSIsIk1JSUJyVENDQVZPZ0F3SUJBZ0lCQWpBS0JnZ3Foa2pPUFFRREFqQWZNUjB3R3dZRFZRUUREQlJLWld4c2VVZHNZWE56SUZSbGMzUWdVbTl2ZERBZUZ3MHhPVEEyTURFd01EQXdNREJhRncwME1EQXhNREV3TURBd01EQmFNQ2N4SlRBakJnTlZCQU1NSEVwbGJHeDVSMnhoYzNNZ1ZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVd1dUQVRCZ2NxaGtqT1BRSUJCZ2dxaGtqT1BRTUJCd05DQUFUb0Q3SGR3b3hEU3cxYXZVREtNYnk2aGdkUEJLblAyZjliL25IbWtIZDlqeXN5NHRybGFlSzZya0pJc2M3ZEdOSjNpSmtzRGdabFIxdUVPbE9jMTN3WG8zZ3dkakFTQmdOVkhSTUJBZjhFQ0RBR0FRSC9BZ0VBTUE0R0ExVWREd0VCL3dRRUF3SUJCakFkQmdOVkhRNEVGZ1FVZ05DejhYRktqZUd2S2dNajE2RTNUL2RmYlA4d0h3WURWUjBqQkJnd0ZvQVVoMXZGZjF0c2hvYjlpd3grUEJIWC9JZzBWQm93RUFZS0tvWklodmRqWkFZQ0FRUUNCUUF3Q2dZSUtvWkl6ajBFQXdJRFNBQXdSUUloQU12SkJQREVGTXFBUVB0ajRUOTMzY2RadldoZVFzNVk5RUJIeStaRVNGU3pBaUI4amtFRHFDTndQZmEyU1FpS2svS3d1dFJkdUpnTWhTZVBFZ0hBemgxQndnPT0iLCJNSUlCZ3pDQ0FTaWdBd0lCQWdJVWNuYUw2blVTU0hDY2NOU05aSThnLzJsWENNZ3dDZ1lJS29aSXpqMEVBd0l3SHpFZE1Cc0dBMVVFQXd3VVNtVnNiSGxIYkdGemN5QlVaWE4wSUZKdmIzUXdIaGNOTVRrd01UQXhNREF3TURBd1doY05ORFV3TVRBeE1EQXdNREF3V2pBZk1SMHdHd1lEVlFRRERCUktaV3hzZVVkc1lYTnpJRlJsYzNRZ1VtOXZkREJaTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEEwSUFCSGxqZk45Rm45RUNDSkRHbFNPcHNzbnk1bGZQQVEyYldMalUzbFIxMVd5QWszbUllNTc4ZTdBYXd6WVNFdEVDZkxTeWlyTUhLWXp0MGtsOU4vaUxoVXVqUWpCQU1BOEdBMVVkRXdFQi93UUZNQU1CQWY4d0RnWURWUjBQQVFIL0JBUURBZ0VHTUIwR0ExVWREZ1FXQkJTSFc4Vi9XMnlHaHYyTERINDhFZGY4aURSVUdqQUtCZ2dxaGtqT1BRUURBZ05KQURCR0FpRUE2dnprNWk1S2Y2a1VDcXE4Z2ZGR3B5Vm5SM3M2anR5SU9FaEZCOHQwdHdNQ0lRRHUxbDMzVFQxbjFmVzNWeTlkdlZhNkdqWXM3ODhmMUpwamM2aUNoSTcvQ0E9PSJdfQ.eyJidW5kbGVJZCI6ImNvbS5jaW5lbWF4LnR2b3MiLCJwcm9kdWN0SWQiOiJjb20uY2luZW1heC50dm9zLnBybyIsIm9yaWdpbmFsVHJhbnNhY3Rpb25JZCI6IjIwMDAwMDAxMTEiLCJ0cmFuc2FjdGlvbklkIjoiMjAwMDAwMDExMSIsImVudmlyb25tZW50IjoiUHJvZHVjdGlvbiIsInR5cGUiOiJOb24tQ29uc3VtYWJsZSIsInB1cmNoYXNlRGF0ZSI6MTU5MzUwMDAwMDAwMCwib3JpZ2luYWxQdXJjaGFzZURhdGUiOjE1OTM1MDAwMDAwMDAsInNpZ25lZERhdGUiOjE2NTY2MzM2MDAwMDB9.qEEmrT1sakXORrnJat6b8kECemdz7QpRbYvZCSLvo-7YcdEjlxKBCHS4jtGJwqNMhsOFyR1hGFSGpT3E7VZNqQ"
    static let appTransactionAfterLeafExpiry = "eyJhbGciOiJFUzI1NiIsIng1YyI6WyJNSUlCcHpDQ0FVMmdBd0lCQWdJQkF6QUtCZ2dxaGtqT1BRUURBakFuTVNVd0l3WURWUVFEREJ4S1pXeHNlVWRzWVhOeklGUmxjM1FnU1c1MFpYSnRaV1JwWVhSbE1CNFhEVEl3TURFd01UQXdNREF3TUZvWERUSXhNREV3TVRBd01EQXdNRm93SHpFZE1Cc0dBMVVFQXd3VVNtVnNiSGxIYkdGemN5QlVaWE4wSUd4bFlXWXdXVEFUQmdjcWhrak9QUUlCQmdncWhrak9QUU1CQndOQ0FBUjVFRlRZdXVneDgvamJnR2lzamR4clNiZ0IvcE1RaStTVEs3NlNRa2pLOVVhaFAra3REb1ZYKzZpRm5FYkU2SHlaZEcycTJyRlBYcVJublEzMHlNNXhvM0l3Y0RBTUJnTlZIUk1CQWY4RUFqQUFNQTRHQTFVZER3RUIvd1FFQXdJSGdEQWRCZ05WSFE0RUZnUVVPRER5QktZZmJDSW9LNXg1elNtdlF6cWdrVkV3SHdZRFZSMGpCQmd3Rm9BVWdOQ3o4WEZLamVHdktnTWoxNkUzVC9kZmJQOHdFQVlLS29aSWh2ZGpaQVlMQVFRQ0JRQXdDZ1lJS29aSXpqMEVBd0lEU0FBd1JRSWdDczV5TVM5MGt3NElmVFROZEdteTNMS2hZSldmV2I2cGhLY0k2dWJQWURjQ0lRQ1VyV2R0K2NNSWFzb1ZrOHNWaGtHbGoxMmJnNllNOHpVSGM2VityN25RN1E9PSIsIk1JSUJyVENDQVZPZ0F3SUJBZ0lCQWpBS0JnZ3Foa2pPUFFRREFqQWZNUjB3R3dZRFZRUUREQlJLWld4c2VVZHNZWE56SUZSbGMzUWdVbTl2ZERBZUZ3MHhPVEEyTURFd01EQXdNREJhRncwME1EQXhNREV3TURBd01EQmFNQ2N4SlRBakJnTlZCQU1NSEVwbGJHeDVSMnhoYzNNZ1ZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVd1dUQVRCZ2NxaGtqT1BRSUJCZ2dxaGtqT1BRTUJCd05DQUFUb0Q3SGR3b3hEU3cxYXZVREtNYnk2aGdkUEJLblAyZjliL25IbWtIZDlqeXN5NHRybGFlSzZya0pJc2M3ZEdOSjNpSmtzRGdabFIxdUVPbE9jMTN3WG8zZ3dkakFTQmdOVkhSTUJBZjhFQ0RBR0FRSC9BZ0VBTUE0R0ExVWREd0VCL3dRRUF3SUJCakFkQmdOVkhRNEVGZ1FVZ05DejhYRktqZUd2S2dNajE2RTNUL2RmYlA4d0h3WURWUjBqQkJnd0ZvQVVoMXZGZjF0c2hvYjlpd3grUEJIWC9JZzBWQm93RUFZS0tvWklodmRqWkFZQ0FRUUNCUUF3Q2dZSUtvWkl6ajBFQXdJRFNBQXdSUUloQU12SkJQREVGTXFBUVB0ajRUOTMzY2RadldoZVFzNVk5RUJIeStaRVNGU3pBaUI4amtFRHFDTndQZmEyU1FpS2svS3d1dFJkdUpnTWhTZVBFZ0hBemgxQndnPT0iLCJNSUlCZ3pDQ0FTaWdBd0lCQWdJVWNuYUw2blVTU0hDY2NOU05aSThnLzJsWENNZ3dDZ1lJS29aSXpqMEVBd0l3SHpFZE1Cc0dBMVVFQXd3VVNtVnNiSGxIYkdGemN5QlVaWE4wSUZKdmIzUXdIaGNOTVRrd01UQXhNREF3TURBd1doY05ORFV3TVRBeE1EQXdNREF3V2pBZk1SMHdHd1lEVlFRRERCUktaV3hzZVVkc1lYTnpJRlJsYzNRZ1VtOXZkREJaTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEEwSUFCSGxqZk45Rm45RUNDSkRHbFNPcHNzbnk1bGZQQVEyYldMalUzbFIxMVd5QWszbUllNTc4ZTdBYXd6WVNFdEVDZkxTeWlyTUhLWXp0MGtsOU4vaUxoVXVqUWpCQU1BOEdBMVVkRXdFQi93UUZNQU1CQWY4d0RnWURWUjBQQVFIL0JBUURBZ0VHTUIwR0ExVWREZ1FXQkJTSFc4Vi9XMnlHaHYyTERINDhFZGY4aURSVUdqQUtCZ2dxaGtqT1BRUURBZ05KQURCR0FpRUE2dnprNWk1S2Y2a1VDcXE4Z2ZGR3B5Vm5SM3M2anR5SU9FaEZCOHQwdHdNQ0lRRHUxbDMzVFQxbjFmVzNWeTlkdlZhNkdqWXM3ODhmMUpwamM2aUNoSTcvQ0E9PSJdfQ.eyJidW5kbGVJZCI6ImNvbS5jaW5lbWF4LnR2b3MiLCJyZWNlaXB0VHlwZSI6IlByb2R1Y3Rpb24iLCJvcmlnaW5hbEFwcGxpY2F0aW9uVmVyc2lvbiI6IjEuMC4yIiwiYXBwbGljYXRpb25WZXJzaW9uIjoiMi41LjAiLCJvcmlnaW5hbFB1cmNoYXNlRGF0ZSI6MTU5MzAwMDAwMDAwMCwicmVjZWlwdENyZWF0aW9uRGF0ZSI6MTY1NjYzMzYwMDAwMH0.6vvw0Hp5HzTYO3hqDCfbhKsB7r1ufaM9MYtASb2e_kRuPfQpbUyIRQocBbJbnFhbWIzVHBiHj2SHKj0Ky8HgKA"
}
