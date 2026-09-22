import Testing
import Foundation
@testable import CinemaxKit

@Suite("ContentRatingClassifier")
struct ContentRatingClassifierTests {

    // MARK: age(forRating:)

    @Test("Known codes map to their board age")
    func knownCodes() {
        #expect(ContentRatingClassifier.age(forRating: "G") == 0)
        #expect(ContentRatingClassifier.age(forRating: "PG") == 10)
        #expect(ContentRatingClassifier.age(forRating: "PG-13") == 13)
        #expect(ContentRatingClassifier.age(forRating: "R") == 17)
        #expect(ContentRatingClassifier.age(forRating: "NC-17") == 18)
        #expect(ContentRatingClassifier.age(forRating: "TV-MA") == 17)
        #expect(ContentRatingClassifier.age(forRating: "-12") == 12)
        #expect(ContentRatingClassifier.age(forRating: "FSK-16") == 16)
    }

    @Test("Lookup is case-insensitive and trims whitespace")
    func caseAndWhitespace() {
        #expect(ContentRatingClassifier.age(forRating: "pg-13") == 13)
        #expect(ContentRatingClassifier.age(forRating: "  TV-MA  ") == 17)
        #expect(ContentRatingClassifier.age(forRating: "tous publics") == 0)
    }

    @Test("Unknown or nil ratings are permissive (age 0)")
    func unknownPermissive() {
        #expect(ContentRatingClassifier.age(forRating: nil) == 0)
        #expect(ContentRatingClassifier.age(forRating: "") == 0)
        #expect(ContentRatingClassifier.age(forRating: "NOT-A-RATING") == 0)
    }

    /// Audit 2026-09-22 : la table seule répondait 0 (« laisse passer ») aux
    /// formes que les fournisseurs écrivent réellement, et la porte de la fiche
    /// atteinte par identifiant repose sur ce classifieur.
    @Test("Country prefixes, bare ages and a trailing + are read as ages")
    func realWorldForms() {
        #expect(ContentRatingClassifier.age(forRating: "FR-12") == 12)
        #expect(ContentRatingClassifier.age(forRating: "DE-16") == 16)
        #expect(ContentRatingClassifier.age(forRating: "Germany: FSK-18") == 18)
        #expect(ContentRatingClassifier.age(forRating: "16") == 16)
        #expect(ContentRatingClassifier.age(forRating: "12+") == 12)
        #expect(ContentRatingClassifier.age(forRating: "Rated R") == 17)
        // The table still wins over the splitting: these contain a dash.
        #expect(ContentRatingClassifier.age(forRating: "PG-13") == 13)
        #expect(ContentRatingClassifier.age(forRating: "TV-MA") == 17)
        #expect(ContentRatingClassifier.age(forRating: "-12") == 12)
    }

    // MARK: passes(rating:maxAge:)

    @Test("maxAge 0 disables filtering — everything passes")
    func zeroMaxAgeDisables() {
        #expect(ContentRatingClassifier.passes(rating: "NC-17", maxAge: 0))
        #expect(ContentRatingClassifier.passes(rating: "R", maxAge: 0))
    }

    @Test("Items at or below the ceiling pass; above are hidden")
    func boundary() {
        // PG-13 (age 13) against a 13+ ceiling: passes (<=).
        #expect(ContentRatingClassifier.passes(rating: "PG-13", maxAge: 13))
        // R (age 17) against a 13+ ceiling: hidden.
        #expect(!ContentRatingClassifier.passes(rating: "R", maxAge: 13))
        // TV-14 (age 14) against a 13+ ceiling: hidden.
        #expect(!ContentRatingClassifier.passes(rating: "TV-14", maxAge: 13))
    }

    @Test("Unrated items pass even under a ceiling")
    func unratedPasses() {
        #expect(ContentRatingClassifier.passes(rating: nil, maxAge: 10))
        #expect(ContentRatingClassifier.passes(rating: "MYSTERY", maxAge: 10))
    }

    // MARK: maxOfficialRatingCode(forAge:)

    /// Audit 2026-09-22 (S2) : les codes US envoyés jusque-là dépassaient le
    /// plafond (12 → PG-13 = 13, 16 → TV-MA = 17 sur 10.10+ ; TV-PG = 13 sur
    /// 10.9). Chaque serveur supporté lit un entier comme un âge : exact partout.
    @Test("Server-side ceiling is the age itself, as an integer string")
    func serverCode() {
        #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: 0) == nil)
        #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: -5) == nil)
        for age in [10, 12, 14, 16, 18] {
            #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: age) == String(age))
        }
    }
}
