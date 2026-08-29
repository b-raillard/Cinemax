import Testing
@testable import CinemaxKit

/// Locks the ordering the remote-artwork picker renders. The grid is the only
/// place in the app where the user picks a *specific* image, so an unstable or
/// wrong order is directly a usability defect — and the order must be TOTAL, or
/// two loads of the same server response can reshuffle under the user's finger.
@Suite("RemoteImageCatalog.rank")
struct RemoteImageCatalogTests {

    private func candidate(
        _ url: String,
        language: String? = nil,
        rating: Double? = nil,
        votes: Int? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) -> RemoteImageCandidate {
        RemoteImageCandidate(
            url: url,
            language: language,
            width: width,
            height: height,
            communityRating: rating,
            voteCount: votes
        )
    }

    @Test("an empty catalogue ranks to nothing")
    func emptyStaysEmpty() {
        #expect(RemoteImageCatalog.rank([], preferredLanguage: "fr").isEmpty)
    }

    @Test("the preferred language leads, textless follows, other languages last")
    func languageTiers() {
        let ranked = RemoteImageCatalog.rank(
            [candidate("de", language: "de"), candidate("none"), candidate("fr", language: "fr")],
            preferredLanguage: "fr"
        )
        #expect(ranked.map(\.url) == ["fr", "none", "de"])
    }

    @Test("regional variants match their primary subtag, case-insensitively")
    func regionalVariantsMatch() {
        let ranked = RemoteImageCatalog.rank(
            [candidate("en", language: "en"), candidate("frCA", language: "FR-CA")],
            preferredLanguage: "fr"
        )
        #expect(ranked.first?.url == "frCA")
    }

    @Test("with no preferred language, textless still leads")
    func noPreferenceFavoursTextless() {
        let ranked = RemoteImageCatalog.rank(
            [candidate("en", language: "en"), candidate("none")],
            preferredLanguage: nil
        )
        #expect(ranked.map(\.url) == ["none", "en"])
    }

    @Test("an empty language string counts as textless, not as a third language")
    func blankLanguageIsTextless() {
        let ranked = RemoteImageCatalog.rank(
            [candidate("de", language: "de"), candidate("blank", language: "  ")],
            preferredLanguage: "fr"
        )
        #expect(ranked.map(\.url) == ["blank", "de"])
    }

    @Test("within a tier, community rating decides")
    func ratingOrdersWithinTier() {
        let ranked = RemoteImageCatalog.rank(
            [candidate("low", language: "fr", rating: 4.1), candidate("high", language: "fr", rating: 9.2)],
            preferredLanguage: "fr"
        )
        #expect(ranked.map(\.url) == ["high", "low"])
    }

    @Test("an unrated image sorts below any rated one")
    func unratedSinks() {
        let ranked = RemoteImageCatalog.rank(
            [candidate("unrated", language: "fr"), candidate("rated", language: "fr", rating: 0.5)],
            preferredLanguage: "fr"
        )
        #expect(ranked.map(\.url) == ["rated", "unrated"])
    }

    @Test("equal ratings fall through to vote count, then to resolution")
    func votesThenResolutionBreakTies() {
        let byVotes = RemoteImageCatalog.rank(
            [candidate("few", rating: 8, votes: 3), candidate("many", rating: 8, votes: 90)],
            preferredLanguage: nil
        )
        #expect(byVotes.map(\.url) == ["many", "few"])

        let byPixels = RemoteImageCatalog.rank(
            [
                candidate("sd", rating: 8, votes: 5, width: 640, height: 360),
                candidate("hd", rating: 8, votes: 5, width: 1920, height: 1080),
            ],
            preferredLanguage: nil
        )
        #expect(byPixels.map(\.url) == ["hd", "sd"])
    }

    @Test("the order is total — otherwise identical entries fall through to url")
    func urlIsTheFinalTiebreak() {
        let ranked = RemoteImageCatalog.rank(
            [candidate("b", rating: 8, votes: 5, width: 100, height: 100),
             candidate("a", rating: 8, votes: 5, width: 100, height: 100)],
            preferredLanguage: nil
        )
        #expect(ranked.map(\.url) == ["a", "b"])
    }

    @Test("duplicate urls collapse to one tile — the server addresses artwork by url")
    func duplicatesCollapse() {
        let ranked = RemoteImageCatalog.rank(
            [candidate("same", rating: 9), candidate("same", rating: 1), candidate("other", rating: 5)],
            preferredLanguage: nil
        )
        #expect(ranked.count == 2)
        #expect(ranked.filter { $0.url == "same" }.count == 1)
    }

    @Test("a blank url is dropped — it could never be applied")
    func blankURLsDropped() {
        let ranked = RemoteImageCatalog.rank(
            [candidate(""), candidate("   "), candidate("real")],
            preferredLanguage: nil
        )
        #expect(ranked.map(\.url) == ["real"])
    }

    @Test("previewURL prefers the thumbnail and falls back to the full image")
    func previewFallsBack() {
        let withThumb = RemoteImageCandidate(url: "full", thumbnailURL: "thumb")
        let without = RemoteImageCandidate(url: "full")
        #expect(withThumb.previewURL == "thumb")
        #expect(without.previewURL == "full")
    }

    @Test("resolutionLabel is nil unless both dimensions are meaningful")
    func resolutionLabelGuards() {
        #expect(RemoteImageCandidate(url: "a", width: 1920, height: 1080).resolutionLabel == "1920 × 1080")
        #expect(RemoteImageCandidate(url: "a", width: 1920).resolutionLabel == nil)
        #expect(RemoteImageCandidate(url: "a", width: 0, height: 0).resolutionLabel == nil)
    }
}
