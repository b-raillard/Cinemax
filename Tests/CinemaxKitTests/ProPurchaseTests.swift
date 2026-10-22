import Foundation
import Testing
@testable import Cinemax

private let iosBundle = "com.cinemax.ios"
private let tvBundle = "com.cinemax.tvos"

private func fact(
    product: String = ProProduct.iOSProductID,
    transaction: String = "2000000111",
    familyShared: Bool = false,
    environment: AppTransactionSnapshot.Environment = .production
) -> ProEntitlementFact {
    ProEntitlementFact(
        productID: product,
        originalTransactionID: transaction,
        purchaseDate: Date(timeIntervalSinceReferenceDate: 812_000_000),
        signedTransaction: "jws.\(transaction)",
        isFamilyShared: familyShared,
        environment: environment
    )
}

private func record(writer: String = iosBundle, transaction: String = "2000000111") -> CloudEntitlementRecord {
    fact(transaction: transaction).record(writerBundleID: writer)
}

// MARK: - Revoking this app's own purchase

@MainActor
@Suite("Retrait de son propre achat")
struct RevokeOwnPurchaseTests {

    @Test("Le miroir écrit par CETTE app part avec l'enregistrement local")
    func ownMirrorRemoved() {
        let cloud = InMemoryCloudKeyValueStore()
        let store = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud)
        store.recordPurchase(record(writer: iosBundle))
        #expect(store.state.isPro)

        store.revokeOwnPurchase(ownBundleID: iosBundle)

        #expect(store.localRecord == nil)
        #expect(store.cloudRecord == nil)
        #expect(cloud.data(forKey: CloudEntitlementMirror.key) == nil)
        #expect(store.state == .free)
    }

    @Test("Le miroir de l'AUTRE plateforme n'est jamais touché")
    func otherPlatformMirrorKept() {
        let cloud = InMemoryCloudKeyValueStore()
        cloud.set(record(writer: tvBundle, transaction: "tv").encoded(), forKey: CloudEntitlementMirror.key)
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set(record(writer: iosBundle).encoded(), forKey: SettingsKey.entitlementLocalRecord)
        let store = EntitlementStore(defaults: defaults, cloud: cloud)

        store.revokeOwnPurchase(ownBundleID: iosBundle)

        #expect(store.localRecord == nil)
        #expect(store.cloudRecord?.writerBundleID == tvBundle)
        #expect(store.state == .pro(.cloudMirror))
    }

    @Test("Le miroir est relu juste avant d'être retiré : un record neuf de l'autre plateforme survit")
    func rereadsMirrorBeforeRemoving() {
        let cloud = InMemoryCloudKeyValueStore()
        let store = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud)
        store.recordPurchase(record(writer: iosBundle))
        // The Apple TV rewrote the key; its notification is not processed yet.
        cloud.set(record(writer: tvBundle, transaction: "tv").encoded(), forKey: CloudEntitlementMirror.key)

        store.revokeOwnPurchase(ownBundleID: iosBundle)

        #expect(cloud.data(forKey: CloudEntitlementMirror.key) != nil)
        #expect(store.state == .pro(.cloudMirror))
    }

    @Test("Un record d'achat de test (bac à sable, Xcode) lu dans iCloud ne débloque rien")
    func nonProductionMirrorIgnored() {
        let cloud = InMemoryCloudKeyValueStore()
        let sandbox = fact(transaction: "sb", environment: .sandbox).record(writerBundleID: tvBundle)
        cloud.set(sandbox.encoded(), forKey: CloudEntitlementMirror.key)
        let store = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud)
        #expect(store.state == .free)
    }
}

// MARK: - Reconciliation policy

@Suite("Politique d'achat Pro")
struct ProPurchasePolicyTests {

    @Test("Un droit vérifié jamais enregistré s'enregistre (local + miroir)")
    func recordsNewEntitlement() {
        let action = ProPurchasePolicy.reconcile(
            entitlement: .entitled(fact()), localRecord: nil, cloudRecord: nil, ownBundleID: iosBundle
        )
        #expect(action == .record(record(writer: iosBundle), mirror: true))
    }

