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
}
