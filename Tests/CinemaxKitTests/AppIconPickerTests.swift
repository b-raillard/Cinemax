import Foundation
import Testing
import UIKit
@testable import Cinemax

/// Réglages → Apparence → « Icône de l'app » (lot D, 2026-10-22): which
/// choices exist, which one the system shows, and what a tap does — apply,
/// keep, or raise the Pro sheet — before and after the Pro launch.
@Suite("Icône de l'app")
struct AppIconPickerTests {

    private let halloween = "AppIconHalloween"

    /// Decision 2026-10-22: every variant `recolor.py` declines ships —
    /// Classique, the three Halloween ones, then the nine accents in
    /// `AccentOption` order. The list is mirrored by recolor.py's
    /// `ALTERNATES` and `project.yml` (`bundleWiring` checks the latter).
    @Test("Classique, les trois Halloween, puis les neuf couleurs d'accent, chacune avec son aperçu")
    func catalogue() {
        let choices = AppIconCatalogue.choices
        #expect(choices.map(\.alternateName) == [
            nil,
            "AppIconHalloweenPumpkin", "AppIconHalloweenPotion", halloween,
            "AppIconRed", "AppIconOrange", "AppIconYellow", "AppIconGreen", "AppIconCyan",
            "AppIconBlue", "AppIconIndigo", "AppIconPurple", "AppIconPink",
        ])
        #expect(choices.first == AppIconCatalogue.primary)
        #expect(Set(choices.map(\.id)).count == choices.count)
        #expect(choices.map(\.previewImage) == choices.map { ($0.alternateName ?? "AppIcon") + "Preview" })
    }

    @Test("Chaque famille à sa place : une classique, trois Halloween, une icône par accent sauf l'arc-en-ciel")
    func families() {
        let choices = AppIconCatalogue.choices
        #expect(choices.map(\.family).first == .classic)
        #expect(choices.filter { $0.family == .halloween }.count == 3)
        let accents = choices.compactMap { choice -> AccentOption? in
            if case .accent(let option) = choice.family { option } else { nil }
        }
        #expect(accents == AccentOption.allCases.filter { $0 != .rainbow })
        // An accent icon is labelled with its colour's own name.
        for choice in choices {
            if case .accent(let option) = choice.family { #expect(choice.labelKey == option.nameKey) }
        }
    }

    @Test("Le choix affiché suit le nom que donne le système ; un nom inconnu n'en coche aucun")
    func current() {
        #expect(AppIconCatalogue.choice(alternateName: nil) == AppIconCatalogue.primary)
        #expect(AppIconCatalogue.choice(alternateName: halloween)?.alternateName == halloween)
        #expect(AppIconCatalogue.choice(alternateName: "AppIconRetiree") == nil)
    }

    /// Before the launch the tier is never `.free` (`ProFeatureGate.tier`),
    /// whatever the purchase and founder facts: every icon is open.
    @Test("Avant le lancement : tout est ouvert, Halloween s'applique", arguments: [
        (false, false), (true, false), (false, true), (true, true),
    ])
    func beforeLaunch(isPro: Bool, isEarlyAdopter: Bool) throws {
        let tier = ProFeatureGate.tier(proLaunched: false, isPro: isPro, isEarlyAdopter: isEarlyAdopter, override: .automatic)
        for choice in AppIconCatalogue.choices {
            #expect(!AppIconPickerPolicy.isLocked(choice, tier: tier))
        }
        let target = try #require(AppIconCatalogue.choice(alternateName: halloween))
        #expect(AppIconPickerPolicy.outcome(choosing: target, current: nil, tier: tier) == .apply(halloween))
    }

    @Test("Après le lancement, gratuit : Halloween verrouillée, son choix ouvre la feuille Pro")
    func freeAfterLaunch() throws {
        let tier = ProFeatureGate.tier(proLaunched: true, isPro: false, isEarlyAdopter: false, override: .automatic)
        #expect(tier == .free)
        let target = try #require(AppIconCatalogue.choice(alternateName: halloween))
        #expect(AppIconPickerPolicy.isLocked(target, tier: tier))
        #expect(!AppIconPickerPolicy.isLocked(AppIconCatalogue.primary, tier: tier))
        #expect(AppIconPickerPolicy.outcome(choosing: target, current: nil, tier: tier) == .upsell)
    }

    /// RULE « a Pro feature is never taken back »: a user back to free who
    /// still shows Halloween keeps it — tapping it changes nothing, and the
    /// default stays free to go back to (after which the lock holds).
    @Test("Retour au gratuit : l'icône Halloween déjà posée reste, Classique reste permise")
    func heldIconNeverTakenBack() throws {
        let target = try #require(AppIconCatalogue.choice(alternateName: halloween))
        #expect(AppIconPickerPolicy.outcome(choosing: target, current: halloween, tier: .free) == .keep)
        #expect(AppIconPickerPolicy.outcome(choosing: AppIconCatalogue.primary, current: halloween, tier: .free) == .apply(nil))
        #expect(!ProFeatureGate.revertsAppIconWhenTierDrops)
    }

    @Test("Après le lancement, Pro ou fondateur : Halloween s'applique, et Classique aussi", arguments: [ProTier.pro, .founder])
    func proAfterLaunch(tier: ProTier) throws {
        let target = try #require(AppIconCatalogue.choice(alternateName: halloween))
        #expect(!AppIconPickerPolicy.isLocked(target, tier: tier))
        #expect(AppIconPickerPolicy.outcome(choosing: target, current: nil, tier: tier) == .apply(halloween))
        #expect(AppIconPickerPolicy.outcome(choosing: AppIconCatalogue.primary, current: halloween, tier: tier) == .apply(nil))
    }

    @Test("Toucher l'icône déjà affichée ne fait rien, quel que soit le palier", arguments: [ProTier.free, .pro, .founder])
    func tappingCurrentKeeps(tier: ProTier) {
        #expect(AppIconPickerPolicy.outcome(choosing: AppIconCatalogue.primary, current: nil, tier: tier) == .keep)
    }

    /// Apple TV: one row, Left / Right / press step through the choices,
    /// wrapping; an unknown current name steps from the primary.
    @Test("Apple TV : le pas passe au choix voisin, en boucle")
    func neighbour() {
        #expect(AppIconCatalogue.neighbour(of: nil, by: 1).alternateName == "AppIconHalloweenPumpkin")
        #expect(AppIconCatalogue.neighbour(of: nil, by: -1).alternateName == "AppIconPink")
        #expect(AppIconCatalogue.neighbour(of: halloween, by: 1).alternateName == "AppIconRed")
        #expect(AppIconCatalogue.neighbour(of: "AppIconPink", by: 1).alternateName == nil)
        #expect(AppIconCatalogue.neighbour(of: "AppIconRetiree", by: 1).alternateName == "AppIconHalloweenPumpkin")
    }

    @Test("Chaque choix a son libellé dans chaque langue")
    func labelsInEveryLanguage() throws {
        for lang in AppLanguage.supported {
            let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang))
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            for choice in AppIconCatalogue.choices {
                #expect(table[choice.labelKey] != nil, "\(lang): \(choice.labelKey)")
            }
            #expect(table["settings.appIcon.title"] != nil, "\(lang)")
            let sections = AppIconCatalogue.sections + AppIconCatalogue.tvSections
            for key in sections.map(\.titleKey) + AppIconCatalogue.choices.map(\.family.captionKey) {
                #expect(table[key] != nil, "\(lang): \(key)")
            }
        }
    }

    // MARK: - The dedicated page (design A on iPhone / iPad, B on Apple TV)

    @Test("iPhone / iPad : sections Classique, Halloween, Couleurs, qui couvrent chaque choix une fois")
    func phoneSections() {
        let sections = AppIconCatalogue.sections
        #expect(sections.map(\.titleKey) == [
            "settings.appIcon.section.classic", "settings.appIcon.section.halloween", "settings.appIcon.section.colors",
        ])
        #expect(sections.map(\.choices.count) == [1, 3, 9])
        #expect(sections.flatMap(\.choices) == AppIconCatalogue.choices)
    }

    @Test("Apple TV : Éditions (Classique + Halloween) puis Couleurs, dans l'ordre du catalogue")
    func tvSections() {
        let sections = AppIconCatalogue.tvSections
        #expect(sections.map(\.titleKey) == ["settings.appIcon.section.editions", "settings.appIcon.section.colors"])
        #expect(sections.map(\.choices.count) == [4, 9])
        #expect(sections.flatMap(\.choices) == AppIconCatalogue.choices)
    }

    /// USER RULE (2026-10-22): a tile only PREVIEWS — the system alert of
    /// `setAlternateIconName` on every tap was « vraiment pas user friendly ».
    @Test("Toucher une vignette ne fait que l'aperçu, quel que soit le palier", arguments: [ProTier.free, .pro, .founder])
    func tileTapOnlyPreviews(tier: ProTier) {
        for choice in AppIconCatalogue.choices {
            #expect(AppIconPickerPolicy.tileTap(choice) == .preview(choice))
        }
    }

    @Test("Le bouton unique : « Icône actuelle », « Utiliser cette icône » ou « Débloquer avec JellyGlass Pro »")
    func applyButton() throws {
        let blue = try #require(AppIconCatalogue.choice(alternateName: "AppIconBlue"))
        // The preview IS the current icon: disabled « Icône actuelle », for every tier.
        for tier in [ProTier.free, .pro, .founder] {
            #expect(AppIconPickerPolicy.previewState(blue, current: "AppIconBlue", tier: tier) == .current)
            #expect(AppIconPickerPolicy.previewState(AppIconCatalogue.primary, current: nil, tier: tier) == .current)
        }
        #expect(AppIconPickerPolicy.previewState(blue, current: nil, tier: .free) == .locked)
        #expect(AppIconPickerPolicy.previewState(blue, current: nil, tier: .pro) == .available)
        #expect(AppIconPickerPolicy.previewState(blue, current: nil, tier: .founder) == .available)
        // Back to Classique is always available, even for a free user holding Blue.
        #expect(AppIconPickerPolicy.previewState(AppIconCatalogue.primary, current: "AppIconBlue", tier: .free) == .available)
    }

    @Test("Appliquer l'aperçu : une seule alerte système, ou la feuille Pro quand il est verrouillé")
    func applyPreview() throws {
        let blue = try #require(AppIconCatalogue.choice(alternateName: "AppIconBlue"))
        #expect(AppIconPickerPolicy.apply(previewing: blue, current: nil, tier: .pro) == .apply("AppIconBlue"))
        #expect(AppIconPickerPolicy.apply(previewing: blue, current: nil, tier: .free) == .upsell)
        #expect(AppIconPickerPolicy.apply(previewing: blue, current: "AppIconBlue", tier: .free) == .keep)
        #expect(AppIconPickerPolicy.apply(previewing: AppIconCatalogue.primary, current: "AppIconBlue", tier: .free) == .apply(nil))
    }

    @Test("Le bandeau « 12 icônes de plus avec JellyGlass Pro » : gratuit seulement, et le compte vient du catalogue")
    func proBanner() {
        #expect(AppIconPickerPolicy.proBannerCount(tier: .free) == 12)
        #expect(AppIconPickerPolicy.proBannerCount(tier: .pro) == nil)
        #expect(AppIconPickerPolicy.proBannerCount(tier: .founder) == nil)
        // Before the launch nobody is free, so nobody sees it.
        let tier = ProFeatureGate.tier(proLaunched: false, isPro: false, isEarlyAdopter: false, override: .automatic)
        #expect(AppIconPickerPolicy.proBannerCount(tier: tier) == nil)
    }

    /// The test host IS the app: its built Info.plist must declare every
    /// alternate (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in
    /// `project.yml`), or `setAlternateIconName` fails at run time; and each
    /// thumbnail must be in the bundle.
    @Test("Le bundle déclare chaque icône alternative et embarque chaque aperçu")
    func bundleWiring() {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
        for choice in AppIconCatalogue.choices {
            if let name = choice.alternateName {
                #expect(alternates[name] != nil, "\(name) absent de CFBundleAlternateIcons")
            }
            #expect(UIImage(named: choice.previewImage) != nil, "\(choice.previewImage)")
        }
    }
}
