import Foundation

/// What a user gets: everything free, the Pro bought, or the Pro offered to a
/// founder (installed before the Pro launched).
enum ProTier: Sendable, Equatable {
    case free
    case pro
    case founder

    var unlocksProFeatures: Bool { self != .free }
}

/// Settings → Debug « Palier simulé ». `.automatic` = the real answer;
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

    /// Whether Réglages shows « JellyGlass Pro » at all: once the Pro has
    /// launched (or in a `PRO_PREVIEW` build), or in a Debug build whose
    /// « Palier simulé » is set. Before the launch, production users never
    /// see a Pro page — App Review would meet a product that is not on sale.
    static func showsProEntry(proLaunched: Bool, override: ProTierOverride) -> Bool {
        proLaunched || override != .automatic
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
    /// `ProFeatureGate.showsProEntry` for this store's Debug override.
    var showsProEntry: Bool {
        #if DEBUG || PRO_PREVIEW
        let override = proTierOverride
        #else
        let override = ProTierOverride.automatic
        #endif
        return ProFeatureGate.showsProEntry(proLaunched: ProFeatureGate.proLaunched, override: override)
    }

    /// The tier for this user, the founder recognition coming from `earlyAdopter`.
    func proTier(earlyAdopter: EarlyAdopterService) -> ProTier {
        #if DEBUG || PRO_PREVIEW
        let override = proTierOverride
        #else
        let override = ProTierOverride.automatic
        #endif
        return ProFeatureGate.tier(
            proLaunched: ProFeatureGate.proLaunched,
            isPro: state.isPro,
            isEarlyAdopter: ProFeatureGate.recognisesFounders && earlyAdopter.isEarlyAdopter,
            override: override
        )
    }
}

extension ProFeatureGate {
    /// `false` in a `PRO_PREVIEW` build: a preview exists to walk the
    /// purchase, and with no pivot every PRODUCTION install reads as an early
    /// adopter — the tester's own Apple TV (or an earlier App Store install)
    /// publishes that to their iCloud, which made the preview open on
    /// « Fondateur », with no purchase button.
    static var recognisesFounders: Bool {
        #if PRO_PREVIEW
        false
        #else
        true
        #endif
    }
}

// MARK: - Lot B — the gate sites (spec 2026-10-22)

extension ProFeatureGate {
    /// THE question every gate site asks. Pure: the tier decides, and before
    /// the launch `tier(…)` is never `.free` — so every feature stays open
    /// until the pivot is set, whatever the purchase and the founder facts.
    /// `feature` is part of the question on purpose: a future feature with
    /// its own rule (a lower tier, a trial) changes this line, not the sites.
    static func allows(_ feature: ProFeatureID, tier: ProTier) -> Bool {
        switch feature {
        case .memorizedAccounts, .administration, .playOn, .appIcons, .seasonalAllYear, .shortcuts:
            tier.unlocksProFeatures
        }
    }

    /// App icons: the default icon (`nil`) is never paid, an alternate one is
    /// the Pro's. Asked by the picker of Réglages → Apparence through
    /// `AppIconPickerPolicy` — see the App Icons RULE in
    /// `Shared/DesignSystem/CLAUDE.md`.
    static func mayChooseAppIcon(alternateName: String?, tier: ProTier) -> Bool {
        alternateName == nil || allows(.appIcons, tier: tier)
    }

    /// A tier that drops (refund, end of family sharing) never takes an icon
    /// back: `setAlternateIconName` raises a system alert of its own, so a
    /// revert would be a dialog nobody asked for. The picker just locks.
    static let revertsAppIconWhenTierDrops = false
}

/// The gate sites' one entry point (lot B): asks `ProFeatureGate.allows` for
/// THIS user, and — through `admit` — raises the contextual Pro sheet, which
/// the root presents (`ProUpsellPresentation`). A process singleton
/// (`AppNavigation.sharedProAccess`), injected through the environment and
/// reached directly by the App Intents, which have no environment.
///
/// The tier is a closure over the two stores, built at init — never wired
/// late from a `.task`: an intent can cold-launch the app and ask before any
/// view exists. Reading it inside a `body` reads `EntitlementStore` /
/// `EarlyAdopterService` observable properties, so a tier change redraws the
/// gated entries like any other observed value.
@MainActor @Observable
final class ProFeatureAccess {
    /// The feature whose contextual sheet the root shows; `nil` = none.
    var upsell: ProFeatureID?
    @ObservationIgnored private let tier: @MainActor () -> ProTier

    /// `tier` is a test seam; the app uses `init(entitlements:earlyAdopter:)`.
    init(tier: @escaping @MainActor () -> ProTier) {
        self.tier = tier
    }

    convenience init(entitlements: EntitlementStore, earlyAdopter: EarlyAdopterService) {
        self.init { entitlements.proTier(earlyAdopter: earlyAdopter) }
    }

    /// This user's tier, for a pure policy that takes one
    /// (`AppIconPickerPolicy`). Reading it in a `body` observes the stores.
    func currentTier() -> ProTier {
        tier()
    }

    /// Only asks — never opens anything. For drawing a lock, or hiding a
    /// per-item shortcut.
    func allows(_ feature: ProFeatureID) -> Bool {
        ProFeatureGate.allows(feature, tier: tier())
    }

    /// Asks, and when refused raises the sheet of THIS feature. For a tap.
    @discardableResult
    func admit(_ feature: ProFeatureID) -> Bool {
        if allows(feature) { return true }
        upsell = feature
        return false
    }
}
