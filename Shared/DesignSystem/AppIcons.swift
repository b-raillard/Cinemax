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

    var id: String { alternateName ?? "primary" }
}

/// The icons the app ships — DATA: the next icon is one entry here, one in
/// `recolor.py`'s `ALTERNATES` and one name in `project.yml`.
enum AppIconCatalogue {
    /// The primary icon — whatever `scripts/seasonal-icon.py` last made it;
    /// its thumbnail moves with it.
    static let primary = AppIconChoice(alternateName: nil, labelKey: "settings.appIcon.classic", previewImage: "AppIconPreview")

    static let choices: [AppIconChoice] = [
        primary,
        AppIconChoice(alternateName: "AppIconHalloween", labelKey: "settings.appIcon.halloween", previewImage: "AppIconHalloweenPreview")
    ]

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
/// iOS 10.3+ / tvOS 10.2+. iOS raises its own « Vous avez changé l'icône »
/// alert on every switch; nothing here can (or should) silence it.
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
