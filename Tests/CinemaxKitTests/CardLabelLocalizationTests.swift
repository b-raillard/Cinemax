import Foundation
import Testing
import JellyfinAPI
@testable import Cinemax

/// Card subtitles printed `BaseItemKind.rawValue` (« Movie » / « Series » in
/// English whatever the app language) and ratings through
/// `String(format: "%.1f")` (always a point). Both now go through
/// `LocalizationManager`; these lock the pure halves against the real fr / en
/// bundles, without touching the app-wide language a parallel test reads.
@Suite("Card label localization")
struct CardLabelLocalizationTests {
    private func string(_ key: String, _ language: String) -> String {
        Bundle.localizedBundle(for: language).localizedString(forKey: key, value: nil, table: nil)
    }

    @Test("common kinds have a translated label in every language", arguments: AppLanguage.supported)
    func kindsResolve(language: String) {
        for kind in [BaseItemKind.movie, .series, .episode, .season, .boxSet, .playlist, .video] {
            let key = LocalizationManager.itemKindKey(kind)
            #expect(key != nil, "\(kind) has no label")
            if let key {
                #expect(string(key, language) != key, "\(key) missing in \(language)")
            }
        }
    }

    @Test("French labels are French")
    func frenchLabels() {
        #expect(string(LocalizationManager.itemKindKey(.movie)!, "fr") == "Film")
        #expect(string(LocalizationManager.itemKindKey(.series)!, "fr") == "Série")
    }

    @Test("a kind with no label is left out, never printed raw")
    func unknownKindHasNoLabel() {
        #expect(LocalizationManager.itemKindKey(.person) == nil)
        #expect(LocalizationManager.itemKindKey(.folder) == nil)
    }

    @Test("ratings use the app language's decimal separator")
    func decimalSeparator() {
        #expect(LocalizationManager.decimal(6.8, languageCode: "fr") == "6,8")
        #expect(LocalizationManager.decimal(6.8, languageCode: "en") == "6.8")
        #expect(LocalizationManager.decimal(7, languageCode: "fr") == "7,0")
    }
}

// MARK: - App languages (2.3.1, German)

/// Until 2.3.1 every install started in French whatever the phone spoke; the
/// default now follows the device until the user picks a language.
@Suite("App language")
struct AppLanguageTests {

    @Test("the device's first language the app ships wins, whatever its region")
    func resolvesFromDevice() {
        #expect(AppLanguage.resolve(preferredLanguages: ["de-CH", "fr-CH"]) == "de")
        #expect(AppLanguage.resolve(preferredLanguages: ["fr-FR"]) == "fr")
        #expect(AppLanguage.resolve(preferredLanguages: ["en-GB"]) == "en")
        #expect(AppLanguage.resolve(preferredLanguages: ["it-CH", "de-CH"]) == "de")
        #expect(AppLanguage.resolve(preferredLanguages: ["zh-Hans-CN"]) == "en")
        #expect(AppLanguage.resolve(preferredLanguages: []) == "en")
    }

    @Test("every shipped language has its own name in every table", arguments: AppLanguage.supported)
    func namesResolve(language: String) {
        let bundle = Bundle.localizedBundle(for: language)
        for code in AppLanguage.supported {
            let key = AppLanguage.nameKey(code)
            #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key, "\(language): \(key)")
        }
        // A real `.lproj`, not the main-bundle fallback.
        #expect(bundle != Bundle.main, "\(language).lproj missing")
    }

    @Test("a fresh install takes the device's language, an upgrade keeps French")
    func settlesOnce() {
        // Fresh install: the device decides, English when it speaks none of ours.
        #expect(AppLanguage.languageToSettle(stored: nil, isExistingInstall: false, preferredLanguages: ["de-CH"]) == "de")
        #expect(AppLanguage.languageToSettle(stored: nil, isExistingInstall: false, preferredLanguages: ["it-IT"]) == "en")
        // An upgrade had been reading French (the old default) — it keeps it
        // and is OFFERED its device's language in « Quoi de neuf ».
        #expect(AppLanguage.languageToSettle(stored: nil, isExistingInstall: true, preferredLanguages: ["de-CH"]) == "fr")
        // A stored choice is never touched.
        #expect(AppLanguage.languageToSettle(stored: "en", isExistingInstall: true, preferredLanguages: ["de-CH"]) == nil)
    }

