import Foundation

/// What the Pro page sells — the eight functions of the approved mockups, in
/// their order. `isGated` says whether the feature is really locked to the free
/// tier yet: only the remembered accounts are (lot 1); lot 3 locks the rest,
/// one by one, each with its own founder audit. RULE (spec R8): the production
/// pivot is never set while a listed feature is still free — locked by
/// `ProFeatureCatalogueTests`.
nonisolated enum ProFeatureCatalogue {
    struct Feature: Identifiable, Sendable, Equatable {
        let id: ProFeatureID
        /// Localization keys.
        let titleKey: String
        let detailKey: String
        let icon: String
        let isGated: Bool
    }

    static let features: [Feature] = [
        Feature(id: .memorizedAccounts, titleKey: "pro.feature.accounts.title", detailKey: "pro.feature.accounts.detail", icon: "person.2.circle", isGated: true),
        Feature(id: .administration, titleKey: "pro.feature.admin.title", detailKey: "pro.feature.admin.detail", icon: "shield.lefthalf.filled", isGated: false),
        Feature(id: .watchTogetherHost, titleKey: "pro.feature.watchTogether.title", detailKey: "pro.feature.watchTogether.detail", icon: "person.3", isGated: false),
        Feature(id: .playOn, titleKey: "pro.feature.playOn.title", detailKey: "pro.feature.playOn.detail", icon: "airplayvideo", isGated: false),
        Feature(id: .customMenu, titleKey: "pro.feature.menu.title", detailKey: "pro.feature.menu.detail", icon: "rectangle.grid.2x2", isGated: false),
        Feature(id: .accentsAndIcons, titleKey: "pro.feature.accents.title", detailKey: "pro.feature.accents.detail", icon: "paintpalette", isGated: false),
        Feature(id: .seasonalAllYear, titleKey: "pro.feature.seasonal.title", detailKey: "pro.feature.seasonal.detail", icon: "leaf", isGated: false),
        Feature(id: .shortcuts, titleKey: "pro.feature.shortcuts.title", detailKey: "pro.feature.shortcuts.detail", icon: "square.stack.3d.up", isGated: false)
    ]

    static func feature(_ id: ProFeatureID) -> Feature? {
        features.first { $0.id == id }
    }
}

nonisolated enum ProFeatureID: String, Sendable, CaseIterable {
    case memorizedAccounts
    case administration
    case watchTogetherHost
    case playOn
    case customMenu
    case accentsAndIcons
    case seasonalAllYear
    case shortcuts
}
