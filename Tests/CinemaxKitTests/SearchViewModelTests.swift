import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

@MainActor
@Suite("SearchViewModel")
struct SearchViewModelTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    private func makeItem(id: String, name: String) -> BaseItemDto {
        var item = BaseItemDto()
        item.id = id
        item.name = name
        return item
    }

    @Test("Empty query resets results and skips network call")
    func emptyQueryIsNoop() async {
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Inception")]
        let vm = SearchViewModel()
        vm.searchText = "   "

        vm.search(using: makeAppState(api: api))
        // Give the debounce ample time to fire (or not).
        try? await Task.sleep(for: .milliseconds(500))

        #expect(vm.results.isEmpty)
        #expect(!vm.hasSearched)
        #expect(!vm.isSearching)
    }

    @Test("Successful search populates results and flips isSearching back to false")
    func successfulSearchCompletes() async {
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Dune")]
        let vm = SearchViewModel()
        vm.searchText = "Dune"

        vm.search(using: makeAppState(api: api))
        // Debounce is 400 ms; wait longer so the Task completes.
        try? await Task.sleep(for: .milliseconds(700))

        #expect(vm.results.count == 1)
        #expect(vm.hasSearched)
        #expect(!vm.isSearching)
    }

    // MARK: - Person row

    @Test("Search in the All scope populates personResults")
    func personsPopulatedInAllScope() async {
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Oppenheimer")]
        api.stubbedPersonResults = [makeItem(id: "p1", name: "Cillian Murphy")]
        let vm = SearchViewModel()
        vm.scope = .all
        vm.searchText = "Cillian Murphy"

        vm.search(using: makeAppState(api: api))
        try? await Task.sleep(for: .milliseconds(700))

        #expect(vm.personResults.map(\.id) == ["p1"])
    }

    /// A type filter that shows something other than the requested type isn't a
    /// filter. Narrowing to Movies must not surface people — and must not spend
    /// a request finding out.
    @Test("Narrowed scopes skip the person fetch entirely")
    func personsSkippedOutsideAllScope() async {
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Oppenheimer")]
        api.stubbedPersonResults = [makeItem(id: "p1", name: "Cillian Murphy")]
        let vm = SearchViewModel()
        vm.scope = .movies
        vm.searchText = "Cillian Murphy"

        vm.search(using: makeAppState(api: api))
        try? await Task.sleep(for: .milliseconds(700))

        #expect(vm.personResults.isEmpty)
        #expect(api.searchPersonsCallCount == 0)
    }

    /// The person row is additive: losing it must never cost the user their
    /// title results, nor raise the retryable error state.
    @Test("A failing person fetch leaves title results and searchFailed intact")
    func personFailureDoesNotBreakTitles() async {
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Oppenheimer")]
        api.searchPersonsHandler = { _ in throw MockError.genericFailure }
        let vm = SearchViewModel()
        vm.searchText = "Oppenheimer"

        vm.search(using: makeAppState(api: api))
        try? await Task.sleep(for: .milliseconds(700))

        #expect(vm.results.count == 1)
        #expect(!vm.searchFailed)
        #expect(vm.personResults.isEmpty)
    }

    @Test("Emptying the query clears personResults too")
    func emptyQueryClearsPersons() async {
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Oppenheimer")]
        api.stubbedPersonResults = [makeItem(id: "p1", name: "Cillian Murphy")]
        let vm = SearchViewModel()
        vm.searchText = "Cillian"
        vm.search(using: makeAppState(api: api))
        try? await Task.sleep(for: .milliseconds(700))
        #expect(!vm.personResults.isEmpty)

        vm.searchText = "  "
        vm.search(using: makeAppState(api: api))
        try? await Task.sleep(for: .milliseconds(500))

        #expect(vm.personResults.isEmpty)
    }

    /// Regression for the defer-guarded `isSearching = false` in `SearchViewModel.search`.
    /// When a new `search()` call cancels a task that was mid-await, the `defer` must
    /// still fire so the spinner flips off. Previously the flag could stay stuck at
    /// true if the cancellation landed between `isSearching = true` and the first
    /// `Task.isCancelled` guard after the API call.
    @Test("Cancelled search does not leave isSearching stuck on")
    func cancelledSearchClearsIsSearching() async {
        let api = MockAPIClient()
        api.searchItemsHandler = { term in
            try? await Task.sleep(for: .milliseconds(300))
            return [BaseItemDto]()
        }
        let vm = SearchViewModel()
        let appState = makeAppState(api: api)

        // First query: debounce + 300 ms API. Will be cancelled once the API await starts.
        vm.searchText = "a"
        vm.search(using: appState)
        // Let the first task pass its debounce and enter the API call.
        try? await Task.sleep(for: .milliseconds(450))

        // Replace with a new query — this cancels the in-flight task.
        vm.searchText = "ab"
        vm.search(using: appState)

        // Let the second task fully complete.
        try? await Task.sleep(for: .milliseconds(900))

        #expect(!vm.isSearching)
    }

    @Test("API failure leaves isSearching false and results empty")
    func apiFailureClearsState() async {
        let api = MockAPIClient()
        api.searchItemsHandler = { _ in throw MockError.genericFailure }
        let vm = SearchViewModel()
        vm.searchText = "query"

        vm.search(using: makeAppState(api: api))
        try? await Task.sleep(for: .milliseconds(700))

        #expect(vm.results.isEmpty)
        #expect(!vm.isSearching)
    }

    @Test("fetchRandomMovie returns first item from API")
    func fetchRandomMovieReturnsItem() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem(id: "m1", name: "Arrival")]
        let vm = SearchViewModel()

        let result = await vm.fetchRandomMovie(using: makeAppState(api: api))

        #expect(result?.id == "m1")
    }

    @Test("fetchRandomMovie returns nil on error")
    func fetchRandomMovieNilOnError() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = SearchViewModel()

        let result = await vm.fetchRandomMovie(using: makeAppState(api: api))

        #expect(result == nil)
    }
}
