import Foundation
import Observation
import OSLog
import StoreKit

/// The StoreKit slice the Pro purchase needs — injectable, so the store is
/// tested on a stand-in (`FakeProStoreClient`) and never on the real App Store.
protocol ProStoreClient: Sendable {
    /// `nil` when the App Store does not know the product (not created in App
    /// Store Connect, Paid Apps agreement inactive).
    func product(id: String) async throws -> ProductSnapshot?
    /// Shows the system purchase sheet. A `.purchased` outcome is VERIFIED and
    /// already finished.
    func purchase(id: String) async throws -> ProPurchaseOutcome
    /// What StoreKit's local cache says, positively: a verified, non-revoked
    /// entitlement (`Transaction.currentEntitlements`), else a proven
    /// revocation (`Transaction.latest` carries a `revocationDate`), else
    /// nothing either way. Answers offline.
    func entitlementState(productID: String) async -> ProEntitlementState
    /// `AppStore.sync()` — may ask for the Apple-account password, so only on
    /// the « Restaurer les achats » tap (spec R5).
    func sync() async throws
    /// One element per transaction StoreKit pushes (`Transaction.updates`): an
    /// « Ask to Buy » approval, a refund, a family-sharing change, a purchase
    /// made on another device. Each is finished before the element is sent.
    func updates() -> AsyncStream<Void>
}

/// The real client: StoreKit 2. Only VERIFIED transactions ever count (spec R5).
struct StoreKitProClient: ProStoreClient {
    private static let logger = Logger(subsystem: "com.cinemax", category: "ProStore")

    func product(id: String) async throws -> ProductSnapshot? {
        guard let product = try await Product.products(for: [id]).first else { return nil }
        return ProductSnapshot(id: product.id, displayName: product.displayName, displayPrice: product.displayPrice)
    }

    func purchase(id: String) async throws -> ProPurchaseOutcome {
        guard let product = try await Product.products(for: [id]).first else { return .failed }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                Self.logger.error("Pro purchase returned an UNVERIFIED transaction — ignored")
                return .failed
            }
            await transaction.finish()
            return .purchased(Self.fact(transaction, jws: verification.jwsRepresentation))
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .failed
        }
    }

    func entitlementState(productID: String) async -> ProEntitlementState {
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification,
                  transaction.productID == productID,
                  transaction.revocationDate == nil else { continue }
            return .entitled(Self.fact(transaction, jws: verification.jwsRepresentation))
        }
        if case .verified(let latest)? = await Transaction.latest(for: productID),
           latest.revocationDate != nil {
            return .revoked
        }
        return .absent
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    func updates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await verification in Transaction.updates {
                    if case .verified(let transaction) = verification {
                        await transaction.finish()
                    } else {
                        Self.logger.error("Transaction update UNVERIFIED — ignored")
                    }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func fact(_ transaction: Transaction, jws: String) -> ProEntitlementFact {
        ProEntitlementFact(
            productID: transaction.productID,
            originalTransactionID: String(transaction.originalID),
            purchaseDate: transaction.originalPurchaseDate,
            signedTransaction: jws,
            isFamilyShared: transaction.ownershipType == .familyShared,
            environment: AppTransactionSnapshot.Environment(transaction.environment)
        )
    }
}

/// The Pro purchase, for the whole app. A process singleton hosted by
/// `AppNavigation` (`sharedProStore`) and injected through the environment.
///
/// Writes its verdicts into `EntitlementStore` (`recordPurchase` /
/// `revokeOwnPurchase`), which stays the one place the app reads Free / Pro
/// from. RULE: playback never reads this store (see the area file).
@MainActor @Observable
final class ProStore {
    enum ProductState: Sendable, Equatable {
        case idle, loading, loaded, unavailable
    }

    private(set) var product: ProductSnapshot?
    private(set) var productState: ProductState = .idle
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    /// « Demander à acheter » sent, not answered yet: the Pro page shows it
    /// instead of the purchase button. In memory only — after a relaunch the
    /// approval still arrives through `Transaction.updates`.
    private(set) var isPending = false
    /// The last purchase's outcome worth telling (purchased / pending /
    /// failed), until `acknowledgeOutcome()`. Held HERE, not in the view that
    /// raised it: a verified purchase flips the tier, which removes the
    /// purchase button — an alert owned by it went down before « Merci ! »
    /// was read. Shown by `proPurchaseResultAlert`, on a container that
    /// survives the flip.
    private(set) var lastOutcome: ProPurchaseOutcome?

