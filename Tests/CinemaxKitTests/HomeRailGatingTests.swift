import Foundation
import Testing
import JellyfinAPI
@testable import Cinemax
@testable import CinemaxKit

/// Lot 3 of the 2026-09-10 platform audit: the network a Home load actually
/// costs. Two separate rules are locked here — which rails are FETCHED at all
/// (P1), and which queries ask the server for a `totalRecordCount` (P2/P5).
@Suite("Home rail gating and request budget")
@MainActor
struct HomeRailGatingTests {

    private func makeItem(name: String) -> BaseItemDto {
        var item = BaseItemDto()
        item.id = name
        item.name = name
        return item
    }

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    /// Sets every `home.show*` key this test cares about, so a test never
    /// inherits the simulator's stored preferences (`SettingsKey.Default` only
    /// applies to an ABSENT key).
    private func setRails(
        nextUp: Bool = true, favorites: Bool = true, playlists: Bool = true,
        upcoming: Bool = true, collections: Bool = true,
        becauseYouWatched: Bool = true,
        genreRows: Bool = true, watchingNow: Bool = true
    ) {
        let defaults = UserDefaults.standard
        defaults.set(nextUp, forKey: SettingsKey.homeShowNextUp)
        defaults.set(favorites, forKey: SettingsKey.homeShowFavorites)
        defaults.set(playlists, forKey: SettingsKey.homeShowPlaylists)
        defaults.set(upcoming, forKey: SettingsKey.homeShowUpcoming)
        defaults.set(collections, forKey: SettingsKey.homeShowCollections)
        defaults.set(becauseYouWatched, forKey: SettingsKey.homeShowBecauseYouWatched)
        defaults.set(genreRows, forKey: SettingsKey.homeShowGenreRows)
        defaults.set(watchingNow, forKey: SettingsKey.homeShowWatchingNow)
    }

    private func clearRails() {
        let defaults = UserDefaults.standard
        for key in [
            SettingsKey.homeShowNextUp, SettingsKey.homeShowFavorites,
            SettingsKey.homeShowPlaylists, SettingsKey.homeShowUpcoming,
            SettingsKey.homeShowCollections, SettingsKey.homeShowBecauseYouWatched,
            SettingsKey.homeShowGenreRows, SettingsKey.homeShowWatchingNow,
        ] { defaults.removeObject(forKey: key) }
    }

    /// The query that seeds « Parce que vous avez vu … » — the only Home
    /// query carrying the `.isPlayed` filter.
    private func isSeedQuery(_ filters: [ItemFilter]?) -> Bool {
        filters?.contains(.isPlayed) == true
    }

    // MARK: - P1 — a rail that is off is not fetched

