import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

// MARK: - LibrarySortFilterState

@Suite("LibrarySortFilterState")
struct LibrarySortFilterStateTests {

    @Test("expandedYears expands each selected decade into its 10 years, sorted")
    func expandedYearsTwoDecades() {
        var state = LibrarySortFilterState()
        state.selectedDecades = [2000, 1980] // insertion order must not matter

        let years = state.expandedYears
        #expect(years == Array(1980...1989) + Array(2000...2009))
        #expect(years?.count == 20)
    }

    @Test("expandedYears is nil when no decade is selected")
    func expandedYearsEmpty() {
        let state = LibrarySortFilterState()
        #expect(state.selectedDecades.isEmpty)
        #expect(state.expandedYears == nil)
    }

    @Test("default state is neither filtered nor non-default")
    func defaultState() {
        let state = LibrarySortFilterState()
        #expect(!state.isFiltered)
        #expect(!state.isNonDefault)
    }

    @Test("sort-only changes flip isNonDefault but not isFiltered")
    func sortOnlyChanges() {
        var state = LibrarySortFilterState()
        state.sortBy = .sortName
        #expect(!state.isFiltered)
        #expect(state.isNonDefault)

        state = LibrarySortFilterState()
        state.sortAscending = true
        #expect(!state.isFiltered)
        #expect(state.isNonDefault)
    }

    @Test("genre / unwatched / decade filters flip both isFiltered and isNonDefault")
    func filterChanges() {
        var state = LibrarySortFilterState()
        state.selectedGenres = ["Action"]
        #expect(state.isFiltered)
        #expect(state.isNonDefault)

        state = LibrarySortFilterState()
        state.showUnwatchedOnly = true
        #expect(state.isFiltered)
        #expect(state.isNonDefault)

        state = LibrarySortFilterState()
        state.selectedDecades = [1990]
        #expect(state.isFiltered)
        #expect(state.isNonDefault)
    }
}

// MARK: - Episode navigation (free functions in PlayLink.swift)

@Suite("Episode navigation")
struct EpisodeNavigationTests {

    private func makeEpisode(id: String?, name: String) -> BaseItemDto {
        var ep = BaseItemDto()
        ep.id = id
        ep.name = name
        return ep
    }

    private var episodes: [BaseItemDto] {
        [
            makeEpisode(id: "ep-1", name: "One"),
            makeEpisode(id: "ep-2", name: "Two"),
            makeEpisode(id: "ep-3", name: "Three")
        ]
    }

    @Test("first episode has no previous, last has no next, middle has both")
    func neighbors() {
        let api = MockAPIClient()

        let first = buildEpisodeNavigation(for: "ep-1", in: episodes, apiClient: api, userId: "u1")
        #expect(first.previous == nil)
        #expect(first.next?.id == "ep-2")
        #expect(first.navigator != nil)

        let middle = buildEpisodeNavigation(for: "ep-2", in: episodes, apiClient: api, userId: "u1")
        #expect(middle.previous?.id == "ep-1")
        #expect(middle.next?.id == "ep-3")
        #expect(middle.navigator != nil)

        let last = buildEpisodeNavigation(for: "ep-3", in: episodes, apiClient: api, userId: "u1")
        #expect(last.previous?.id == "ep-2")
        #expect(last.next == nil)
        #expect(last.navigator != nil)
    }

    @Test("unknown episode id yields nils")
    func unknownID() {
        let api = MockAPIClient()
        let nav = buildEpisodeNavigation(for: "nope", in: episodes, apiClient: api, userId: "u1")
        #expect(nav.previous == nil)
        #expect(nav.next == nil)
        #expect(nav.navigator == nil)
    }

    @Test("single-episode season yields nil/nil even for the present episode")
    func singleEpisode() {
        let api = MockAPIClient()
        let only = [makeEpisode(id: "ep-1", name: "One")]
        let nav = buildEpisodeNavigation(for: "ep-1", in: only, apiClient: api, userId: "u1")
        #expect(nav.previous == nil)
        #expect(nav.next == nil)
        #expect(nav.navigator == nil)
    }

    @Test("precomputeEpisodeRefs skips episodes without an id")
    func precomputeSkipsNilIDs() {
        let list = [
            makeEpisode(id: "ep-1", name: "One"),
            makeEpisode(id: nil, name: "Ghost"),
            makeEpisode(id: "ep-2", name: "Two")
        ]
        let (refs, indexByID) = precomputeEpisodeRefs(list)
        #expect(refs.map(\.id) == ["ep-1", "ep-2"])
        #expect(refs.map(\.title) == ["One", "Two"])
        #expect(indexByID == ["ep-1": 0, "ep-2": 1])
    }

    @Test("navigator resolves a target's playback info and neighbors, nil for unknown ids")
    func navigatorResolvesTarget() async {
        let api = MockAPIClient()
        let nav = buildEpisodeNavigation(for: "ep-1", in: episodes, apiClient: api, userId: "u1").navigator

        let resolved = await nav?("ep-3")
        // MockAPIClient echoes the requested itemId as mediaSourceId.
        #expect(resolved?.0.mediaSourceId == "ep-3")
        #expect(resolved?.1?.id == "ep-2") // new previous
        #expect(resolved?.2 == nil)        // last episode → no next

        let unknown = await nav?("nope")
        #expect(unknown == nil)
    }
}
