import Foundation
import Testing
import JellyfinAPI
@testable import Cinemax
@testable import CinemaxKit

@Suite("Seasonal Home row")
@MainActor
struct SeasonalHomeRowTests {
    private let defaults = UserDefaults.isolatedForTesting()
    private let row = SeasonRow(titleKey: "season.halloween.row", genreCandidates: ["Horror", "Horreur"])

    private func item(_ id: String) -> BaseItemDto {
        var i = BaseItemDto(); i.id = id; i.name = id; return i
    }

    private func appState(_ api: MockAPIClient) -> AppState {
        let s = AppState(apiClient: api, keychain: MockKeychain())
        s.currentUserId = "user1"
        return s
    }

    @Test("The row queries the server's spelling of the genre")
    func loadsMatchingGenre() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Action", "Horreur"]
        api.stubbedLatestItems = [item("nosferatu")]
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(row)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.map(\.id) == ["nosferatu"])
        #expect(api.getItemsQueries.contains { $0.genres == ["Horreur"] })
    }

    @Test("No matching genre hides the row")
    func noMatchingGenreHidesTheRow() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Comédie"]
        api.stubbedLatestItems = [item("x")]
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(row)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.isEmpty)
        #expect(!api.getItemsQueries.contains { $0.genres == ["Comédie"] })
    }

    @Test("A matching genre with no items hides the row")
    func emptyGenreHidesTheRow() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Horror"]
        api.stubbedLatestItems = []
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(row)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.isEmpty)
    }

    @Test("A network failure hides the row, no retry chip")
    func failureHidesTheRow() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Horror"]
        api.shouldThrow = true
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(row)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.isEmpty)
    }

    @Test("Out of season: no request at all")
    func outOfSeasonNoRequest() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Horror"]
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(nil)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.isEmpty)
        #expect(api.getGenresCallCount == 0)
    }

    @Test("A fetch that lands after the row changed never writes")
    func staleFetchDoesNotWrite() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Horror"]
        let entered = TestLatch(), release = TestLatch()
        let late = [item("late")]
        api.getItemsHandler = { _ in
            entered.open()
            await release.wait()
            return (late, 1)
        }
        let vm = HomeViewModel(defaults: defaults)
        let state = appState(api)
        vm.setSeasonRow(row)
        let first = Task { await vm.refreshSeasonRow(using: state) }
        await entered.wait()
        vm.setSeasonRow(nil)                      // the season ended meanwhile
        await vm.refreshSeasonRow(using: state)
        release.open()
        await first.value
        #expect(vm.seasonRowItems.isEmpty)
    }

    @Test("In season, the season row's genre is not repeated as a genre row")
    func seasonGenreNotDuplicated() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Action", "Horror"]
        api.stubbedLatestItems = [item("x")]
        HomeGenrePreferences.setSelectedGenres(["Action", "Horror"], in: defaults)
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(row)
        await vm.load(using: appState(api))
        #expect(vm.genreRows.map(\.genre) == ["Action"])
    }

    @Test("Out of season, the genre row stays")
    func genreRowOutOfSeason() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Action", "Horror"]
        api.stubbedLatestItems = [item("x")]
        HomeGenrePreferences.setSelectedGenres(["Action", "Horror"], in: defaults)
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(nil)
        await vm.load(using: appState(api))
        #expect(vm.genreRows.map(\.genre) == ["Action", "Horror"])
    }
}
