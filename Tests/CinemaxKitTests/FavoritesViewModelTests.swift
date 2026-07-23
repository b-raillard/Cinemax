import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Free (non-isolated) helpers so they can be called from inside the
/// `@Sendable` `MockAPIClient.getItemsHandler` closures without an
/// actor-isolation hop — mirrors `makeSeasonEpisode` in HomeViewModelTests.
private func makeItem(_ name: String) -> BaseItemDto {
    var item = BaseItemDto()
    item.name = name
    return item
}

private func makeItems(_ count: Int, prefix: String = "Item") -> [BaseItemDto] {
    (0..<count).map { makeItem("\(prefix) \($0)") }
}

@MainActor
@Suite("FavoritesViewModel")
struct FavoritesViewModelTests {

    private func makeAppState(api: MockAPIClient, userId: String? = "user1") -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = userId
        return appState
    }

    @Test("load populates the loader from the favorites query")
    func loadPopulatesItems() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem("Arrival"), makeItem("Blade Runner 2049")]
        api.stubbedTotalCount = 2
        let vm = FavoritesViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.loader.items.count == 2)
        #expect(!vm.isLoading)
        #expect(!vm.loadFailed)
    }

    @Test("load failure flags loadFailed and leaves the loader empty")
    func loadFailureFlagsError() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = FavoritesViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.loader.items.isEmpty)
        #expect(vm.loadFailed)
        #expect(!vm.isLoading)
    }

    @Test("load without userId is a no-op")
    func loadWithoutUserIdNoop() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem("Dune")]
        let vm = FavoritesViewModel()

        await vm.load(using: makeAppState(api: api, userId: nil))

        #expect(vm.loader.items.isEmpty)
    }

    @Test("loadInitial only fetches once across reappearances")
    func loadInitialGuardsRefetch() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem("Sicario")]
        api.stubbedTotalCount = 1
        let vm = FavoritesViewModel()
        let appState = makeAppState(api: api)

        await vm.loadInitial(using: appState)
        #expect(vm.loader.items.count == 1)

        // A second loadInitial (screen reappearance) must NOT re-hit the API,
        // even if the stub changed underneath.
        api.stubbedItems = [makeItem("A"), makeItem("B"), makeItem("C")]
        await vm.loadInitial(using: appState)
        #expect(vm.loader.items.count == 1)
    }

    // MARK: - Pagination

    @Test("first page requests 40 items at startIndex 0 and leaves hasLoadedAll false when more remain")
    func firstPageRequestsFortyItems() async {
        let api = MockAPIClient()
        api.stubbedItems = makeItems(40)
        api.stubbedTotalCount = 97
        let vm = FavoritesViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.loader.items.count == 40)
        #expect(!vm.loader.hasLoadedAll)
        #expect(api.getItemsCalls.count == 1)
        #expect(api.getItemsCalls.first?.startIndex == 0)
        #expect(api.getItemsCalls.first?.limit == 40)
    }

    @Test("loadMore appends page 2 starting at index 40")
    func loadMoreAppendsPageTwo() async {
        let api = MockAPIClient()
        api.getItemsHandler = { startIndex in
            if startIndex == 0 {
                return (makeItems(40, prefix: "Page1"), 60)
            }
            return (makeItems(20, prefix: "Page2"), 60)
        }
        let vm = FavoritesViewModel()
        let appState = makeAppState(api: api)

        await vm.load(using: appState)
        #expect(vm.loader.items.count == 40)

        await vm.loadMore(using: appState)

        #expect(vm.loader.items.count == 60)
        #expect(vm.loader.hasLoadedAll)
        #expect(api.getItemsCalls.count == 2)
        #expect(api.getItemsCalls[1].startIndex == 40)
        #expect(api.getItemsCalls[1].limit == 40)
    }

    @Test("a fetch failure on the first page sets loadFailed")
    func firstPageFailureSetsLoadFailed() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = FavoritesViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.loadFailed)
        #expect(vm.loader.items.isEmpty)
    }

    @Test("a successful reload after a prior failure clears loadFailed")
    func reloadClearsLoadFailed() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = FavoritesViewModel()
        let appState = makeAppState(api: api)

        await vm.load(using: appState)
        #expect(vm.loadFailed)

        api.shouldThrow = false
        api.stubbedItems = [makeItem("Recovered")]
        api.stubbedTotalCount = 1
        await vm.load(using: appState)

        #expect(!vm.loadFailed)
        #expect(vm.loader.items.count == 1)
    }

    @Test("a reset-on-notification reload (load) restarts from page 0")
    func reloadResetsToPageZero() async {
        let api = MockAPIClient()
        api.stubbedItems = makeItems(40)
        api.stubbedTotalCount = 97
        let vm = FavoritesViewModel()
        let appState = makeAppState(api: api)

        await vm.load(using: appState)
        await vm.loadMore(using: appState)
        #expect(vm.loader.items.count == 80)

        // Simulate a catalogue notification: `load` must reset the paginator
        // before re-fetching, not simply append another page on top.
        api.stubbedItems = makeItems(5, prefix: "Fresh")
        api.stubbedTotalCount = 5
        await vm.load(using: appState)

        #expect(vm.loader.items.count == 5)
        #expect(vm.loader.hasLoadedAll)
        #expect(api.getItemsCalls.last?.startIndex == 0)
    }
}

