import Foundation

/// What the Pro page sells, in its order — the scope decided on 2026-10-22
/// (spec `2026-10-22-pro-scope-settings-design.md`): « Regarder ensemble »
/// (creating a session), the custom menu and the accent colours are FREE and
/// left the list. `isGated` says whether a gate site really locks the feature
/// for the free tier yet (lot B: accounts, administration, « Lire sur… »,
/// Siri / Raccourcis; lot C: the « Halloween » choice of Réglages → Apparence;
/// lot D: the alternate app icon, `AppIconPickerPolicy`). RULE (spec R8): the
/// production pivot is never set while a listed feature is still free —
/// locked by `ProFeatureCatalogueTests`.
nonisolated enum ProFeatureCatalogue {
    struct Feature: Identifiable, Sendable, Equatable {
        let id: ProFeatureID
        /// Localization keys.
        let titleKey: String
        let detailKey: String
        let icon: String
        let isGated: Bool
        /// The Apple TV's own wording, when the iPhone's would be wrong there
        /// (« Lire sur… » is sent FROM the TV too; the administration and
        /// Siri / Raccourcis exist on iPhone / iPad only). Nil = same text on both.
        var tvTitleKey: String?
        var tvDetailKey: String?

        func displayTitleKey(onTV: Bool) -> String { onTV ? (tvTitleKey ?? titleKey) : titleKey }
        func displayDetailKey(onTV: Bool) -> String { onTV ? (tvDetailKey ?? detailKey) : detailKey }
        /// What the running platform prints.
        var shownTitleKey: String { displayTitleKey(onTV: ProFeatureCatalogue.isTV) }
        var shownDetailKey: String { displayDetailKey(onTV: ProFeatureCatalogue.isTV) }

        /// The one- or two-word label of the Apple TV pills (« Comptes »,
        /// « Lire sur… ») — `pro.feature.<name>.short`.
        var shortKey: String { titleKey.replacingOccurrences(of: ".title", with: ".short") }
    }

    static let features: [Feature] = [
        Feature(id: .memorizedAccounts, titleKey: "pro.feature.accounts.title", detailKey: "pro.feature.accounts.detail", icon: "person.2.circle", isGated: true),
        // Sold on the Apple TV too (the purchase covers the iPhone / iPad
        // through iCloud), whose wording says where it lives (Q-PROTV).
        Feature(id: .administration, titleKey: "pro.feature.admin.title", detailKey: "pro.feature.admin.detail", icon: "shield.lefthalf.filled", isGated: true,
                tvDetailKey: "pro.feature.admin.detail.tv"),
        Feature(id: .playOn, titleKey: "pro.feature.playOn.title", detailKey: "pro.feature.playOn.detail", icon: "tv.badge.wifi", isGated: true,
                tvTitleKey: "pro.feature.playOn.title.tv", tvDetailKey: "pro.feature.playOn.detail.tv"),
        // Lot D: the picker of Réglages → Apparence → « Icône de l'app »,
        // through `ProFeatureGate.mayChooseAppIcon` (the default icon is free).
        Feature(id: .appIcons, titleKey: "pro.feature.icons.title", detailKey: "pro.feature.icons.detail", icon: "app.badge", isGated: true),
        // Lot C: forcing Halloween at any date (Réglages → Apparence). Free
        // keeps Automatique (Halloween in season) and Désactivé.
        Feature(id: .seasonalAllYear, titleKey: "pro.feature.seasonal.title", detailKey: "pro.feature.seasonal.detail", icon: "leaf", isGated: true),
        Feature(id: .shortcuts, titleKey: "pro.feature.shortcuts.title", detailKey: "pro.feature.shortcuts.detail", icon: "square.stack.3d.up", isGated: true,
                tvDetailKey: "pro.feature.shortcuts.detail.tv")
    ]

    static let isTV: Bool = {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }()

    static func feature(_ id: ProFeatureID) -> Feature? {
        features.first { $0.id == id }
    }
}

nonisolated enum ProFeatureID: String, Sendable, CaseIterable, Identifiable {
    case memorizedAccounts
    case administration
    case playOn
    case appIcons
    case seasonalAllYear
    case shortcuts

    /// `sheet(item:)` — the root's contextual Pro sheet.
    var id: String { rawValue }
}
