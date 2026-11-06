import Foundation

/// The pure reconciliation of StoreKit's answer with what the app recorded
/// (spec R3, R4). StoreKit is the truth on the platform the purchase was made
/// on; the local record and the iCloud mirror follow it — but only on
/// POSITIVE evidence:
/// - an entitlement ⇒ record it (and mirror it if it was a real purchase);
/// - a PROVEN revocation ⇒ withdraw the local record AND this app's mirror,
///   even with no local record left (refunded, deleted, reinstalled);
/// - a mere absence ⇒ withdraw the local record only. The mirror stays: the
///   App Store may simply be signed out, or not synced yet on a restored
///   device, and the other platform must not lose its Pro over that. Accepted
///   cost: a signed-out device stays Pro through its own mirror.
nonisolated enum ProPurchasePolicy {
    enum Action: Sendable, Equatable {
        /// Write the record locally, and to the mirror when `mirror`.
        case record(CloudEntitlementRecord, mirror: Bool)
        /// `revokeOwnPurchase`: local record + this app's mirror record.
        case revoke
        /// `clearLocal`: the local record only.
        case clearLocal
        case none
    }

    static func reconcile(
        entitlement: ProEntitlementState,
        localRecord: CloudEntitlementRecord?,
        cloudRecord: CloudEntitlementRecord?,
        ownBundleID: String
    ) -> Action {
        let ownLocal = localRecord.map { $0.writerBundleID == ownBundleID } ?? false
        switch entitlement {
        case .revoked:
            let ownMirror = cloudRecord.map { $0.writerBundleID == ownBundleID } ?? false
            return ownLocal || ownMirror ? .revoke : .none
        case .absent:
            return ownLocal ? .clearLocal : .none
        case .entitled(let fact):
            let candidate = fact.record(writerBundleID: ownBundleID)
            let localUpToDate = localRecord.map { sameTransaction($0, candidate) } ?? false
            // A test purchase (sandbox, TestFlight, Xcode) never reaches the
            // iCloud key-value store, which has no test / production split.
            guard candidate.isProduction else {
                return localUpToDate ? .none : .record(candidate, mirror: false)
            }
            // The mirror only has to carry SOME purchase: the other platform's
            // own record serves just as well, and overwriting it would churn
            // iCloud on every launch of both apps. Rewritten when absent (a
            // refund on the other platform removed it) or when it is ours but
            // stale.
            let mirrorUpToDate: Bool = {
                guard let cloudRecord else { return false }
                if cloudRecord.writerBundleID != ownBundleID { return true }
                return sameTransaction(cloudRecord, candidate)
            }()
            return localUpToDate && mirrorUpToDate ? .none : .record(candidate, mirror: true)
        }
    }

    /// Same purchase, whatever JWS StoreKit re-signed it with.
    private static func sameTransaction(_ lhs: CloudEntitlementRecord, _ rhs: CloudEntitlementRecord) -> Bool {
        lhs.productID == rhs.productID
            && lhs.originalTransactionID == rhs.originalTransactionID
            && lhs.writerBundleID == rhs.writerBundleID
    }
}