    @Test("a rail switched off issues no request for it")
    func disabledRailsAreNotFetched() async {
        setRails(nextUp: false, favorites: false, playlists: false,
                 upcoming: false, collections: false, becauseYouWatched: false,
                 genreRows: false, watchingNow: false)
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedResumeItems = [makeItem(name: "Resuming")]
        // A played item exists, so the rail WOULD have something to show —
        // the negative below is about the switch, not about an empty history.
        api.stubbedLastPlayedItems = [makeItem(name: "Watched")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(api.getNextUpEpisodesCallCount == 0)
        #expect(api.favoriteFetchCount == 0)
        #expect(api.getPlaylistsCallCount == 0)
        #expect(api.getGenresCallCount == 0)
        #expect(api.getItemsQueries.contains { $0.includeItemTypes == [.boxSet] } == false)
        #expect(api.getItemsQueries.contains { isSeedQuery($0.filters) } == false)
        #expect(api.getSimilarItemsCallCount == 0)

        // The hero is never gated, so the two rails that feed it are fetched
        // whatever their switch says — this is the load-bearing half of the
        // rule, and the reason `home.showContinueWatching` /
        // `home.showRecentlyAdded` are absent from the gate.
        #expect(api.getResumeItemsCallCount == 1)
        #expect(api.getItemsQueries.contains {
            $0.includeItemTypes == [.movie, .series] && $0.isFavorite == nil
        })
        #expect(vm.heroItem?.name == "Resuming")
    }

    @Test("every rail on: each one is fetched exactly once")
    func enabledRailsAreFetched() async {
        setRails()
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedGenres = ["Action"]
        api.stubbedLastPlayedItems = [makeItem(name: "Watched")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(api.getNextUpEpisodesCallCount == 1)
        #expect(api.favoriteFetchCount == 1)
        #expect(api.getPlaylistsCallCount == 1)
        #expect(api.getGenresCallCount == 1)
        #expect(api.getItemsQueries.filter { $0.includeItemTypes == [.boxSet] }.count == 1)
        #expect(api.getItemsQueries.filter { isSeedQuery($0.filters) }.count == 1)
        #expect(api.getSimilarItemsCallCount == 1)
    }

    /// The re-activation path: `HomeScreen` asks for one rail by name when its
    /// key flips back on, because `load()` skipped it and the row would
    /// otherwise stay empty until the next launch — a setting that looks broken.
    @Test("refreshRail fetches that rail alone, without a reload")
    func refreshRailIsTargeted() async {
        setRails()
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedUpcomingItems = [makeItem(name: "Airing soon")]
        let vm = HomeViewModel()
        let loadingBefore = vm.isLoading

        await vm.refreshRail(.upcoming, using: makeAppState(api: api))

        #expect(vm.upcomingItems.count == 1)
        // Nothing else moved: no resume, no genres, and crucially no
        // `isLoading` transition — flipping it is what swaps the body for the
        // skeleton and costs the user their scroll position. Compared against
        // the value before the call rather than against `false`, because a
        // fresh view model starts out loading.
        #expect(api.getResumeItemsCallCount == 0)
        #expect(api.getGenresCallCount == 0)
        #expect(vm.isLoading == loadingBefore)
    }

    // MARK: - « Parce que vous avez vu … » (#170)

    private func makeEpisode(id: String, seriesId: String, seriesName: String) -> BaseItemDto {
        var item = makeItem(name: id)
        item.type = .episode
        item.seriesID = seriesId
        item.seriesName = seriesName
        return item
    }

    private func makePlayed(_ name: String) -> BaseItemDto {
        var item = makeItem(name: name)
        var data = UserItemDataDto(key: "test")
        data.isPlayed = true
        item.userData = data
        return item
    }

    @Test("an episode seeds the rail with its SERIES; the seed query is one item, uncounted")
    func episodeSeedsItsSeries() async {
        setRails()
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedLastPlayedItems = [makeEpisode(id: "ep-4", seriesId: "arrow", seriesName: "Arrow")]
        api.stubbedSimilarItems = [makeItem(name: "Flash"), makeItem(name: "Legends")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(api.similarItemsRequests.map { $0.itemId } == ["arrow"])
        #expect(api.similarItemsRequests.first?.limit == HomeViewModel.becauseYouWatchedLimit)
        #expect(vm.becauseYouWatched?.seedTitle == "Arrow")
        #expect(vm.becauseYouWatched?.items.map(\.id) == ["Flash", "Legends"])

        let seed = api.getItemsQueries.first { isSeedQuery($0.filters) }
        #expect(seed?.includeItemTypes == [.movie, .episode])
        #expect(seed?.sortBy == [.datePlayed])
        #expect(seed?.sortOrder == [.descending])
        #expect(seed?.limit == 1)
        #expect(seed?.enableTotalRecordCount == false)
    }

    @Test("watched titles and anything in Continue Watching never reach the rail")
    func railExcludesWatchedAndInProgress() async {
        setRails()
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedLastPlayedItems = [makeItem(name: "Seed")]
        api.stubbedResumeItems = [
            makeEpisode(id: "show-ep", seriesId: "Show", seriesName: "Show"),
            makeItem(name: "Resumed film"),
        ]
        api.stubbedSimilarItems = [
            makeItem(name: "Seed"),          // the seed itself
            makePlayed("Already seen"),      // played
            makeItem(name: "Resumed film"),  // in Continue Watching
            makeItem(name: "Show"),          // series of a resumed episode
            makeItem(name: "Fresh"),
            makeItem(name: "Fresh"),         // duplicate
        ]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.becauseYouWatched?.items.map(\.id) == ["Fresh"])
    }

    @Test("with no played item the rail hides itself and asks for nothing similar")
    func railHiddenWithoutPlayedItem() async {
        setRails()
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedLastPlayedItems = []
        api.stubbedSimilarItems = [makeItem(name: "Orphan")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.becauseYouWatched == nil)
        #expect(api.getSimilarItemsCallCount == 0)
    }

    @Test("the rail hides itself when every similar title is filtered out")
    func railHiddenWhenEverythingFiltered() async {
        setRails()
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedLastPlayedItems = [makeItem(name: "Seed")]
        api.stubbedSimilarItems = [makePlayed("Seen 1"), makePlayed("Seen 2")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(api.getSimilarItemsCallCount == 1, "the control: the request did go out")
        #expect(vm.becauseYouWatched == nil)
    }

    @Test("refreshRail(.becauseYouWatched) fills the rail alone, without a reload")
    func refreshRailFillsBecauseYouWatched() async {
        setRails()
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedLastPlayedItems = [makeItem(name: "Seed")]
        api.stubbedSimilarItems = [makeItem(name: "Fresh")]
        let vm = HomeViewModel()
        let loadingBefore = vm.isLoading

        await vm.refreshRail(.becauseYouWatched, using: makeAppState(api: api))

        #expect(vm.becauseYouWatched?.items.map(\.id) == ["Fresh"])
        #expect(api.getResumeItemsCallCount == 0)
        #expect(api.getGenresCallCount == 0)
        #expect(vm.isLoading == loadingBefore)
    }

    /// Finishing a film posts tier-2, and that is precisely when the seed
    /// should move on to it.
    @Test("the tier-2 refresh re-seeds the rail")
    func tierTwoReseedsBecauseYouWatched() async {
        setRails()
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedLastPlayedItems = [makeItem(name: "First")]
        api.stubbedSimilarItems = [makeItem(name: "Like first")]
        let appState = makeAppState(api: api)
        let vm = HomeViewModel()

        await vm.load(using: appState)
        #expect(vm.becauseYouWatched?.seedTitle == "First")

        api.stubbedLastPlayedItems = [makeItem(name: "Second")]
        api.stubbedSimilarItems = [makeItem(name: "Like second")]
        await vm.refreshUserDataRails(using: appState)

        #expect(vm.becauseYouWatched?.seedTitle == "Second")
        #expect(vm.becauseYouWatched?.items.map(\.id) == ["Like second"])
        #expect(api.similarItemsRequests.map { $0.itemId } == ["First", "Second"])
    }

    @Test("switched off, the tier-2 refresh issues no request for the rail")
    func tierTwoSkipsDisabledBecauseYouWatched() async {
        setRails(becauseYouWatched: false)
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedLastPlayedItems = [makeItem(name: "Seed")]
        let vm = HomeViewModel()

        await vm.refreshUserDataRails(using: makeAppState(api: api))

        #expect(api.getResumeItemsCallCount == 1, "the control: the tier-2 refresh did run")
        #expect(api.getItemsQueries.contains { isSeedQuery($0.filters) } == false)
        #expect(api.getSimilarItemsCallCount == 0)
    }

    @Test("a movie seeds itself; an episode with no series seeds nothing")
    func seedRule() {
        let movie = makeItem(name: "Dune")
        #expect(HomeViewModel.becauseYouWatchedSeed(from: movie)?.id == "Dune")
        #expect(HomeViewModel.becauseYouWatchedSeed(from: movie)?.title == "Dune")

        var orphan = makeItem(name: "ep")
        orphan.type = .episode
        #expect(HomeViewModel.becauseYouWatchedSeed(from: orphan) == nil)
    }

    // MARK: - P2 / P5 — who asks the server to COUNT

    /// `totalRecordCount` is a second server-side query over the whole match.
    /// Home renders fixed-size pages and reads no total, so none of its
    /// `getItems` calls should ask for one.
    @Test("Home's getItems calls ask for no totalRecordCount")
    func homeAsksForNoCount() async {
        setRails()
        defer { clearRails() }

        let api = MockAPIClient()
        api.stubbedGenres = ["Action"]
        api.stubbedLastPlayedItems = [makeItem(name: "Watched")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        let counted = api.getItemsQueries.filter { $0.enableTotalRecordCount }
        #expect(counted.isEmpty, "Home asked for a count on \(counted.count) query/queries")
        #expect(api.getItemsQueries.isEmpty == false, "the assertion above must not pass vacuously")
        #expect(api.getItemsQueries.contains { isSeedQuery($0.filters) },
                "the « Parce que vous avez vu » seed query must be among those checked")
    }

    /// The paired control, and the half that must never regress: a caller that
    /// PAGINATES derives `hasLoadedAll` from the total, so a count of 0 would
    /// end pagination on the first page.
    @Test("a paginated grid keeps asking for the count")
    func paginatedGridKeepsCount() async {
        let api = MockAPIClient()
        api.stubbedItems = (0..<40).map { makeItem(name: "Item \($0)") }
        api.stubbedTotalCount = 120
        // `FavoritesScreen`'s own view model — the real `PaginatedLoader`
        // consumer, rather than a hand-rolled stand-in that could diverge.
        let vm = FavoritesViewModel()

        await vm.load(using: makeAppState(api: api))

        let favorites = api.getItemsQueries.filter { $0.isFavorite == true }
        #expect(favorites.isEmpty == false)
        #expect(favorites.allSatisfy { $0.enableTotalRecordCount })
        #expect(vm.loader.totalCount == 120)
        #expect(vm.loader.hasLoadedAll == false,
                "40 of 120 loaded — a count of 0 would have ended pagination here")
    }

    /// The library header prints « 503 films » off this very query, and it is
    /// the count BEFORE `limit` — which is exactly why `limit: 1` is enough for
    /// the hero and why the count must stay on.
    @Test("the library hero keeps the count while fetching a single item")
    func libraryHeroKeepsCount() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem(name: "Newest")]
        api.stubbedTotalCount = 503
        api.stubbedGenres = ["Action"]
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.loadInitial(using: makeAppState(api: api), loc: LocalizationManager())

        let heroQuery = api.getItemsQueries.first { $0.limit == 1 }
        #expect(heroQuery != nil, "the hero must fetch one item, not a page of 20")
        #expect(heroQuery?.enableTotalRecordCount == true)
        #expect(vm.totalCount == 503)
        #expect(vm.heroItem?.name == "Newest")
    }

    /// The library's own genre fan-out: one query per genre, up to 8, on every
    /// tab open in the default "browse" layout — and `GenreResult` keeps only
    /// `.items`. Measured on the reference server (2026-09-10), a COUNT costs
    /// ~3 ms on a 257-film genre slice and +42,9 ms on a 6 657-row match, so
    /// this is scaling insurance rather than a win on a small catalogue.
    @Test("the library genre rows ask for no totalRecordCount")
    func libraryGenreRowsAskForNoCount() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Action", "Drame"]
        api.stubbedItems = [makeItem(name: "Un film")]
        api.stubbedTotalCount = 503
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.loadInitial(using: makeAppState(api: api), loc: LocalizationManager())

        let genreQueries = api.getItemsQueries.filter { ($0.genres?.isEmpty == false) }
        #expect(genreQueries.isEmpty == false, "the fan-out must actually have run")
        #expect(genreQueries.allSatisfy { $0.enableTotalRecordCount == false })
        // Paired control: the hero query on the same load still counts, because
        // the header prints that total.
        #expect(api.getItemsQueries.contains { $0.genres == nil && $0.enableTotalRecordCount })
    }

    /// The search fan-out is the heaviest per-keystroke cost in the app: one
    /// request per significant word, none of which reads a total.
    @Test("the search fan-out asks for no totalRecordCount")
    func searchAsksForNoCount() async {
        let api = MockAPIClient()
        api.stubbedSearchResults = [makeItem(name: "Mission Impossible")]

        _ = await LibrarySearchRanker.rank(
            query: "mission impossible", userId: "user1",
            includeItemTypes: [.movie, .series, .episode], api: api
        )

        #expect(api.searchCountFlags.isEmpty == false)
        #expect(api.searchCountFlags.allSatisfy { $0 == false })
    }
}
