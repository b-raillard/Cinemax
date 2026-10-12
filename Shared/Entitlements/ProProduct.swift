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
    /// Where it was bought: only a `.production` purchase is ever mirrored.
    let environment: AppTransactionSnapshot.Environment

    /// The record `EntitlementStore` keeps (and, if production, mirrors).
    func record(writerBundleID: String) -> CloudEntitlementRecord {
        CloudEntitlementRecord(
            productID: productID,
            originalTransactionID: originalTransactionID,
            purchaseDate: purchaseDate,
            signedTransaction: signedTransaction,
            writerBundleID: writerBundleID,
            environment: environment.rawValue
        )
    }
}

/// What StoreKit says about this app's Pro, POSITIVELY — the policy never
/// reads a refund into a mere absence.
nonisolated enum ProEntitlementState: Sendable, Equatable {
    /// `Transaction.currentEntitlements` holds a verified, non-revoked one.
    case entitled(ProEntitlementFact)
    /// No current entitlement, and the latest verified transaction carries a
    /// `revocationDate`: refunded, or family sharing withdrawn.
    case revoked
    /// Nothing either way: never bought — or StoreKit cannot tell yet (App
    /// Store signed out, a restored device not synced, another account).
    case absent
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
