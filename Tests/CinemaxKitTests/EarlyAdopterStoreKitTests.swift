import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Cinemax

private final class StoreKitFixtureToken {}

/// The REAL `AppTransaction.shared`, served by Xcode's local StoreKit testing
/// (`SKTestSession` on `Fixtures/EarlyAdopter.storekit`) — the one place the
/// StoreKit adapter itself runs. Local testing signs with Xcode's own
/// certificate, reports the `.xcode` environment, and offers no way to set
/// `originalAppVersion` (neither `SKTestSession` nor the `.storekit` file has
/// one): the production decision stays covered by the policy tests, this suite
/// proves the adapter, the verification and the failure path.
@Suite("Early adopter — real StoreKit (local testing)", .serialized)
@MainActor
struct EarlyAdopterStoreKitTests {
    /// The simulated error OUTLIVES the session (it sits in the simulator's
    /// StoreKit test state, across test runs): every test starts by clearing it.
    private func session() async throws -> SKTestSession {
        let url = try #require(
            Bundle(for: StoreKitFixtureToken.self)
                .url(forResource: "EarlyAdopter", withExtension: "storekit", subdirectory: "Fixtures"),
            "Fixtures/EarlyAdopter.storekit missing from the test bundle"
        )
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        try await session.setSimulatedError(nil, forAPI: .appTransaction)
        return session
    }

    /// Whatever local StoreKit answers, nobody becomes an early adopter: a
    /// verified answer is `.xcode` → non-production; an unverified one is
    /// refused. Both were seen on 2026-10-01 (Xcode 27.0): the first run found
    /// the « StoreKit Testing in Xcode » certificate EXPIRED (`-67818`) and got
    /// `.unverified(invalidCertificateChain)`; the next runs got a verified
    /// transaction whose `originalAppVersion` is the CURRENT build (`2.3.2`) —
    /// « 1.0 » is the sandbox's value, not Xcode's.
    @Test("Real local StoreKit never makes an early adopter, verified or not")
    func realTransactionNeverGrants() async throws {
        let session = try await session()
        defer { _ = session }
        let source = StoreKitAppTransactionSource()
        do {
            let snapshot = try await source.fetch()
            #expect(snapshot.environment == .xcode)
        } catch let error as VerificationResult<AppTransaction>.VerificationError {
            // Refused, as it must be — not a test failure.
            print("Local AppTransaction unverified and refused: \(error)")
        }

        let service = EarlyAdopterService(
            source: source,
            cache: StoreKitTestCache(nil),
            configuration: .init(pivotBuild: BuildNumber("3.0"), pivotDate: nil),
            defaults: .isolatedForTesting(),
            cloud: InMemoryCloudKeyValueStore()
        )
        await service.refreshIfNeeded(isOnline: true)
        #expect(service.status == .nonProduction || service.status == .unknown)
        #expect(!service.isEarlyAdopter)
    }

    @Test("A StoreKit failure keeps the cached status")
    func realFailureKeepsCache() async throws {
        let session = try await session()
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appTransaction)

        let cached = AppTransactionSnapshot(originalAppVersion: "2.3.2", originalPurchaseDate: Date(), environment: .production)
        let cache = StoreKitTestCache(EarlyAdopterCacheRecord(transaction: cached, fetchedAt: Date()))
        let service = EarlyAdopterService(
            cache: cache,
            configuration: .init(pivotBuild: BuildNumber("3.0"), pivotDate: nil),
            defaults: .isolatedForTesting(),
            cloud: InMemoryCloudKeyValueStore()
        )
        #expect(service.status == .earlyAdopter)
        #expect(await service.evaluate() == false)
        #expect(service.status == .earlyAdopter)
        #expect(cache.record?.transaction == cached)
        try await session.setSimulatedError(nil, forAPI: .appTransaction)
    }
}

@MainActor
private final class StoreKitTestCache: EarlyAdopterCache {
    var record: EarlyAdopterCacheRecord?
    init(_ record: EarlyAdopterCacheRecord?) { self.record = record }
    func load() -> EarlyAdopterCacheRecord? { record }
    func save(_ record: EarlyAdopterCacheRecord) { self.record = record }
}