    @Test("Un droit reçu par le Partage familial débloque comme un achat")
    func familySharedRecords() {
        let shared = fact(familyShared: true)
        let action = ProPurchasePolicy.reconcile(
            entitlement: .entitled(shared), localRecord: nil, cloudRecord: nil, ownBundleID: iosBundle
        )
        #expect(action == .record(shared.record(writerBundleID: iosBundle), mirror: true))
    }

    @Test("Un achat de test (bac à sable, TestFlight, Xcode) s'enregistre ici mais n'est jamais miroité")
    func nonProductionNotMirrored() {
        for environment in [AppTransactionSnapshot.Environment.sandbox, .xcode] {
            let test = fact(environment: environment)
            let action = ProPurchasePolicy.reconcile(
                entitlement: .entitled(test), localRecord: nil, cloudRecord: nil, ownBundleID: iosBundle
            )
            #expect(action == .record(test.record(writerBundleID: iosBundle), mirror: false))
            // Already recorded locally: nothing more to do, no mirror ever.
            let again = ProPurchasePolicy.reconcile(
                entitlement: .entitled(test), localRecord: test.record(writerBundleID: iosBundle),
                cloudRecord: nil, ownBundleID: iosBundle
            )
            #expect(again == .none)
        }
    }

    @Test("Déjà enregistré et miroité : rien à écrire")
    func alreadyRecorded() {
        let mine = record(writer: iosBundle)
        let action = ProPurchasePolicy.reconcile(
            entitlement: .entitled(fact()), localRecord: mine, cloudRecord: mine, ownBundleID: iosBundle
        )
        #expect(action == .none)
    }

    @Test("Un JWS ré-émis pour la même transaction ne réécrit rien")
    func sameTransactionNewJWSIgnored() {
        let mine = record(writer: iosBundle)
        var refreshed = fact()
        refreshed.signedTransaction = "jws.resigned"
        let action = ProPurchasePolicy.reconcile(
            entitlement: .entitled(refreshed), localRecord: mine, cloudRecord: mine, ownBundleID: iosBundle
        )
        #expect(action == .none)
    }

    @Test("Miroir effacé (remboursement sur l'autre appareil) : on le réécrit")
    func rewritesMissingMirror() {
        let mine = record(writer: iosBundle)
        let action = ProPurchasePolicy.reconcile(
            entitlement: .entitled(fact()), localRecord: mine, cloudRecord: nil, ownBundleID: iosBundle
        )
        #expect(action == .record(mine, mirror: true))
    }

    @Test("Le miroir de l'autre plateforme suffit à l'autre : on ne l'écrase pas pour rien")
    func keepsOtherPlatformMirror() {
        let mine = record(writer: iosBundle)
        let theirs = record(writer: tvBundle, transaction: "tv")
        let action = ProPurchasePolicy.reconcile(
            entitlement: .entitled(fact()), localRecord: mine, cloudRecord: theirs, ownBundleID: iosBundle
        )
        #expect(action == .none)
    }

    @Test("Révocation PROUVÉE (remboursement, départ du groupe) : retrait complet, miroir compris")
    func revokesOnProvenRevocation() {
        let action = ProPurchasePolicy.reconcile(
            entitlement: .revoked, localRecord: record(writer: iosBundle), cloudRecord: record(writer: iosBundle), ownBundleID: iosBundle
        )
        #expect(action == .revoke)
    }

    @Test("Remboursé puis réinstallé : plus de record local, mais NOTRE miroir doit partir")
    func revokedAfterReinstallRemovesOwnMirror() {
        let action = ProPurchasePolicy.reconcile(
            entitlement: .revoked, localRecord: nil, cloudRecord: record(writer: iosBundle), ownBundleID: iosBundle
        )
        #expect(action == .revoke)
    }

