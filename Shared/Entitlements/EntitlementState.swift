import Foundation

/// Where a Pro entitlement comes from. Only ever shown in Settings → Debug:
/// nothing in the app behaves differently by source.
enum EntitlementSource: Sendable, Equatable {
    /// A purchase recorded on THIS device (the platform it was bought on).
    case purchase
    /// A purchase made on the OTHER platform, read from the shared iCloud
    /// key-value store (the iOS and tvOS apps have different bundle ids, so
    /// StoreKit cannot share a non-consumable between them).
    case cloudMirror
    /// Settings → Debug → « Simuler Pro ». DEBUG builds only.
    case debugOverride
}

/// Free or Pro — resolved by `EntitlementPolicy`, held by `EntitlementStore`.
///
/// A FOUNDATION only: nothing reads `isPro` to hide a feature yet, and playback
/// never will (see `Shared/Entitlements/CLAUDE.md`).
enum EntitlementState: Sendable, Equatable {
    case free
    case pro(EntitlementSource)

    var isPro: Bool {
        if case .pro = self { return true }
        return false
    }

    var source: EntitlementSource? {
        if case .pro(let source) = self { return source }
        return nil
    }
}
