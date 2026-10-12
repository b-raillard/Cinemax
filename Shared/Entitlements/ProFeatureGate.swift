import Foundation

/// What a user gets: everything free, the Pro bought, or the Pro offered to a
/// founder (installed before the Pro launched).
enum ProTier: Sendable, Equatable {
    case free
    case pro
    case founder

    var unlocksProFeatures: Bool { self != .free }
}

/// Settings → Débogage « Palier simulé ». `.automatic` = the real answer;
/// `.launched` = the real answer AS IF the Pro had launched (no pre-launch
/// founder for everyone), which is what lets the local StoreKit file walk
/// free → purchase → Pro. Persisted under `SettingsKey.debugProTier`,
/// honoured in DEBUG builds only.
enum ProTierOverride: String, CaseIterable, Sendable {
    case automatic, launched, free, pro, founder

    var next: Self {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

/// The ONE decision « may this user use a Pro feature? » (multi-account first).
///
/// **Before the Pro launches, everybody passes** — and that is not a shortcut:
/// `EarlyAdopterService` only recognises a founder from a verified PRODUCTION
/// App Store transaction, so sandbox, TestFlight and Xcode all answer
/// « non-production » and a Debug build evaluates nothing. A plain
/// `isPro || isEarlyAdopter` would therefore lock the feature on every device
/// it can be tested on, until 3.0 ships. « Launched » is read from the very
/// constant that ends the free period: `EarlyAdopterConfiguration.production`
/// carrying a pivot. RULE: playback never asks this (see the Entitlements area
/// file).
///
/// **`PRO_PREVIEW`** (spec R1): a TestFlight preview of the purchase is built
/// with that compilation condition on the archive's command line, and answers
/// « launched » — never a runtime test of the environment, since App Review
/// runs in the same sandbox as TestFlight and would meet a paywall for a
/// feature production users get free. A preview build is never submitted.
enum ProFeatureGate {
    static var proLaunched: Bool {
        #if PRO_PREVIEW
        true
        #else
        EarlyAdopterConfiguration.production.pivotBuild != nil
            || EarlyAdopterConfiguration.production.pivotDate != nil
        #endif
    }

    static func tier(
        proLaunched: Bool,
        isPro: Bool,
        isEarlyAdopter: Bool,
        override: ProTierOverride
    ) -> ProTier {
        var launched = proLaunched
        switch override {
        case .free: return .free
        case .pro: return .pro
        case .founder: return .founder
        case .launched: launched = true
        case .automatic: break
        }
        if isPro { return .pro }
        if !launched || isEarlyAdopter { return .founder }
        return .free
    }
}

extension EntitlementStore {
    /// The tier for this user, the founder recognition coming from `earlyAdopter`.
    func proTier(earlyAdopter: EarlyAdopterService) -> ProTier {
        #if DEBUG
        let override = proTierOverride
        #else
        let override = ProTierOverride.automatic
        #endif
        return ProFeatureGate.tier(
            proLaunched: ProFeatureGate.proLaunched,
            isPro: state.isPro,
            isEarlyAdopter: earlyAdopter.isEarlyAdopter,
            override: override
        )
    }
}
