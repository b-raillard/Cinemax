import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

@MainActor
@Suite("FavoritesViewModel")
struct FavoritesViewModelTests {

    private func makeItem(_ name: String) -> BaseItemDto {
        var item = BaseItemDto()
        item.name = name
        return item
    }

    private func makeAppState(api: MockAPIClient, userId: String? = "user1") -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = userId
        return appState
    }

    @Test("load populates items from the favorites query")
    func loadPopulatesItems() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem("Arrival"), makeItem("Blade Runner 2049")]
        let vm = FavoritesViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.items.count == 2)
        #expect(!vm.isLoading)
        #expect(!vm.loadFailed)
    }

    @Test("load failure flags loadFailed and leaves items empty")
    func loadFailureFlagsError() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = FavoritesViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.items.isEmpty)
        #expect(vm.loadFailed)
        #expect(!vm.isLoading)
    }

    @Test("load without userId is a no-op")
    func loadWithoutUserIdNoop() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem("Dune")]
        let vm = FavoritesViewModel()

        await vm.load(using: makeAppState(api: api, userId: nil))

        #expect(vm.items.isEmpty)
    }

    @Test("loadInitial only fetches once across reappearances")
    func loadInitialGuardsRefetch() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem("Sicario")]
        let vm = FavoritesViewModel()
        let appState = makeAppState(api: api)

        await vm.loadInitial(using: appState)
        #expect(vm.items.count == 1)

        // A second loadInitial (screen reappearance) must NOT re-hit the API,
        // even if the stub changed underneath.
        api.stubbedItems = [makeItem("A"), makeItem("B"), makeItem("C")]
        await vm.loadInitial(using: appState)
        #expect(vm.items.count == 1)
    }
}