// MARK: - WatchedHistoryViewModel

@MainActor
@Suite("WatchedHistoryViewModel")
struct WatchedHistoryViewModelTests {

    private func makeAppState(api: MockAPIClient, userId: String? = "user1") -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = userId
        return appState
    }

    @Test("load populates the loader from the watched-history query")
    func loadPopulatesItems() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem("Arrival"), makeItem("Dune")]
        api.stubbedTotalCount = 2
        let vm = WatchedHistoryViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.loader.items.count == 2)
        #expect(!vm.isLoading)
        #expect(!vm.loadFailed)
    }

    @Test("load failure flags loadFailed and leaves the loader empty")
    func loadFailureFlagsError() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = WatchedHistoryViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.loader.items.isEmpty)
        #expect(vm.loadFailed)
        #expect(!vm.isLoading)
    }

    @Test("load without userId is a no-op")
    func loadWithoutUserIdNoop() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem("Dune")]
        let vm = WatchedHistoryViewModel()

        await vm.load(using: makeAppState(api: api, userId: nil))

        #expect(vm.loader.items.isEmpty)
    }

    @Test("loadInitial only fetches once across reappearances")
    func loadInitialGuardsRefetch() async {
        let api = MockAPIClient()
        api.stubbedItems = [makeItem("Sicario")]
        api.stubbedTotalCount = 1
        let vm = WatchedHistoryViewModel()
        let appState = makeAppState(api: api)

        await vm.loadInitial(using: appState)
        #expect(vm.loader.items.count == 1)

        api.stubbedItems = [makeItem("A"), makeItem("B"), makeItem("C")]
        await vm.loadInitial(using: appState)
        #expect(vm.loader.items.count == 1)
    }

    @Test("first page requests 40 items at startIndex 0 and leaves hasLoadedAll false when more remain")
    func firstPageRequestsFortyItems() async {
        let api = MockAPIClient()
        api.stubbedItems = makeItems(40)
        api.stubbedTotalCount = 97
        let vm = WatchedHistoryViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.loader.items.count == 40)
        #expect(!vm.loader.hasLoadedAll)
        #expect(api.getItemsCalls.count == 1)
        #expect(api.getItemsCalls.first?.startIndex == 0)
        #expect(api.getItemsCalls.first?.limit == 40)
    }

    @Test("loadMore appends page 2 starting at index 40")
    func loadMoreAppendsPageTwo() async {
        let api = MockAPIClient()
        api.getItemsHandler = { startIndex in
            if startIndex == 0 {
                return (makeItems(40, prefix: "Page1"), 60)
            }
            return (makeItems(20, prefix: "Page2"), 60)
        }
        let vm = WatchedHistoryViewModel()
        let appState = makeAppState(api: api)

        await vm.load(using: appState)
        #expect(vm.loader.items.count == 40)

        await vm.loadMore(using: appState)

        #expect(vm.loader.items.count == 60)
        #expect(vm.loader.hasLoadedAll)
        #expect(api.getItemsCalls.count == 2)
        #expect(api.getItemsCalls[1].startIndex == 40)
        #expect(api.getItemsCalls[1].limit == 40)
    }

    @Test("a fetch failure on the first page sets loadFailed")
    func firstPageFailureSetsLoadFailed() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = WatchedHistoryViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.loadFailed)
        #expect(vm.loader.items.isEmpty)
    }

    @Test("a reset-on-notification reload (load) restarts from page 0")
    func reloadResetsToPageZero() async {
        let api = MockAPIClient()
        api.stubbedItems = makeItems(40)
        api.stubbedTotalCount = 97
        let vm = WatchedHistoryViewModel()
        let appState = makeAppState(api: api)

        await vm.load(using: appState)
        await vm.loadMore(using: appState)
        #expect(vm.loader.items.count == 80)

        api.stubbedItems = makeItems(5, prefix: "Fresh")
        api.stubbedTotalCount = 5
        await vm.load(using: appState)

        #expect(vm.loader.items.count == 5)
        #expect(vm.loader.hasLoadedAll)
        #expect(api.getItemsCalls.last?.startIndex == 0)
    }
}

