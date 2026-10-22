import Foundation
#if canImport(UIKit)
import OSLog
import UIKit
#endif

// MARK: - Alternate app icons (lot D, 2026-10-22)

/// One choice of Réglages → Apparence → « Icône de l'app ».
struct AppIconChoice: Identifiable, Sendable, Equatable {
    /// `nil` = the primary icon (always free); otherwise the asset name handed
    /// to `setAlternateIconName` — the SAME string on iOS (an `.appiconset`)
    /// and tvOS (a top-level `.imagestack`), declared in `project.yml`'s
    /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` of both targets.
    let alternateName: String?
    let labelKey: String
    /// The picker's thumbnail imageset: `UIImage(named:)` cannot read an app
    /// icon set. Written by `design/logo-variantes/recolor.py --alternates`.
    let previewImage: String
    /// Which kind of icon it is — for a picker that groups or decorates them
    /// (a section per family, an accent's swatch).
    let family: Family

    enum Family: Equatable, Sendable {
        /// The primary icon (`alternateName == nil`).
        case classic
        /// A « Nuit d'Halloween » variant.
        case halloween
        /// The logo in one accent colour (`AccentOption.accentDark`'s hue).
        case accent(AccentOption)
    }

    var id: String { alternateName ?? "primary" }
}

/// The icons the app ships — DATA: the next icon is one entry here, one in
/// `recolor.py`'s `ALTERNATES` and one name in `project.yml`.
enum AppIconCatalogue {
    /// The primary icon — whatever `scripts/seasonal-icon.py` last made it;
    /// its thumbnail moves with it.
    static let primary = AppIconChoice(alternateName: nil, labelKey: "settings.appIcon.classic", previewImage: "AppIconPreview", family: .classic)

    /// Every variant `recolor.py` declines (decision 2026-10-22), in picker
    /// order: Classique, the three Halloween ones, then one per accent in
    /// `AccentOption` order (no rainbow — it has no hue to recolour with).
    /// The asset name is the thumbnail's minus « Preview ».
    static let choices: [AppIconChoice] = [primary] + halloween + accents

    /// A = bell pumpkin, tentacles potion (the PRIMARY icon until the user
    /// reverts it after 2 November — identical to Classique until then); B =
    /// the reverse; « Nuit d'Halloween » = A on the theme's aubergine ground.
    static let halloween: [AppIconChoice] = [
        ("AppIconHalloweenPumpkin", "settings.appIcon.halloweenPumpkin"),
        ("AppIconHalloweenPotion", "settings.appIcon.halloweenPotion"),
        ("AppIconHalloween", "settings.appIcon.halloween")
    ].map { AppIconChoice(alternateName: $0.0, labelKey: $0.1, previewImage: $0.0 + "Preview", family: .halloween) }

    /// `AppIconRed` … `AppIconPink`, labelled with the accent's own name.
    static let accents: [AppIconChoice] = AccentOption.allCases.filter { $0 != .rainbow }.map { option in
        let name = "AppIcon" + option.rawValue.prefix(1).uppercased() + option.rawValue.dropFirst()
        return AppIconChoice(alternateName: name, labelKey: option.nameKey, previewImage: name + "Preview", family: .accent(option))
    }

    /// The choice the system shows for `UIApplication.alternateIconName`;
    /// `nil` for a name no choice carries (an icon a later version dropped) —
    /// then nothing is ticked rather than a wrong one.
    static func choice(alternateName: String?) -> AppIconChoice? {
        choices.first { $0.alternateName == alternateName }
    }

    /// Apple TV: the choice `step` away from the current one, wrapping. An
    /// unknown current name steps from the primary.
    static func neighbour(of alternateName: String?, by step: Int) -> AppIconChoice {
        let start = choices.firstIndex { $0.alternateName == alternateName } ?? 0
        let count = choices.count
        return choices[((start + step) % count + count) % count]
    }
}

/// What a tap on a choice does. Pure; the gate is
/// `ProFeatureGate.mayChooseAppIcon` (the default icon is never paid).
enum AppIconPickerPolicy {
    enum Outcome: Equatable, Sendable {
        /// The icon already shown: nothing — not even for a locked one the
        /// user still holds (RULE: a Pro feature is never taken back).
        case keep
        /// `setAlternateIconName(_:)` with this name.
        case apply(String?)
        /// Refused: the root's contextual Pro sheet (`ProFeatureAccess.admit(.appIcons)`).
        case upsell
    }

    static func isLocked(_ choice: AppIconChoice, tier: ProTier) -> Bool {
        !ProFeatureGate.mayChooseAppIcon(alternateName: choice.alternateName, tier: tier)
    }

    static func outcome(choosing choice: AppIconChoice, current: String?, tier: ProTier) -> Outcome {
        if choice.alternateName == current { return .keep }
        return isLocked(choice, tier: tier) ? .upsell : .apply(choice.alternateName)
    }
}

#if canImport(UIKit)
/// The system side of the picker — `UIApplication`'s alternate-icon API,
/// iOS 10.3+ / tvOS 10.2+. Both systems raise their own « You have changed
/// the icon » alert on every switch (seen on the iOS 27 and tvOS 27
/// simulators); nothing here can (or should) silence it.
@MainActor
enum AppIconSwitcher {
    /// `false` hides the whole « Icône de l'app » section.
    static var isSupported: Bool { UIApplication.shared.supportsAlternateIcons }
    /// Not observable: the picker keeps a copy, refreshed on appear and
    /// after each switch.
    static var currentName: String? { UIApplication.shared.alternateIconName }

    /// Logs a failure (the caller shows a localized toast, never the raw error).
    static func set(_ name: String?) async throws {
        do {
            try await UIApplication.shared.setAlternateIconName(name)
        } catch {
            log.error("setAlternateIconName(\(name ?? "nil", privacy: .public)) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static let log = Logger(subsystem: "com.cinemax", category: "AppIcon")
}
#endif
