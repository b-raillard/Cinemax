import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Free function so it can be called from the non-isolated `@Sendable`
/// `getEpisodesHandler` closure without crossing actor boundaries.
private func makeSeasonEpisode(id: String, name: String) -> BaseItemDto {
    var ep = BaseItemDto()
    ep.id = id
    ep.name = name
    return ep
}

@MainActor
@Suite("HomeViewModel")
struct HomeViewModelTests {

    private func makeItem(name: String) -> BaseItemDto {
        var item = BaseItemDto()
        item.name = name
        return item
    }

    private func makeAppState(api: MockAPIClient, userId: String? = "user1") -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = userId
        return appState
    }

    // MARK: - Loading

    @Test("load() without userId returns early without fetching")
    func loadWithoutUserIdIsNoop() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api, userId: nil)
        let vm = HomeViewModel()

        await vm.load(using: appState)

        // isLoading stays true (no userId → early return before setting false)
        #expect(vm.resumeItems.isEmpty)
        #expect(vm.latestItems.isEmpty)
    }

    @Test("load() populates resumeItems and latestItems from API")
    func loadPopulatesItems() async {
        let api = MockAPIClient()
        api.stubbedResumeItems = [makeItem(name: "Inception"), makeItem(name: "Interstellar")]
        api.stubbedLatestItems = [makeItem(name: "Dune")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.resumeItems.count == 2)
        #expect(vm.latestItems.count == 1)
        #expect(!vm.isLoading)
    }

    @Test("heroItem is set to first resumeItem when available")
    func heroItemFromResumeItems() async {
        let api = MockAPIClient()
        api.stubbedResumeItems = [makeItem(name: "Featured")]
        api.stubbedLatestItems = [makeItem(name: "Latest")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.heroItem?.name == "Featured")
    }

    @Test("heroItem falls back to latestItems when resumeItems is empty")
    func heroItemFallsBackToLatest() async {
        let api = MockAPIClient()
        api.stubbedResumeItems = []
        api.stubbedLatestItems = [makeItem(name: "Latest")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.heroItem?.name == "Latest")
    }

    @Test("load() populates nextUpItems from the global Next Up endpoint")
    func loadPopulatesNextUp() async {
        let api = MockAPIClient()
        api.stubbedNextUpItems = [makeItem(name: "S01E02"), makeItem(name: "S03E01")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.nextUpItems.count == 2)
        #expect(!vm.isLoading)
    }

    @Test("load() builds Next Up episode navigation with prev/next refs")
    func loadBuildsNextUpNavigation() async {
        let api = MockAPIClient()
        // Next Up surfaces episode 2 of a three-episode season.
        var nextUp = BaseItemDto()
        nextUp.id = "ep-2"
        nextUp.name = "Episode 2"
        nextUp.type = .episode
        nextUp.seasonID = "season-1"
        nextUp.seriesID = "series-1"
        api.stubbedNextUpItems = [nextUp]
        api.getEpisodesHandler = { seasonId in
            guard seasonId == "season-1" else { return [] }
            return [
                makeSeasonEpisode(id: "ep-1", name: "Episode 1"),
                makeSeasonEpisode(id: "ep-2", name: "Episode 2"),
                makeSeasonEpisode(id: "ep-3", name: "Episode 3"),
            ]
        }
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        let nav = vm.nextUpNavigation["ep-2"]
        #expect(nav != nil)
        #expect(nav?.previous?.id == "ep-1")
        #expect(nav?.next?.id == "ep-3")
        #expect(nav?.navigator != nil)
    }

    @Test("Next Up fetch failure leaves nextUpItems empty without failing the load")
    func nextUpFailureIsIsolated() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.nextUpItems.isEmpty)
        #expect(!vm.isLoading)
    }

    @Test("API failures leave collections empty and set isLoading false")
    func apiFailureLeavesCollectionsEmpty() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.resumeItems.isEmpty)
        #expect(vm.latestItems.isEmpty)
        #expect(!vm.isLoading)
    }

    // MARK: - Targeted userData refresh

    @Test("refreshUserDataRails re-fetches only resume/nextUp/favorites, not genre/latest")
    func refreshUserDataRailsIsTargeted() async {
        let api = MockAPIClient()
        api.stubbedResumeItems = [makeItem(name: "Resuming")]
        api.stubbedNextUpItems = [makeItem(name: "NextUp")]
        let vm = HomeViewModel()

        await vm.refreshUserDataRails(using: makeAppState(api: api))

        // Hit exactly the three userData rails, once each.
        #expect(api.getResumeItemsCallCount == 1)
        #expect(api.getNextUpEpisodesCallCount == 1)
        #expect(api.favoriteFetchCount == 1)
        // Left the heavy catalogue fetches untouched.
        #expect(api.getLatestMediaCallCount == 0)
        #expect(api.getGenresCallCount == 0)
        // And the rails reflect server truth.
        #expect(vm.resumeItems.count == 1)
        #expect(vm.nextUpItems.count == 1)
    }

    // MARK: - Genre retry (stale-index regression)
    //
    // `retryGenre` suspends on the fetch; `genreRows` can be emptied or
    // reordered meanwhile (pull-to-refresh, a genre-selection change, another
    // retry chip). Reusing the pre-await index crashed with "Index out of
    // range" or wrote into the wrong row.

    @Test("retryGenre bails silently when its row disappears during the fetch")
    func retryGenreRowRemovedMidFlight() async {
        let api = MockAPIClient()
        let vm = HomeViewModel()
        vm.genreRows = [GenreRow(genre: "Action", state: .failed),
                        GenreRow(genre: "Comedy", state: .failed)]
        // Runs while `retryGenre` is suspended — same effect as a concurrent
        // `loadGenreRows` wiping the rows.
        api.getItemsHandler = { _ in
            await MainActor.run { vm.genreRows = [] }
            return ([], 0)
        }

        await vm.retryGenre("Action", using: makeAppState(api: api))

        #expect(vm.genreRows.isEmpty)
    }

    @Test("retryGenre re-resolves the index when rows shift during the fetch")
    func retryGenreIndexShiftsMidFlight() async {
        let api = MockAPIClient()
        let vm = HomeViewModel()
        vm.genreRows = [GenreRow(genre: "Action", state: .failed),
                        GenreRow(genre: "Comedy", state: .failed),
                        GenreRow(genre: "Drama", state: .failed)]
        // Drop the row ahead of the retried one: "Drama" moves from index 2 to 1
        // and the old index would now be out of bounds.
        api.getItemsHandler = { _ in
            await MainActor.run { vm.genreRows.removeFirst() }
            return ([makeSeasonEpisode(id: "d1", name: "Dramatic")], 1)
        }

        await vm.retryGenre("Drama", using: makeAppState(api: api))

        #expect(vm.genreRows.map(\.genre) == ["Comedy", "Drama"])
        #expect(vm.genreRows.first(where: { $0.genre == "Drama" })?.state != .failed)
        #expect(vm.genreRows.first(where: { $0.genre == "Comedy" })?.state == .failed)
    }

    @Test("retryGenre no-ops when the genre isn't in genreRows at all")
    func retryGenreUnknownGenre() async {
        let api = MockAPIClient()
        let vm = HomeViewModel()
        vm.genreRows = [GenreRow(genre: "Action", state: .failed)]

        await vm.retryGenre("Comedy", using: makeAppState(api: api))

        #expect(vm.genreRows.count == 1)
        #expect(vm.genreRows[0].state == .failed)
        #expect(api.getItemsCalls.isEmpty)
    }
}

