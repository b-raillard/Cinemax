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
/// Local StoreKit testing is NOT active in the FIRST test process a simulator
/// ever runs: StoreKit answers from the real Sandbox (`noAccount`, no product),
/// and waiting does not help (measured 2026-11-06: still Sandbox after 30 s);
/// only the next process gets the `.storekit` file. Every CI runner is a fresh
/// simulator, so there the real-StoreKit tests record a KNOWN, intermittent
/// issue; on a simulator that has run the suite once, they pass in full.
/// ONLY that cause is tolerated: the precondition measures, before the body,
/// whether local StoreKit is serving this process (`localStoreKitIsInactive`).
/// When it is, any failure of the body is a real failure (audit CI-06: the
/// unconditional wrapper turned every `#expect` into a known issue).
@MainActor
func localStoreKitColdStartTolerant(_ body: () async throws -> Void) async throws {
    try await withKnownIssue("Local StoreKit inactive on a simulator's first test run", isIntermittent: true) {
        try await body()
    } when: {
        await localStoreKitIsInactive()
    }
}

/// Measured once per process (the cold start is a property of the process —
/// waiting does not end it): with a local `SKTestSession` open, the app
/// transaction comes from Xcode's local testing (`.xcode`) — verified or not,
/// its certificate may be expired — when local StoreKit is active, and the
/// real Sandbox answers (`noAccount` → throws, or a non-Xcode environment)
/// when it is not. Keyed on the ENVIRONMENT, never on what a test asserts
/// (the product lookup, the purchase).
@MainActor private var localStoreKitInactiveProbe: Bool?

/// The header and payload of a JWS StoreKit emitted, UNVERIFIED — to check
/// that its shape is the one `AppStoreSignature` reads.
func storeKitJWSFields(_ jws: String?) -> (header: [String: Any], payload: [String: Any])? {
    guard let parts = jws?.split(separator: ".", omittingEmptySubsequences: false), parts.count == 3 else { return nil }
    func object(_ part: Substring) -> [String: Any]? {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    guard let header = object(parts[0]), let payload = object(parts[1]) else { return nil }
    return (header, payload)
}

@MainActor
private func localStoreKitIsInactive() async -> Bool {
    if let measured = localStoreKitInactiveProbe { return measured }
    var inactive = true
    if let url = Bundle(for: ProStoreKitFixtureToken.self)
        .url(forResource: "JellyGlassPro", withExtension: "storekit", subdirectory: "Fixtures"),
       let session = try? SKTestSession(contentsOf: url) {
        session.disableDialogs = true
        // A simulated error outlives its session (area RULE): a leftover one
        // would read as the cold start and make the whole process tolerant.
        try? await session.setSimulatedError(nil, forAPI: .appTransaction)
        if let result = try? await AppTransaction.shared {
            inactive = result.unsafePayloadValue.environment != .xcode
        }
    }
    localStoreKitInactiveProbe = inactive
    return inactive
}

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
        try await localStoreKitColdStartTolerant {
            let session = try await session()
            defer { _ = session }
            let product = try await StoreKitProClient().product(id: ProProduct.current)
            #expect(product?.id == ProProduct.current)
            #expect(product?.displayPrice.isEmpty == false)
        }
    }

    @Test("Acheté → Pro sur cet appareil, SANS miroir (achat de test) ; remboursé → gratuit")
    func purchaseThenRefund() async throws {
        try await localStoreKitColdStartTolerant {
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
            // The JWS StoreKit really emits carries what `AppStoreSignature`
            // reads (audit SEC-02 — its own fixtures are hand-written).
            let fields = try #require(storeKitJWSFields(fact.signedTransaction))
            #expect(fields.header["alg"] as? String == "ES256")
            #expect(fields.payload["signedDate"] is NSNumber)
            let purchase = try JSONDecoder().decode(SignedPurchasePayload.self, from: JSONSerialization.data(withJSONObject: fields.payload))
            #expect(purchase.productId == ProProduct.current)
            #expect(purchase.environment == "Xcode")
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