    @Test("Simple ABSENCE (compte App Store déconnecté, restauration hors ligne) : local seul, miroir gardé")
    func absenceOnlyClearsLocal() {
        let action = ProPurchasePolicy.reconcile(
            entitlement: .absent, localRecord: record(writer: iosBundle), cloudRecord: record(writer: iosBundle), ownBundleID: iosBundle
        )
        #expect(action == .clearLocal)
    }

    @Test("Rien d'enregistré ici, quelle que soit la réponse : on ne touche pas au miroir de l'autre")
    func nothingToRevoke() {
        for answer in [ProEntitlementState.absent, .revoked] {
            let action = ProPurchasePolicy.reconcile(
                entitlement: answer, localRecord: nil, cloudRecord: record(writer: tvBundle), ownBundleID: iosBundle
            )
            #expect(action == .none)
        }
    }

    @Test("Chaque app vend son propre produit")
    func productPerPlatform() {
        #if os(tvOS)
        #expect(ProProduct.current == ProProduct.tvOSProductID)
        #else
        #expect(ProProduct.current == ProProduct.iOSProductID)
        #endif
        #expect(ProProduct.iOSProductID != ProProduct.tvOSProductID)
    }
}

// MARK: - Store

/// A StoreKit stand-in. `entitlement` is what `Transaction.currentEntitlements`
/// (and `Transaction.latest`) would answer; `pushUpdate()` plays
/// `Transaction.updates`; `holdNextEntitlementRead()` parks the next read
/// until `releaseHeldRead(with:)` — a refresh caught mid-flight.
actor FakeProStoreClient: ProStoreClient {
    var productToReturn: ProductSnapshot? = ProductSnapshot(id: ProProduct.current, displayName: "JellyGlass Pro", displayPrice: "7,99 €")
    var purchaseResult: ProPurchaseOutcome = .cancelled
    var purchaseError: (any Error)?
    var entitlement: ProEntitlementState = .absent
    var syncError: (any Error)?
    private(set) var syncCount = 0
    private var holdNext = false
    private var held: CheckedContinuation<ProEntitlementState, Never>?
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func set(purchase: ProPurchaseOutcome) { purchaseResult = purchase }
    func set(purchaseError: (any Error)?) { self.purchaseError = purchaseError }
    func set(entitlement: ProEntitlementState) { self.entitlement = entitlement }
    func set(product: ProductSnapshot?) { productToReturn = product }
    func set(syncError: (any Error)?) { self.syncError = syncError }
    func holdNextEntitlementRead() { holdNext = true }
    var isHoldingARead: Bool { held != nil }
    func releaseHeldRead(with answer: ProEntitlementState) {
        held?.resume(returning: answer)
        held = nil
    }

    func product(id: String) async throws -> ProductSnapshot? { productToReturn }

    func purchase(id: String) async throws -> ProPurchaseOutcome {
        if let purchaseError { throw purchaseError }
        if case .purchased(let bought) = purchaseResult { entitlement = .entitled(bought) }
        return purchaseResult
    }

    func entitlementState(productID: String) async -> ProEntitlementState {
        if holdNext {
            holdNext = false
            return await withCheckedContinuation { held = $0 }
        }
        return entitlement
    }

    func sync() async throws {
        syncCount += 1
        if let syncError { throw syncError }
    }

    nonisolated func updates() -> AsyncStream<Void> { stream }

    nonisolated func pushUpdate() { continuation.yield() }
}

@MainActor
@Suite("Magasin Pro")
struct ProStoreTests {

    private func makeStore(_ client: FakeProStoreClient) -> (ProStore, EntitlementStore) {
        let entitlements = EntitlementStore(defaults: .isolatedForTesting(), cloud: InMemoryCloudKeyValueStore())
        return (ProStore(client: client, entitlements: entitlements, ownBundleID: iosBundle), entitlements)
    }

    @Test("Le prix vient du produit StoreKit ; produit introuvable = indisponible")
    func productLoading() async {
        let client = FakeProStoreClient()
        let (store, _) = makeStore(client)
        await store.loadProduct()
        #expect(store.product?.displayPrice == "7,99 €")
        #expect(store.productState == .loaded)

        await client.set(product: nil)
        await store.loadProduct()
        #expect(store.productState == .unavailable)
    }

