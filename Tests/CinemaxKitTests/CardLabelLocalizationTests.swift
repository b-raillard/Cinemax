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