    @ObservationIgnored private let client: any ProStoreClient
    @ObservationIgnored private let entitlements: EntitlementStore
    @ObservationIgnored private let ownBundleID: String
    @ObservationIgnored private let productID: String
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Bumped by every applied answer. A refresh compares it across its
    /// StoreKit read and drops an answer overtaken by a newer one — a read
    /// started before a purchase must not revoke it on its way back.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let logger = Logger(subsystem: "com.cinemax", category: "ProStore")

    init(
        client: any ProStoreClient = StoreKitProClient(),
        entitlements: EntitlementStore,
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "",
        productID: String = ProProduct.current
    ) {
        self.client = client
        self.entitlements = entitlements
        self.ownBundleID = ownBundleID
        self.productID = productID
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Launch: listen to `Transaction.updates` for the life of the process
    /// (spec R5 — an approval or a refund arriving while the app was closed is
    /// delivered here), then reconcile once. Idempotent.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self, client] in
            for await _ in client.updates() {
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    /// Re-reads StoreKit's current entitlements and aligns the records with
    /// them. Launch, every return to the foreground, every pushed update.
    func refresh() async {
        let started = generation
        let state = await client.entitlementState(productID: productID)
        guard started == generation else { return }
        apply(state)
    }

    /// The Pro page's price. A failure or an unknown product reads as
    /// « Prix indisponible » — never a price written by hand (spec R6).
    func loadProduct() async {
        if product == nil { productState = .loading }
        do {
            if let fresh = try await client.product(id: productID) {
                if fresh != product { product = fresh }
                productState = .loaded
            } else {
                productState = .unavailable
            }
        } catch {
            logger.error("Pro product lookup failed: \(error.localizedDescription, privacy: .public)")
            productState = product == nil ? .unavailable : .loaded
        }
    }

    @discardableResult
    func purchase() async -> ProPurchaseOutcome {
        guard !isPurchasing else { return .cancelled }
        isPurchasing = true
        defer { isPurchasing = false }
        let outcome: ProPurchaseOutcome
        do {
            outcome = try await client.purchase(id: productID)
        } catch {
            logger.error("Pro purchase failed: \(error.localizedDescription, privacy: .public)")
            outcome = .failed
        }
        switch outcome {
        case .purchased(let fact):
            apply(.entitled(fact))
        case .pending:
            isPending = true
        case .cancelled, .failed:
            break
        }
        // Cancelled = the user closed the system sheet: nothing to say (R6).
        if outcome != .cancelled { lastOutcome = outcome }
        return outcome
    }

    /// « Restaurer les achats » — the ONE place `AppStore.sync()` is called.
    @discardableResult
    func restore() async -> ProRestoreOutcome {
        guard !isRestoring else { return .cancelled }
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await client.sync()
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            logger.error("Restore failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        let state = await client.entitlementState(productID: productID)
        apply(state)
        if case .entitled = state { return .restored }
        return .nothingFound
    }

    /// The result alert was read.
    func acknowledgeOutcome() {
        if lastOutcome != nil { lastOutcome = nil }
    }

    private func apply(_ state: ProEntitlementState) {
        generation += 1
        if case .entitled = state, isPending { isPending = false }
        switch ProPurchasePolicy.reconcile(
            entitlement: state,
            localRecord: entitlements.localRecord,
            cloudRecord: entitlements.cloudRecord,
            ownBundleID: ownBundleID
        ) {
        case .record(let record, let mirror):
            entitlements.recordPurchase(record, mirror: mirror)
        case .revoke:
            logger.info("Pro revoked by StoreKit — local record and own mirror withdrawn")
            entitlements.revokeOwnPurchase(ownBundleID: ownBundleID)
        case .clearLocal:
            logger.info("No Pro entitlement in StoreKit — local record withdrawn, mirror kept")
            entitlements.clearLocal()
        case .none:
            break
        }
    }
}