    @Test("Achat réussi : Pro enregistré, miroir écrit, issue publiée pour l'alerte")
    func purchaseSucceeds() async {
        let client = FakeProStoreClient()
        await client.set(purchase: .purchased(fact(product: ProProduct.current)))
        let (store, entitlements) = makeStore(client)
        let outcome = await store.purchase()
        #expect(outcome == .purchased(fact(product: ProProduct.current)))
        #expect(entitlements.state == .pro(.purchase))
        #expect(entitlements.cloudRecord?.writerBundleID == iosBundle)
        #expect(store.isPurchasing == false)
        #expect(store.lastOutcome == outcome)
        store.acknowledgeOutcome()
        #expect(store.lastOutcome == nil)
    }

    @Test("Annulation : rien ne change, aucun message")
    func purchaseCancelled() async {
        let client = FakeProStoreClient()
        let (store, entitlements) = makeStore(client)
        #expect(await store.purchase() == .cancelled)
        #expect(entitlements.state == .free)
        #expect(store.isPending == false)
        #expect(store.lastOutcome == nil)
    }

    @Test("Une erreur de StoreKit pendant l'achat est un échec, jamais un Pro")
    func purchaseThrows() async {
        struct Boom: Error {}
        let client = FakeProStoreClient()
        await client.set(purchaseError: Boom())
        let (store, entitlements) = makeStore(client)
        #expect(await store.purchase() == .failed)
        #expect(entitlements.state == .free)
        #expect(store.lastOutcome == .failed)
    }

    @Test("En attente (Demander à acheter) : l'état reste, puis l'approbation débloque par les mises à jour")
    func pendingThenApproved() async {
        let client = FakeProStoreClient()
        await client.set(purchase: .pending)
        let (store, entitlements) = makeStore(client)
        store.start()
        #expect(await store.purchase() == .pending)
        #expect(store.isPending)

        await client.set(entitlement: .entitled(fact(product: ProProduct.current)))
        client.pushUpdate()

        #expect(await eventually { entitlements.state.isPro })
        #expect(store.isPending == false)
    }

    @Test("Un remboursement arrivé par les mises à jour repasse en gratuit")
    func refundThroughUpdates() async {
        let client = FakeProStoreClient()
        await client.set(entitlement: .entitled(fact(product: ProProduct.current)))
        let (store, entitlements) = makeStore(client)
        store.start()
        #expect(await eventually { entitlements.state.isPro })

        await client.set(entitlement: .revoked)
        client.pushUpdate()

        #expect(await eventually { entitlements.state == .free })
    }

    @Test("Une lecture partie AVANT l'achat ne défait pas l'achat en revenant après")
    func staleRefreshCannotUndoPurchase() async {
        let client = FakeProStoreClient()
        await client.set(purchase: .purchased(fact(product: ProProduct.current)))
        let (store, entitlements) = makeStore(client)

        await client.holdNextEntitlementRead()
        let staleRefresh = Task { await store.refresh() }
        #expect(await eventually { await client.isHoldingARead })

        #expect(await store.purchase() == .purchased(fact(product: ProProduct.current)))
        #expect(entitlements.state == .pro(.purchase))

        // The refresh started before the purchase now answers « revoked ».
        await client.releaseHeldRead(with: .revoked)
        await staleRefresh.value

        #expect(entitlements.state == .pro(.purchase))
    }

    @Test("Restaurer : trouvé, rien trouvé, annulé, échec")
    func restore() async {
        struct Boom: Error {}
        let client = FakeProStoreClient()
        let (store, entitlements) = makeStore(client)
        #expect(await store.restore() == .nothingFound)
        #expect(await client.syncCount == 1)

        await client.set(entitlement: .entitled(fact(product: ProProduct.current)))
        #expect(await store.restore() == .restored)
        #expect(entitlements.state.isPro)

        await client.set(syncError: Boom())
        #expect(await store.restore() == .failed)
    }
}

