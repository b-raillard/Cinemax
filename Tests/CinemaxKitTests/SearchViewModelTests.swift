import Testing
import Foundation
import JellyfinAPI
@testable import CinemaxKit
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
        let vm = SearchViewModel(defaults: .isolatedForTesting())
        vm.searchText = "   "

        vm.search(using: makeAppState(api: api))
        // An empty query starts no search task at all; awaiting the (absent)
        // task proves nothing is left to fire.
        await vm.searchTask?.value

        #expect(vm.results.isEmpty)
        #expect(!vm.hasSearched)
        #expect(!vm.isSearching)
    }

    @Test("Successful search populates results and flips isSearching back to false")
    func successfulSearchCompletes() async {
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Dune")]
        let vm = SearchViewModel(defaults: .isolatedForTesting())
        vm.searchText = "Dune"

        vm.search(using: makeAppState(api: api))
        // Await the debounced task itself rather than outsleeping it.
        await vm.searchTask?.value

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
        let vm = SearchViewModel(defaults: .isolatedForTesting())
        vm.scope = .all
        vm.searchText = "Cillian Murphy"

        vm.search(using: makeAppState(api: api))
        await vm.searchTask?.value

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
        let vm = SearchViewModel(defaults: .isolatedForTesting())
        vm.scope = .movies
        vm.searchText = "Cillian Murphy"

        vm.search(using: makeAppState(api: api))
        await vm.searchTask?.value

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
        let vm = SearchViewModel(defaults: .isolatedForTesting())
        vm.searchText = "Oppenheimer"

        vm.search(using: makeAppState(api: api))
        await vm.searchTask?.value

        #expect(vm.results.count == 1)
        #expect(!vm.searchFailed)
        #expect(vm.personResults.isEmpty)
    }

    @Test("Emptying the query clears personResults too")
    func emptyQueryClearsPersons() async {
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(id: "1", name: "Oppenheimer")]
        api.stubbedPersonResults = [makeItem(id: "p1", name: "Cillian Murphy")]
        let vm = SearchViewModel(defaults: .isolatedForTesting())
        vm.searchText = "Cillian"
        vm.search(using: makeAppState(api: api))
        await vm.searchTask?.value
        #expect(!vm.personResults.isEmpty)

        vm.searchText = "  "
        vm.search(using: makeAppState(api: api))
        await vm.searchTask?.value

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
        let apiEntered = TestLatch()
        api.searchItemsHandler = { term in
            apiEntered.open()
            try? await Task.sleep(for: .milliseconds(300))
            return [BaseItemDto]()
        }
        let vm = SearchViewModel(defaults: .isolatedForTesting())
        let appState = makeAppState(api: api)

        // First query: debounce + 300 ms API. Will be cancelled once the API await starts.
        vm.searchText = "a"
        vm.search(using: appState)
        let firstSearch = vm.searchTask
        // The first task has passed its debounce and entered the API call.
        await apiEntered.wait()

        // Replace with a new query — this cancels the in-flight task.
        vm.searchText = "ab"
        vm.search(using: appState)

        // Both tasks have fully run, the cancelled one's `defer` included.
        await firstSearch?.value
        await vm.searchTask?.value

        #expect(!vm.isSearching)
    }

    @Test("API failure leaves isSearching false and results empty")
    func apiFailureClearsState() async {
        let api = MockAPIClient()
        api.searchItemsHandler = { _ in throw MockError.genericFailure }
        let vm = SearchViewModel(defaults: .isolatedForTesting())
        vm.searchText = "query"

        vm.search(using: makeAppState(api: api))
        await vm.searchTask?.value

        #expect(vm.results.isEmpty)
        #expect(!vm.isSearching)
    }

    @Test("fetchRandomMovie returns first item from API")
    func fetchRandomMovieReturnsItem() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem(id: "m1", name: "Arrival")]
        let vm = SearchViewModel(defaults: .isolatedForTesting())

        let result = await vm.fetchRandomMovie(using: makeAppState(api: api))

        #expect(result?.id == "m1")
    }

    @Test("fetchRandomMovie returns nil on error")
    func fetchRandomMovieNilOnError() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = SearchViewModel(defaults: .isolatedForTesting())

        let result = await vm.fetchRandomMovie(using: makeAppState(api: api))

        #expect(result == nil)
    }
}