    @Test("settling writes once, then a stamped second launch keeps the first answer")
    func settlingIsStable() {
        let defaults = UserDefaults.isolatedForTesting()
        AppLanguage.settleStoredLanguage(defaults: defaults)
        let first = defaults.string(forKey: SettingsKey.appLanguage)
        #expect(first != nil)
        // The first launch stamps « Quoi de neuf »; the second must not take
        // the install for an upgrade and pin it to French.
        defaults.set("2.3.1", forKey: SettingsKey.whatsNewLastSeenVersion)
        AppLanguage.settleStoredLanguage(defaults: defaults)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == first)
    }

    @Test("an upgraded install with no stored language is pinned to French")
    func upgradePinnedToFrench() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("2.3.0", forKey: SettingsKey.whatsNewLastSeenVersion)
        AppLanguage.settleStoredLanguage(defaults: defaults)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "fr")
    }

    @Test("a language the system changed since the last launch is adopted, nothing else is")
    func adoptsSystemChange() {
        // Réglages → JellyGlass → Langue moved from English to German.
        #expect(AppLanguage.languageToAdopt(stored: "fr", systemSeen: "en", systemNow: "de") == "de")
        // From a language we don't ship to one we do.
        #expect(AppLanguage.languageToAdopt(stored: "en", systemSeen: "", systemNow: "fr") == "fr")
        // No change since the last launch: the in-app choice stands.
        #expect(AppLanguage.languageToAdopt(stored: "fr", systemSeen: "en", systemNow: "en") == nil)
        // Never recorded (first launch of 2.3.2+): record only — « Quoi de neuf » offers it.
        #expect(AppLanguage.languageToAdopt(stored: "fr", systemSeen: nil, systemNow: "de") == nil)
        // Moved to a language we don't ship: keep ours.
        #expect(AppLanguage.languageToAdopt(stored: "fr", systemSeen: "en", systemNow: nil) == nil)
    }

    @Test("an upgrade keeps French, writes it as the app's own language, then follows iOS Settings")
    func settleFollowsSystem() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("2.3.1", forKey: SettingsKey.whatsNewLastSeenVersion)
        defaults.set("fr", forKey: SettingsKey.appLanguage)
        // First 2.3.2+ launch on an English device, no language of its own yet.
        AppLanguage.settleStoredLanguage(defaults: defaults, preferredLanguages: ["en-GB"], ownLanguages: nil)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "fr")
        // Mirrored, so Réglages › JellyGlass › Langue shows « Français ».
        #expect(defaults.stringArray(forKey: AppLanguage.appleLanguagesKey) == ["fr"])
        #expect(defaults.string(forKey: SettingsKey.appLanguageSystemSeen) == "fr")
        // Next launch: iOS now puts the app's own language first.
        AppLanguage.settleStoredLanguage(defaults: defaults, preferredLanguages: ["fr", "en-GB"], ownLanguages: ["fr"])
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "fr")
        // Deutsch picked in Réglages › JellyGlass › Langue.
        AppLanguage.settleStoredLanguage(
            defaults: defaults, preferredLanguages: ["de-CH", "en-GB"], ownLanguages: ["de-CH", "en-GB"]
        )
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "de")
    }

    @Test("picking the device's own language in iOS Settings is followed (it used to change nothing)")
    func iOSSettingsBackToDeviceLanguage() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("2.3.1", forKey: SettingsKey.whatsNewLastSeenVersion)
        defaults.set("fr", forKey: SettingsKey.appLanguage)
        AppLanguage.settleStoredLanguage(defaults: defaults, preferredLanguages: ["en-GB"], ownLanguages: nil)
        // English picked there = the device's default: iOS drops the app's own list.
        AppLanguage.settleStoredLanguage(defaults: defaults, preferredLanguages: ["en-GB"], ownLanguages: nil)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "en")
    }

    @Test("an app already speaking the device's language gets no language of its own")
    func noMirrorWhenFollowingDevice() {
        let defaults = UserDefaults.isolatedForTesting()
        AppLanguage.settleStoredLanguage(defaults: defaults, preferredLanguages: ["de-CH"], ownLanguages: nil)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "de")
        #expect(defaults.string(forKey: SettingsKey.appLanguageSystemSeen) == "de")
        // Device moves to English: still followed, nothing pinned it.
        AppLanguage.settleStoredLanguage(defaults: defaults, preferredLanguages: ["en-GB"], ownLanguages: nil)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "en")
    }

    @Test("an in-app choice is mirrored to the system and not read back as a change")
    func inAppChoiceIsMirrored() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("2.3.1", forKey: SettingsKey.whatsNewLastSeenVersion)
        defaults.set("en", forKey: SettingsKey.appLanguage)
        AppLanguage.settleStoredLanguage(defaults: defaults, preferredLanguages: ["en-US"], ownLanguages: nil)
        // The user picks German in the app; iOS then reports it as the app's language.
        defaults.set("de", forKey: SettingsKey.appLanguage)
        AppLanguage.recordUserChoice("de", defaults: defaults)
        #expect(defaults.stringArray(forKey: AppLanguage.appleLanguagesKey) == ["de"])
        AppLanguage.settleStoredLanguage(defaults: defaults, preferredLanguages: ["de"], ownLanguages: ["de"])
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "de")
    }

    @Test("only a shipped device language that differs from the app's is offered")
    func offers() {
        #expect(AppLanguage.offer(current: "fr", preferredLanguages: ["de-CH"]) == "de")
        #expect(AppLanguage.offer(current: "fr", preferredLanguages: ["en-GB"]) == "en")
        #expect(AppLanguage.offer(current: "de", preferredLanguages: ["de-AT"]) == nil)
        #expect(AppLanguage.offer(current: "fr", preferredLanguages: ["it-IT"]) == nil)
        #expect(AppLanguage.offer(current: "fr", preferredLanguages: ["it-IT", "de-CH"]) == "de")
    }

    @Test("the tvOS row walks the languages in order and wraps both ways")
    func cycles() {
        #expect(AppLanguage.next(after: "fr") == "en")
        #expect(AppLanguage.next(after: "en") == "de")
        #expect(AppLanguage.next(after: "de") == "fr")
        #expect(AppLanguage.next(after: "fr", step: -1) == "de")
    }

    #if os(iOS)
    /// `ExtensionLanguage` is the widget's copy (shared by source with the iOS
    /// app only), which cannot link the app's `AppLanguage`.
    @Test("the extensions read the device the same way")
    func extensionsAgree() {
        for tags in [["de-AT"], ["fr-BE"], ["en-US"], ["it-IT", "fr-CH"], ["es-ES"]] {
            let expected = AppLanguage.resolve(preferredLanguages: tags)
            let language = ExtensionLanguage.resolve(tags)
            #expect(language.text(fr: "fr", en: "en", de: "de") == expected, "\(tags)")
        }
    }
    #endif
}