/// Tri-state sentinel: a missing/empty `home.selectedGenres` string means
/// "never configured" (→ deterministic default prefix) while an explicit `[]`
/// means "configured, zero rows". Locks that empty-string ≠ empty-array.
@Suite("HomeGenrePreferences", .serialized)
struct HomeGenrePreferencesTests {

    private let key = SettingsKey.homeSelectedGenres

    private func clear() { UserDefaults.standard.removeObject(forKey: key) }

    @Test("missing key → not configured, renders the default prefix")
    func unconfiguredMissing() {
        clear(); defer { clear() }
        #expect(HomeGenrePreferences.isConfigured() == false)
        let available = ["Action", "Comedy", "Drama", "Fantasy", "Horror", "Mystery", "Romance"]
        #expect(HomeGenrePreferences.effectiveGenres(available: available)
                == Array(available.prefix(HomeGenrePreferences.defaultRowCount)))
    }

    @Test("empty-string value is still treated as unconfigured")
    func emptyStringUnconfigured() {
        clear(); defer { clear() }
        UserDefaults.standard.set("", forKey: key)
        #expect(HomeGenrePreferences.isConfigured() == false)
        #expect(HomeGenrePreferences.effectiveGenres(available: ["Action", "Comedy"]) == ["Action", "Comedy"])
    }

    @Test("explicit empty array is configured and yields zero rows")
    func explicitEmptyArray() {
        clear(); defer { clear() }
        HomeGenrePreferences.setSelectedGenres([])
        #expect(HomeGenrePreferences.isConfigured() == true)
        #expect(HomeGenrePreferences.effectiveGenres(available: ["Action", "Comedy"]).isEmpty)
    }

    @Test("explicit picks intersect availability and follow canonical order")
    func explicitPicks() {
        clear(); defer { clear() }
        HomeGenrePreferences.setSelectedGenres(["Horror", "Action", "Unavailable"])
        #expect(HomeGenrePreferences.isConfigured() == true)
        let available = ["Action", "Comedy", "Drama", "Horror"]
        #expect(HomeGenrePreferences.effectiveGenres(available: available) == ["Action", "Horror"])
    }
}
