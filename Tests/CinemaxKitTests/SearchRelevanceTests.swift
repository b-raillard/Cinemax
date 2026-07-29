import Testing
import Foundation
@testable import Cinemax

/// Unit tests for the permissive-search ranking primitives, extracted out of
/// `SearchViewModel` into `LibrarySearchRanker` so both the search screen and
/// the App Intents entity query score titles identically.
///
/// The `fullQuery` and `queryWords` passed to `score` are expected
/// pre-normalized (that's how `rank` calls them), so tests feed normalized
/// lowercase input.
@Suite("Search relevance")
struct SearchRelevanceTests {

    // MARK: normalize

    @Test("Collapses punctuation to single spaces")
    func punctuationCollapse() {
        #expect(LibrarySearchRanker.normalize("Mission : Impossible") == "mission impossible")
        #expect(LibrarySearchRanker.normalize("Spider-Man: No Way Home") == "spider man no way home")
    }

    @Test("Folds diacritics and lowercases")
    func diacritics() {
        #expect(LibrarySearchRanker.normalize("Amélie") == "amelie")
        #expect(LibrarySearchRanker.normalize("LA HAINE") == "la haine")
    }

    @Test("Trims leading and trailing separators")
    func trims() {
        #expect(LibrarySearchRanker.normalize("  ...Hello!  ") == "hello")
        #expect(LibrarySearchRanker.normalize("¡Qué!") == "que")
    }

    // MARK: significantWords

    @Test("Drops stop words so common articles can't match everything")
    func significantWordsDropsStopWords() {
        // "the" (twice) and "of" carry no discriminating power.
        #expect(LibrarySearchRanker.significantWords(in: "the lord of the rings") == ["lord", "rings"])
        #expect(LibrarySearchRanker.significantWords(in: "le seigneur des anneaux") == ["seigneur", "anneaux"])
    }

    @Test("Drops single-character words")
    func significantWordsDropsSingleCharacters() {
        #expect(LibrarySearchRanker.significantWords(in: "z nation") == ["nation"])
    }

    @Test("Preserves query order")
    func significantWordsPreservesOrder() {
        #expect(LibrarySearchRanker.significantWords(in: "blade runner 2049") == ["blade", "runner", "2049"])
    }

    @Test("A query made only of stop words yields nothing")
    func significantWordsAllStopWords() {
        #expect(LibrarySearchRanker.significantWords(in: "the a of and").isEmpty)
        #expect(LibrarySearchRanker.significantWords(in: "").isEmpty)
    }

    // MARK: score

    @Test("No overlap scores zero (filtered out)")
    func noMatch() {
        let s = LibrarySearchRanker.score(title: "Avatar", fullQuery: "mission", queryWords: ["mission"])
        #expect(s == 0)
    }

    @Test("Exact title beats prefix beats contiguous-elsewhere")
    func contiguousTiers() {
        let exact = LibrarySearchRanker.score(title: "Mission", fullQuery: "mission", queryWords: ["mission"])
        let prefix = LibrarySearchRanker.score(title: "Mission Impossible", fullQuery: "mission", queryWords: ["mission"])
        let mid = LibrarySearchRanker.score(title: "Impossible Mission", fullQuery: "mission", queryWords: ["mission"])
        #expect(exact > prefix)
        #expect(prefix > mid)
        #expect(mid > 0)
    }

    @Test("Contiguous run outranks all-words-separated outranks partial")
    func wordTiers() {
        // Contiguous "dark knight" present.
        let contiguous = LibrarySearchRanker.score(
            title: "The Dark Knight", fullQuery: "dark knight", queryWords: ["dark", "knight"])
        // Both words present but not as a contiguous run.
        let separated = LibrarySearchRanker.score(
            title: "Knight of the Dark", fullQuery: "dark knight", queryWords: ["dark", "knight"])
        // Only one of two words present.
        let partial = LibrarySearchRanker.score(
            title: "The Dark Tower", fullQuery: "dark knight", queryWords: ["dark", "knight"])
        #expect(contiguous > separated)
        #expect(separated > partial)
        #expect(partial > 0)
    }

    @Test("Empty query never matches")
    func emptyQuery() {
        #expect(LibrarySearchRanker.score(title: "Anything", fullQuery: "", queryWords: []) == 0)
    }

    // MARK: voice-transcription tolerance
    //
    // The whole bet of resolving spoken titles without a local index rests on
    // the ranker absorbing what dictation drops: punctuation and diacritics.
    // These lock that contract at the level the entity query depends on.

    @Test("A dictated title matches its punctuated library title")
    func dictationMatchesPunctuatedTitle() {
        let spoken = LibrarySearchRanker.normalize("Mission Impossible")
        let score = LibrarySearchRanker.score(
            title: "Mission : Impossible",
            fullQuery: spoken,
            queryWords: LibrarySearchRanker.significantWords(in: spoken)
        )
        #expect(score > 0)
    }

    @Test("A dictated title matches its accented library title")
    func dictationMatchesAccentedTitle() {
        let spoken = LibrarySearchRanker.normalize("Amelie")
        let score = LibrarySearchRanker.score(
            title: "Amélie",
            fullQuery: spoken,
            queryWords: LibrarySearchRanker.significantWords(in: spoken)
        )
        #expect(score > 0)
    }
}