// MARK: - Seerr section

private let searchSeerrURL = URL(string: "http://192.168.1.20:5055")!

/// Seerr's `/search` for « dune »: the 2021 film (owned by the bench library
/// below), the 1984 film, a series, and a person (dropped by the decoder).
private let duneSearchBody = """
{"page":1,"totalPages":1,"totalResults":4,"results":[
{"mediaType":"movie","id":438631,"title":"Dune","releaseDate":"2021-09-15"},
{"mediaType":"movie","id":841,"title":"Dune","releaseDate":"1984-12-14"},
{"mediaType":"tv","id":90228,"name":"Dune: Prophecy","firstAirDate":"2024-11-17"},
{"mediaType":"person","id":1,"name":"Frank Herbert"}]}
"""

/// A deadline that never fires (the tests hold Seerr with a latch instead),
/// released when the race cancels it.
private let neverExpires: @Sendable () async throws -> Void = {
    let never = TestLatch()
    await withTaskCancellationHandler { await never.wait() } onCancel: { never.open() }
}

/// Answers Seerr by path: the session's reload (`/settings/public`,
/// `/auth/me`), then `/search` — held by `gate` when one is given.
private final class SearchSeerrTransport: SeerrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private let searchReply: StubSeerrTransport.Reply
    private let gate: TestLatch?
    /// Opens when a `/search` request reaches the transport.
    let searchArrived = TestLatch()

    init(search: StubSeerrTransport.Reply, gate: TestLatch? = nil) {
        self.searchReply = search
        self.gate = gate
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        let path = request.url?.path.replacingOccurrences(of: "/api/v1", with: "") ?? ""
        let reply: StubSeerrTransport.Reply
        switch path {
        case "/settings/public":
            reply = .response(status: 200, body: #"{"mediaServerType":2,"partialRequestsEnabled":true}"#)
        case "/auth/me":
            reply = .response(status: 200, body: #"{"id":7,"permissions":32,"jellyfinUserId":"A","displayName":"Alice"}"#)
        case "/search":
            searchArrived.open()
            if let gate { await gate.wait() }
            reply = searchReply
        default:
            throw StubSeerrTransport.Exhausted()
        }
        switch reply {
        case .failure(let error):
            throw error
        case .response(let status, let headers, let body):
            let url = request.url ?? searchSeerrURL
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

/// Signed in as « A » on server S1, Seerr enabled for them, and a session
/// connected through a stored cookie — the state a search starts from.
@MainActor
private func seerrBench(api: MockAPIClient, transport: SearchSeerrTransport) async -> (AppState, SeerrSession) {
    let jellyfin = URL(string: "https://maison.local")!
    api.displayPreferences["me|\(SeerrUserConfig.preferencesId)|\(SeerrUserConfig.client)"] =
        SeerrUserConfig.merged(SeerrUserConfig(isEnabled: true, url: searchSeerrURL), into: nil)
    let keychain = MockKeychain()
    keychain.savedServers = [ServerEntry(
        id: "S1", name: "Maison", url: jellyfin, serverID: "srv",
        accessToken: "tokA", userId: "A", username: "A", lastUsedAt: Date(timeIntervalSince1970: 1_000))]
    keychain.savedActiveServerId = "S1"
    let app = AppState(apiClient: api, keychain: keychain)
    app.settingsDefaults = .isolatedForTesting()
    app.loadServersFromKeychain()
    app.serverURL = jellyfin
    app.hasServer = true
    app.isAuthenticated = true
    app.accessToken = "tokA"
    app.currentUserId = "A"
    var user = UserDto()
    user.id = "A"
    user.policy = UserPolicy(authenticationProviderID: "", passwordResetProviderID: "")
    app.currentUser = user

    let storage = MockKeychain()
    storage.saveSeerrSessions(["S1|A": SeerrBoundSecret(value: "abc", origin: searchSeerrURL)])
    let session = SeerrSession(storage: storage, defaults: .isolatedForTesting(), transport: transport, signInPause: {})
    session.proAllowsProvider = { true }
    session.activeAccountKeyProvider = { [app] in app.activeAccountKey }
    await session.reload(appState: app)
    return (app, session)
}

/// A library item carrying its TMDb id, as `searchItems` returns it when
/// asked for provider ids.
private func libraryItem(id: String, name: String, type: BaseItemKind, tmdb: String) -> BaseItemDto {
    var item = BaseItemDto()
    item.id = id
    item.name = name
    item.type = type
    item.providerIDs = ["Tmdb": tmdb]
    return item
}

@MainActor
@Suite("Search — Seerr section")
struct SearchSeerrSectionTests {

    private func makeViewModel(_ session: SeerrSession, allowed: Bool = true) -> SearchViewModel {
        let vm = SearchViewModel(defaults: .isolatedForTesting())
        vm.seerr = session
        vm.allowsSeerr = { allowed }
        vm.seerrDeadline = neverExpires
        return vm
    }

    @Test("the library results are on screen before Seerr answers, then the section follows")
    func seerrSectionAfterLibraryResults() async {
        let gate = TestLatch()
        let transport = SearchSeerrTransport(search: .response(status: 200, body: duneSearchBody), gate: gate)
        let api = MockAPIClient()
        api.stubbedSearchResults = [libraryItem(id: "lib-dune", name: "Dune", type: .movie, tmdb: "438631")]
        let (app, session) = await seerrBench(api: api, transport: transport)
        #expect(session.isVisible(proAllows: true, isOnline: true))
        let vm = makeViewModel(session)
        vm.searchText = "dune"

        vm.search(using: app)
        await transport.searchArrived.wait()

        // Seerr is held: the library is already written, the spinner gone,
        // and the section is a skeleton.
        #expect(vm.results.map(\.id) == ["lib-dune"])
        #expect(vm.hasSearched)
        #expect(!vm.isSearching)
        #expect(vm.seerrSection == .loading)
        // The TMDb ids were asked for, since the section was going to load.
        #expect(!api.searchProviderIdFlags.isEmpty)
        #expect(api.searchProviderIdFlags.allSatisfy { $0 })

        gate.open()
        await vm.searchTask?.value

        guard case .loaded(let missing) = vm.seerrSection else {
            Issue.record("expected a loaded section, got \(vm.seerrSection)")
            return
        }
        #expect(missing.map(\.id) == ["movie-841", "tv-90228"])
        #expect(vm.seerrSection(for: session.snapshot()) == vm.seerrSection)
    }

    @Test("a title the library owns is not listed again; ownership is per kind")
    func ownedTitleNotListedTwice() async {
        let transport = SearchSeerrTransport(search: .response(status: 200, body: duneSearchBody))
        let api = MockAPIClient()
        api.stubbedSearchResults = [
            libraryItem(id: "lib-dune", name: "Dune", type: .movie, tmdb: "438631"),
            // A SERIES with the 1984 film's TMDb id: TV and movie ids overlap,
            // so the film stays missing.
            libraryItem(id: "lib-other", name: "Dune", type: .series, tmdb: "841"),
        ]
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)
        vm.searchText = "dune"

        vm.search(using: app)
        await vm.searchTask?.value

        guard case .loaded(let missing) = vm.seerrSection else {
            Issue.record("expected a loaded section, got \(vm.seerrSection)")
            return
        }
        #expect(!missing.contains { $0.id == "movie-438631" })
        #expect(missing.map(\.id) == ["movie-841", "tv-90228"])
    }

    @Test("the scope chips filter the Seerr kinds too")
    func scopeFiltersSeerrKinds() async {
        let transport = SearchSeerrTransport(search: .response(status: 200, body: duneSearchBody))
        let api = MockAPIClient()
        api.stubbedSearchResults = [libraryItem(id: "lib-show", name: "Dune", type: .series, tmdb: "1")]
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)
        vm.scope = .series
        vm.searchText = "dune"

        vm.search(using: app)
        await vm.searchTask?.value

        #expect(vm.seerrSection == .loaded([
            SeerrMissingTitle(title: SeerrTitle(kind: .tv, tmdbId: 90228, title: "Dune: Prophecy", year: 2024), badge: .request),
        ]))
    }

    @Test("an unreachable Seerr shows nothing and leaves the library results alone")
    func unreachableSeerrShowsNothing() async {
        let transport = SearchSeerrTransport(search: .failure(URLError(.cannotConnectToHost)))
        let api = MockAPIClient()
        api.stubbedSearchResults = [libraryItem(id: "lib-dune", name: "Dune", type: .movie, tmdb: "438631")]
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)
        vm.searchText = "dune"

        vm.search(using: app)
        await vm.searchTask?.value

        #expect(vm.seerrSection == .hidden)
        #expect(vm.results.map(\.id) == ["lib-dune"])
        #expect(!vm.searchFailed)
    }

    @Test("a profile switch while Seerr answers drops the section")
    func profileSwitchDropsSeerrSection() async {
        let gate = TestLatch()
        let transport = SearchSeerrTransport(search: .response(status: 200, body: duneSearchBody), gate: gate)
        let api = MockAPIClient()
        api.stubbedSearchResults = [libraryItem(id: "lib-dune", name: "Dune", type: .movie, tmdb: "438631")]
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)
        vm.searchText = "dune"

        vm.search(using: app)
        await transport.searchArrived.wait()
        #expect(vm.seerrSection == .loading)

        // Another profile of the same server takes over, its reload runs.
        app.currentUserId = "B"
        await session.reload(appState: app)
        gate.open()
        await vm.searchTask?.value

        // Never loaded: the answer belonged to the previous profile — and the
        // skeleton does not wait for the next one to become visible.
        #expect(vm.seerrSection == .hidden)
    }

    @Test("a section is drawn only for the account it was loaded for")
    func sectionShownOnlyToItsAccount() async {
        let transport = SearchSeerrTransport(search: .response(status: 200, body: duneSearchBody))
        let api = MockAPIClient()
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)
        vm.searchText = "dune"

        vm.search(using: app)
        await vm.searchTask?.value

        #expect(vm.seerrSection != .hidden)
        #expect(vm.seerrSection(for: SeerrSession.Snapshot(accountKey: "S1|B", generation: 99)) == .hidden)
        #expect(vm.seerrSection(for: nil) == .hidden)
    }

    @Test("not allowed: no Seerr call at all, no TMDb ids asked for")
    func notAllowedMakesNoSeerrCall() async {
        let transport = SearchSeerrTransport(search: .response(status: 200, body: duneSearchBody))
        let api = MockAPIClient()
        api.stubbedSearchResults = [libraryItem(id: "lib-dune", name: "Dune", type: .movie, tmdb: "438631")]
        let (app, session) = await seerrBench(api: api, transport: transport)
        let afterReload = transport.requests.count
        let vm = makeViewModel(session, allowed: false)
        vm.searchText = "dune"

        vm.search(using: app)
        await vm.searchTask?.value

        #expect(vm.results.map(\.id) == ["lib-dune"])
        #expect(vm.seerrSection == .hidden)
        #expect(transport.requests.count == afterReload)
        #expect(api.searchProviderIdFlags.allSatisfy { !$0 })
    }

    @Test("emptying the query hides the section")
    func emptyQueryHidesSection() async {
        let transport = SearchSeerrTransport(search: .response(status: 200, body: duneSearchBody))
        let (app, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let vm = makeViewModel(session)
        vm.searchText = "dune"
        vm.search(using: app)
        await vm.searchTask?.value
        #expect(vm.seerrSection != .hidden)

        vm.searchText = ""
        vm.search(using: app)

        #expect(vm.seerrSection == .hidden)
    }
}
