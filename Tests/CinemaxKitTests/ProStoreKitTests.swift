import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Cinemax

private final class ProStoreKitFixtureToken {}

/// The REAL StoreKit 2 adapter (`StoreKitProClient`), served by Xcode's local
/// StoreKit testing on `Fixtures/JellyGlassPro.storekit` — the same file the
/// app schemes run with from Xcode. Proves the product lookup, the
/// verification, and the two transitions that matter: bought → Pro, refunded
/// → free (spec R3, R4).
@Suite("Achat Pro — StoreKit réel (local)", .serialized)
@MainActor
struct ProStoreKitTests {
    /// Same discipline as `EarlyAdopterStoreKitTests`: a simulated error
    /// outlives its session, so it is cleared — AWAITED — first; and the
    /// previous run's transactions are wiped so every test starts unbought.
    private func session() async throws -> SKTestSession {
        let url = try #require(
            Bundle(for: ProStoreKitFixtureToken.self)
                .url(forResource: "JellyGlassPro", withExtension: "storekit", subdirectory: "Fixtures"),
            "Fixtures/JellyGlassPro.storekit missing from the test bundle"
        )
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        return session
    }

    @Test("Le produit de cette app se charge, avec le prix de l'App Store")
    func productLoads() async throws {
        let session = try await session()
        defer { _ = session }
        let product = try await StoreKitProClient().product(id: ProProduct.current)
        #expect(product?.id == ProProduct.current)
        #expect(product?.displayPrice.isEmpty == false)
    }

    @Test("Acheté → Pro sur cet appareil, SANS miroir (achat de test) ; remboursé → gratuit")
    func purchaseThenRefund() async throws {
        let session = try await session()
        let cloud = InMemoryCloudKeyValueStore()
        let entitlements = EntitlementStore(defaults: .isolatedForTesting(), cloud: cloud)
        let store = ProStore(client: StoreKitProClient(), entitlements: entitlements, ownBundleID: "com.cinemax.ios")

        let outcome = await store.purchase()
        guard case .purchased(let fact) = outcome else {
            Issue.record("Expected a verified purchase, got \(outcome)")
            return
        }
        #expect(fact.productID == ProProduct.current)
        #expect(fact.environment == .xcode)
        #expect(entitlements.state == .pro(.purchase))
        // A test purchase never reaches the user's real iCloud store.
        #expect(cloud.data(forKey: CloudEntitlementMirror.key) == nil)

        // A launch after the purchase: StoreKit's cache still grants it.
        await store.refresh()
        #expect(entitlements.state == .pro(.purchase))

        let transaction = try #require(session.allTransactions().first { $0.productIdentifier == ProProduct.current })
        try session.refundTransaction(identifier: transaction.identifier)
        // The refund reaches StoreKit's entitlement cache asynchronously
        // (measured: not yet on the very next read), so poll the reconcile.
        #expect(await eventually {
            await store.refresh()
            return entitlements.state == .free
        })
        #expect(cloud.data(forKey: CloudEntitlementMirror.key) == nil)
        // …and it reads as a PROVEN revocation, not a mere absence — the
        // distinction that decides whether the mirror goes (spec R4).
        #expect(await StoreKitProClient().entitlementState(productID: ProProduct.current) == .revoked)
    }

    @Test("Un échec de StoreKit est un échec, jamais un Pro")
    func purchaseFailure() async throws {
        let session = try await session()
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
        let entitlements = EntitlementStore(defaults: .isolatedForTesting(), cloud: InMemoryCloudKeyValueStore())
        let store = ProStore(client: StoreKitProClient(), entitlements: entitlements, ownBundleID: "com.cinemax.ios")

        #expect(await store.purchase() == .failed)
        #expect(entitlements.state == .free)
        try await session.setSimulatedError(nil, forAPI: .purchase)
    }
}
