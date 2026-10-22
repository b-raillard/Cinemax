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

    @Test("Classique (l'icône principale, nil) puis Halloween, chacune avec son aperçu")
    func catalogue() {
        let choices = AppIconCatalogue.choices
        #expect(choices.map(\.alternateName) == [nil, halloween])
        #expect(choices.first == AppIconCatalogue.primary)
        #expect(Set(choices.map(\.id)).count == choices.count)
        #expect(Set(choices.map(\.previewImage)).count == choices.count)
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
        #expect(AppIconCatalogue.neighbour(of: nil, by: 1).alternateName == halloween)
        #expect(AppIconCatalogue.neighbour(of: nil, by: -1).alternateName == halloween)
        #expect(AppIconCatalogue.neighbour(of: halloween, by: 1).alternateName == nil)
        #expect(AppIconCatalogue.neighbour(of: "AppIconRetiree", by: 1).alternateName == halloween)
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
        }
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
