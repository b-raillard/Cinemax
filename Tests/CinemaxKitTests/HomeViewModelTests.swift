import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

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
}
