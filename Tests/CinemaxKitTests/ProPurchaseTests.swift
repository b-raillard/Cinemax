import Foundation
import Testing
@testable import Cinemax

private let iosBundle = "com.cinemax.ios"
private let tvBundle = "com.cinemax.tvos"

private func fact(
    product: String = ProProduct.iOSProductID,
    transaction: String = "2000000111",
    familyShared: Bool = false
) -> ProEntitlementFact {
    ProEntitlementFact(
        productID: product,
        originalTransactionID: transaction,
        purchaseDate: Date(timeIntervalSinceReferenceDate: 812_000_000),
        signedTransaction: "jws.\(transaction)",
        isFamilyShared: familyShared
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
}

// MARK: - Reconciliation policy

@Suite("Politique d'achat Pro")
struct ProPurchasePolicyTests {

    @Test("Un droit vérifié jamais enregistré s'enregistre (local + miroir)")
    func recordsNewEntitlement() {
        let action = ProPurchasePolicy.reconcile(
            entitlement: fact(), localRecord: nil, cloudRecord: nil, ownBundleID: iosBundle
        )
        #expect(action == .record(record(writer: iosBundle)))
    }

    @Test("Un droit reçu par le Partage familial débloque comme un achat")
    func familySharedRecords() {
        let shared = fact(familyShared: true)
        let action = ProPurchasePolicy.reconcile(
            entitlement: shared, localRecord: nil, cloudRecord: nil, ownBundleID: iosBundle
        )
        #expect(action == .record(shared.record(writerBundleID: iosBundle)))
    }

    @Test("Déjà enregistré et miroité : rien à écrire")
    func alreadyRecorded() {
        let mine = record(writer: iosBundle)
        let action = ProPurchasePolicy.reconcile(
            entitlement: fact(), localRecord: mine, cloudRecord: mine, ownBundleID: iosBundle
        )
        #expect(action == .none)
    }

    @Test("Un JWS ré-émis pour la même transaction ne réécrit rien")
    func sameTransactionNewJWSIgnored() {
        let mine = record(writer: iosBundle)
        var refreshed = fact()
        refreshed.signedTransaction = "jws.resigned"
        let action = ProPurchasePolicy.reconcile(
            entitlement: refreshed, localRecord: mine, cloudRecord: mine, ownBundleID: iosBundle
        )
        #expect(action == .none)
    }

    @Test("Miroir effacé (remboursement sur l'autre appareil) : on le réécrit")
    func rewritesMissingMirror() {
        let mine = record(writer: iosBundle)
        let action = ProPurchasePolicy.reconcile(
            entitlement: fact(), localRecord: mine, cloudRecord: nil, ownBundleID: iosBundle
        )
        #expect(action == .record(mine))
    }

    @Test("Le miroir de l'autre plateforme suffit à l'autre : on ne l'écrase pas pour rien")
    func keepsOtherPlatformMirror() {
        let mine = record(writer: iosBundle)
        let theirs = record(writer: tvBundle, transaction: "tv")
        let action = ProPurchasePolicy.reconcile(
            entitlement: fact(), localRecord: mine, cloudRecord: theirs, ownBundleID: iosBundle
        )
        #expect(action == .none)
    }

    @Test("Plus aucun droit et un enregistrement de CETTE app : retrait (remboursement, départ du groupe)")
    func revokesWhenEntitlementGone() {
        let action = ProPurchasePolicy.reconcile(
            entitlement: nil, localRecord: record(writer: iosBundle), cloudRecord: nil, ownBundleID: iosBundle
        )
        #expect(action == .revoke)
    }

    @Test("Plus aucun droit, rien d'enregistré ici : rien à faire (le miroir de l'autre reste)")
    func nothingToRevoke() {
        let action = ProPurchasePolicy.reconcile(
            entitlement: nil, localRecord: nil, cloudRecord: record(writer: tvBundle), ownBundleID: iosBundle
        )
        #expect(action == .none)
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
/// would hold; `pushUpdate()` plays `Transaction.updates`.
actor FakeProStoreClient: ProStoreClient {
    var productToReturn: ProductSnapshot? = ProductSnapshot(id: ProProduct.current, displayName: "JellyGlass Pro", displayPrice: "7,99 €")
    var purchaseResult: ProPurchaseOutcome = .cancelled
    var entitlement: ProEntitlementFact?
    var syncError: (any Error)?
    private(set) var syncCount = 0
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func set(purchase: ProPurchaseOutcome) { purchaseResult = purchase }
    func set(entitlement: ProEntitlementFact?) { self.entitlement = entitlement }
    func set(product: ProductSnapshot?) { productToReturn = product }
    func set(syncError: (any Error)?) { self.syncError = syncError }

    func product(id: String) async throws -> ProductSnapshot? { productToReturn }

    func purchase(id: String) async throws -> ProPurchaseOutcome {
        if case .purchased(let bought) = purchaseResult { entitlement = bought }
        return purchaseResult
    }

    func currentEntitlement(productID: String) async -> ProEntitlementFact? { entitlement }

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

    @Test("Achat réussi : Pro enregistré, miroir écrit")
    func purchaseSucceeds() async {
        let client = FakeProStoreClient()
        await client.set(purchase: .purchased(fact(product: ProProduct.current)))
        let (store, entitlements) = makeStore(client)
        let outcome = await store.purchase()
        #expect(outcome == .purchased(fact(product: ProProduct.current)))
        #expect(entitlements.state == .pro(.purchase))
        #expect(entitlements.cloudRecord?.writerBundleID == iosBundle)
        #expect(store.isPurchasing == false)
    }

    @Test("Annulation : rien ne change, aucun message")
    func purchaseCancelled() async {
        let client = FakeProStoreClient()
        let (store, entitlements) = makeStore(client)
        #expect(await store.purchase() == .cancelled)
        #expect(entitlements.state == .free)
        #expect(store.isPending == false)
    }

    @Test("En attente (Demander à acheter) : l'état reste, puis l'approbation débloque par les mises à jour")
    func pendingThenApproved() async {
        let client = FakeProStoreClient()
        await client.set(purchase: .pending)
        let (store, entitlements) = makeStore(client)
        store.start()
        #expect(await store.purchase() == .pending)
        #expect(store.isPending)

        await client.set(entitlement: fact(product: ProProduct.current))
        client.pushUpdate()

        #expect(await eventually { entitlements.state.isPro })
        #expect(store.isPending == false)
    }

    @Test("Un remboursement arrivé par les mises à jour repasse en gratuit")
    func refundThroughUpdates() async {
        let client = FakeProStoreClient()
        await client.set(entitlement: fact(product: ProProduct.current))
        let (store, entitlements) = makeStore(client)
        store.start()
        #expect(await eventually { entitlements.state.isPro })

        await client.set(entitlement: nil)
        client.pushUpdate()

        #expect(await eventually { entitlements.state == .free })
    }

    @Test("Restaurer : trouvé, rien trouvé, échec")
    func restore() async {
        struct Boom: Error {}
        let client = FakeProStoreClient()
        let (store, entitlements) = makeStore(client)
        #expect(await store.restore() == .nothingFound)
        #expect(await client.syncCount == 1)

        await client.set(entitlement: fact(product: ProProduct.current))
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

    /// RULE R8 of the spec: setting the production pivot ends the free period,
    /// so every feature the Pro page sells must be locked by then.
    @Test("Pas de pivot de production tant qu'une fonction vendue reste libre")
    func noLaunchBeforeEveryFeatureIsGated() {
        let production = EarlyAdopterConfiguration.production
        let pivotSet = production.pivotBuild != nil || production.pivotDate != nil
        #expect(!pivotSet || ProFeatureCatalogue.features.allSatisfy(\.isGated))
    }
}
