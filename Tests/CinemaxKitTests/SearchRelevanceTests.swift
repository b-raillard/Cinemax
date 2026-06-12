import Testing
import Foundation
@testable import Cinemax

/// Unit tests for the permissive-search ranking primitives. The `fullQuery` and
/// `queryWords` passed to `relevanceScore` are expected pre-normalized (that's
/// how `fetchRanked` calls them), so tests feed normalized lowercase input.
@Suite("Search relevance")
struct SearchRelevanceTests {

    // MARK: normalizeForMatch

    @Test("Collapses punctuation to single spaces")
    func punctuationCollapse() {
        #expect(SearchViewModel.normalizeForMatch("Mission : Impossible") == "mission impossible")
        #expect(SearchViewModel.normalizeForMatch("Spider-Man: No Way Home") == "spider man no way home")
    }

    @Test("Folds diacritics and lowercases")
    func diacritics() {
        #expect(SearchViewModel.normalizeForMatch("Amélie") == "amelie")
        #expect(SearchViewModel.normalizeForMatch("LA HAINE") == "la haine")
    }

    @Test("Trims leading and trailing separators")
    func trims() {
        #expect(SearchViewModel.normalizeForMatch("  ...Hello!  ") == "hello")
        #expect(SearchViewModel.normalizeForMatch("¡Qué!") == "que")
    }

    // MARK: relevanceScore

    @Test("No overlap scores zero (filtered out)")
    func noMatch() {
        let s = SearchViewModel.relevanceScore(title: "Avatar", fullQuery: "mission", queryWords: ["mission"])
        #expect(s == 0)
    }

    @Test("Exact title beats prefix beats contiguous-elsewhere")
    func contiguousTiers() {
        let exact = SearchViewModel.relevanceScore(title: "Mission", fullQuery: "mission", queryWords: ["mission"])
        let prefix = SearchViewModel.relevanceScore(title: "Mission Impossible", fullQuery: "mission", queryWords: ["mission"])
        let mid = SearchViewModel.relevanceScore(title: "Impossible Mission", fullQuery: "mission", queryWords: ["mission"])
        #expect(exact > prefix)
        #expect(prefix > mid)
        #expect(mid > 0)
    }

    @Test("Contiguous run outranks all-words-separated outranks partial")
    func wordTiers() {
        // Contiguous "dark knight" present.
        let contiguous = SearchViewModel.relevanceScore(
            title: "The Dark Knight", fullQuery: "dark knight", queryWords: ["dark", "knight"])
        // Both words present but not as a contiguous run.
        let separated = SearchViewModel.relevanceScore(
            title: "Knight of the Dark", fullQuery: "dark knight", queryWords: ["dark", "knight"])
        // Only one of two words present.
        let partial = SearchViewModel.relevanceScore(
            title: "The Dark Tower", fullQuery: "dark knight", queryWords: ["dark", "knight"])
        #expect(contiguous > separated)
        #expect(separated > partial)
        #expect(partial > 0)
    }

    @Test("Empty query never matches")
    func emptyQuery() {
        #expect(SearchViewModel.relevanceScore(title: "Anything", fullQuery: "", queryWords: []) == 0)
    }
}
