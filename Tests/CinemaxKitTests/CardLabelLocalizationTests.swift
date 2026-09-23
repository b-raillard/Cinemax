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

    @Test("common kinds have a translated label in both languages", arguments: ["fr", "en"])
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