// MARK: - PaginatedLoader (pure logic)

@MainActor
@Suite("PaginatedLoader")
struct PaginatedLoaderTests {

    @Test("first loadMore replaces items and computes hasLoadedAll false when more remain")
    func firstPageReplaces() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)

        await loader.loadMore { startIndex in
            #expect(startIndex == 0)
            return (items: [1, 2], total: 5)
        }

        #expect(loader.items == [1, 2])
        #expect(loader.totalCount == 5)
        #expect(!loader.hasLoadedAll)
        #expect(!loader.isLoadingMore)
    }

    @Test("subsequent loadMore appends at the current item count and flips hasLoadedAll when exhausted")
    func appendsAndFlipsHasLoadedAll() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)

        await loader.loadMore { _ in (items: [1, 2], total: 5) }
        await loader.loadMore { startIndex in
            #expect(startIndex == 2)
            return (items: [3, 4], total: 5)
        }
        #expect(loader.items == [1, 2, 3, 4])
        #expect(!loader.hasLoadedAll)

        await loader.loadMore { startIndex in
            #expect(startIndex == 4)
            return (items: [5], total: 5)
        }
        #expect(loader.items == [1, 2, 3, 4, 5])
        #expect(loader.hasLoadedAll)
    }

    @Test("loadMore is a no-op while a fetch is already marked in-flight")
    func guardsReentrancyWhileLoading() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        loader.isLoadingMore = true

        var fetchCalled = false
        await loader.loadMore { _ in
            fetchCalled = true
            return (items: [1], total: 1)
        }

        #expect(!fetchCalled)
        #expect(loader.items.isEmpty)
    }

    @Test("loadMore is a no-op once hasLoadedAll is true")
    func guardsAgainstFetchAfterFullyLoaded() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [1, 2], total: 2) }
        #expect(loader.hasLoadedAll)

        var fetchCalledAgain = false
        await loader.loadMore { _ in
            fetchCalledAgain = true
            return (items: [3], total: 3)
        }

        #expect(!fetchCalledAgain)
        #expect(loader.items == [1, 2])
    }

    @Test("a thrown fetch error is swallowed, leaving state unchanged and isLoadingMore reset")
    func swallowsFetchErrors() async {
        struct Boom: Error {}
        let loader = PaginatedLoader<Int>(pageSize: 2)

        await loader.loadMore { _ in throw Boom() }

        #expect(loader.items.isEmpty)
        #expect(loader.totalCount == 0)
        #expect(!loader.isLoadingMore)
        #expect(!loader.hasLoadedAll)
    }

    @Test("reset clears items, totalCount, isLoadingMore, and hasLoadedAll")
    func resetClearsState() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [1, 2], total: 2) }
        #expect(loader.hasLoadedAll)

        loader.reset()

        #expect(loader.items.isEmpty)
        #expect(loader.totalCount == 0)
        #expect(!loader.isLoadingMore)
        #expect(!loader.hasLoadedAll)
    }
}
