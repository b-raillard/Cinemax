import Foundation

/// The two JellyGlass Pro products — one non-consumable per app, the iOS and
/// tvOS apps having different bundle ids (so no universal purchase: the other
/// platform unlocks through the iCloud mirror). Family Sharing on both. Created
/// in App Store Connect by hand; the price is read from StoreKit, never written
/// here (spec R2).
nonisolated enum ProProduct {
    static let iOSProductID = "com.cinemax.ios.pro"
    static let tvOSProductID = "com.cinemax.tvos.pro"

    /// The product THIS app sells.
    static var current: String {
        #if os(tvOS)
        tvOSProductID
        #else
        iOSProductID
        #endif
    }
}

/// What the Pro page shows of the StoreKit product. `displayPrice` is the
/// App Store's own string — the user's currency and taxes.
nonisolated struct ProductSnapshot: Sendable, Equatable {
    let id: String
    let displayName: String
    let displayPrice: String
}

/// A VERIFIED, non-revoked StoreKit entitlement to the Pro — bought on this
/// account or shared by the family organiser. Plain values, so the policy and
/// the tests never touch StoreKit (a `Transaction` cannot be built by hand).
nonisolated struct ProEntitlementFact: Sendable, Equatable {
    let productID: String
    let originalTransactionID: String
    let purchaseDate: Date
    /// The transaction's JWS, carried into the mirrored record for a reader
    /// that wants to verify it.
    var signedTransaction: String?
    let isFamilyShared: Bool

    /// The record `EntitlementStore` keeps and mirrors.
    func record(writerBundleID: String) -> CloudEntitlementRecord {
        CloudEntitlementRecord(
            productID: productID,
            originalTransactionID: originalTransactionID,
            purchaseDate: purchaseDate,
            signedTransaction: signedTransaction,
            writerBundleID: writerBundleID
        )
    }
}

/// How a purchase ended (spec R6).
nonisolated enum ProPurchaseOutcome: Sendable, Equatable {
    /// Verified and finished.
    case purchased(ProEntitlementFact)
    /// « Demander à acheter »: waiting for the family organiser. The approval
    /// arrives later through `Transaction.updates`.
    case pending
    /// The user closed the system sheet — no message.
    case cancelled
    /// Anything else, an unverified transaction included. Nothing was charged.
    case failed
}

nonisolated enum ProRestoreOutcome: Sendable, Equatable {
    case restored
    case nothingFound
    /// The user dismissed the Apple-account sign-in `AppStore.sync()` raised.
    case cancelled
    case failed
}

/// The pure reconciliation of StoreKit's answer with what the app recorded
/// (spec R3, R4). StoreKit's `currentEntitlements` is the truth on the
/// platform the purchase was made on; the local record and the iCloud mirror
/// follow it.
nonisolated enum ProPurchasePolicy {
    enum Action: Sendable, Equatable {
        /// Write the record locally and to the mirror (`recordPurchase`).
        case record(CloudEntitlementRecord)
        /// StoreKit no longer grants it: `revokeOwnPurchase`.
        case revoke
        case none
    }

    static func reconcile(
        entitlement: ProEntitlementFact?,
        localRecord: CloudEntitlementRecord?,
        cloudRecord: CloudEntitlementRecord?,
        ownBundleID: String
    ) -> Action {
        guard let entitlement else {
            // Only a record THIS app wrote is this app's to withdraw.
            if let localRecord, localRecord.writerBundleID == ownBundleID { return .revoke }
            return .none
        }
        let candidate = entitlement.record(writerBundleID: ownBundleID)
        let localUpToDate = localRecord.map { sameTransaction($0, candidate) } ?? false
        // The mirror only has to carry SOME purchase: the other platform's own
        // record serves just as well, and overwriting it would churn iCloud on
        // every launch of both apps. Rewritten when absent (a refund on the
        // other platform removed it) or when it is ours but stale.
        let mirrorUpToDate: Bool = {
            guard let cloudRecord else { return false }
            if cloudRecord.writerBundleID != ownBundleID { return true }
            return sameTransaction(cloudRecord, candidate)
        }()
        return localUpToDate && mirrorUpToDate ? .none : .record(candidate)
    }

    /// Same purchase, whatever JWS StoreKit re-signed it with.
    private static func sameTransaction(_ lhs: CloudEntitlementRecord, _ rhs: CloudEntitlementRecord) -> Bool {
        lhs.productID == rhs.productID
            && lhs.originalTransactionID == rhs.originalTransactionID
            && lhs.writerBundleID == rhs.writerBundleID
    }
}