// MARK: - Catalogue

@Suite("Catalogue Pro")
struct ProFeatureCatalogueTests {

    @Test("Les comptes mémorisés sont la première fonction verrouillée")
    func accountsGated() {
        #expect(ProFeatureCatalogue.features.first?.id == .memorizedAccounts)
        #expect(ProFeatureCatalogue.features.first?.isGated == true)
        #expect(Set(ProFeatureCatalogue.features.map(\.id)).count == ProFeatureCatalogue.features.count)
    }

    /// Spec 2026-10-22: « Regarder ensemble » (créer), le menu personnalisé et
    /// les couleurs d'accent sont GRATUITS ; les icônes de l'app entrent.
    @Test("Le périmètre Pro arrêté le 2026-10-22, dans l'ordre de la page")
    func scope() {
        #expect(ProFeatureCatalogue.features.map(\.id) == [
            .memorizedAccounts, .administration, .playOn, .appIcons, .seasonalAllYear, .shortcuts,
        ])
        #expect(ProFeatureID.allCases.count == ProFeatureCatalogue.features.count)
    }

    /// `isGated` says a gate site really exists. Lot B gates the
    /// administration, « Lire sur… » and Siri / Raccourcis, lot C Halloween
    /// all year (the « Halloween » choice of Réglages → Apparence); the icons
    /// wait for their picker (none exists yet) — each flips here
    /// deliberately, together with its gate site.
    @Test("Les fonctions réellement verrouillées après le lot C")
    func gatedSet() {
        let gated = Set(ProFeatureCatalogue.features.filter(\.isGated).map(\.id))
        #expect(gated == [.memorizedAccounts, .administration, .playOn, .seasonalAllYear, .shortcuts])
    }

    @Test("Chaque fonction a son titre, son détail et son nom court, dans chaque langue")
    func keysExistInEveryLanguage() throws {
        for lang in AppLanguage.supported {
            let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang))
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            for feature in ProFeatureCatalogue.features {
                for key in [feature.titleKey, feature.detailKey, feature.shortKey,
                            feature.displayTitleKey(onTV: true), feature.displayDetailKey(onTV: true)] {
                    #expect(table[key] != nil, "\(lang): \(key)")
                }
            }
        }
    }

    /// Recette 2026-10-22: the Apple TV's Pro sheet for « Lire sur… » read
    /// « Choisissez un film sur l'iPhone… » — the TV sends too, so it gets
    /// its own copy; every other feature reads the same on both platforms.
    @Test("Sur Apple TV, « Lire sur… » parle depuis la télé, pas depuis l'iPhone")
    func playOnSpeaksFromTheTV() throws {
        let playOn = try #require(ProFeatureCatalogue.feature(.playOn))
        #expect(playOn.displayTitleKey(onTV: false) == "pro.feature.playOn.title")
        #expect(playOn.displayDetailKey(onTV: false) == "pro.feature.playOn.detail")
        #expect(playOn.displayTitleKey(onTV: true) == "pro.feature.playOn.title.tv")
        #expect(playOn.displayDetailKey(onTV: true) == "pro.feature.playOn.detail.tv")
        for feature in ProFeatureCatalogue.features where feature.id != .playOn {
            #expect(feature.displayTitleKey(onTV: true) == feature.titleKey)
            #expect(feature.displayDetailKey(onTV: true) == feature.detailKey)
        }
    }

    /// RULE R8 of the spec: setting the production pivot ends the free period,
    /// so every feature the Pro page sells must be locked by then.
    @Test("Pas de pivot de production tant qu'une fonction vendue reste libre")
    func noLaunchBeforeEveryFeatureIsGated() {
        let production = EarlyAdopterConfiguration.production
        let pivotSet = production.pivotBuild != nil || production.pivotDate != nil
        #expect(!pivotSet || ProFeatureCatalogue.features.allSatisfy(\.isGated))
    }
}
