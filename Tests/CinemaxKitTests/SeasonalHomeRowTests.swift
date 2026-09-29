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

    private func item(_ id: String, _ kind: BaseItemKind = .movie) -> BaseItemDto {
        var i = BaseItemDto(); i.id = id; i.name = id; i.type = kind; return i
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

    @Test("A series tagged with the season's keyword joins the row without the genre")
    func taggedSeriesJoinsTheRow() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Horror"]
        api.stubbedLatestItems = [item("nosferatu"), item("scream")]
        api.stubbedTaggedItems = [item("mercredi", .series)]
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(SeasonRow(titleKey: "t", genreCandidates: ["Horror"], tagCandidates: ["halloween"]))
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.map(\.id) == ["nosferatu", "mercredi", "scream"])
        #expect(api.getItemsQueries.contains { $0.tags == ["halloween"] && $0.genres == nil })
    }

    @Test("Keywords alone fill the row when the library has no season genre")
    func tagsWithoutGenre() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Comédie"]
        api.stubbedTaggedItems = [item("hocus-pocus")]
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(SeasonRow(titleKey: "t", genreCandidates: ["Horror"], tagCandidates: ["halloween"]))
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.map(\.id) == ["hocus-pocus"])
    }

    @Test("Merge: keyword hits first, deduplicated, films and series alternate, capped")
    func mixAlternatesKinds() {
        let merged = SeasonRowMix.merge(
            tagged: [item("hp"), item("mercredi", .series)],
            genre: [item("a"), item("b"), item("hp"), item("c"), item("hill-house", .series)],
            limit: 5
        )
        #expect(merged.map(\.id) == ["hp", "mercredi", "a", "hill-house", "b"])
    }
}
