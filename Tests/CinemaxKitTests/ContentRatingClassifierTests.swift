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

    @Test("Server-side ceiling code per age bucket")
    func serverCode() {
        #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: 0) == nil)
        #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: -5) == nil)
        #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: 10) == "TV-PG")
        #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: 12) == "PG-13")
        #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: 14) == "TV-14")
        #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: 16) == "TV-MA")
        #expect(ContentRatingClassifier.maxOfficialRatingCode(forAge: 18) == "NC-17")
    }
}
