import Testing
import Foundation
import JellyfinAPI
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

    /// Only the FIRST page pays for the server-side COUNT: `PaginatedLoader`
    /// keeps that total and ends on a short page (a 10.11 server answered a
    /// 40-card page in ~84 ms uncounted against ~146 ms counted).
    @Test("only the first page asks the server to count")
    func onlyFirstPageCounts() async {
        let api = MockAPIClient()
        api.getItemsHandler = { startIndex in
            if startIndex == 0 {
                return (makeItems(40, prefix: "Page1"), 120)
            }
            // Uncounted: Jellyfin reports the PAGE's size, not 0 (measured, 10.11).
            return (makeItems(40, prefix: "Page2"), 40)
        }
        let vm = FavoritesViewModel()
        let appState = makeAppState(api: api)

        await vm.load(using: appState)
        await vm.loadMore(using: appState)

        #expect(api.getItemsQueries.map(\.enableTotalRecordCount) == [true, false])
        #expect(vm.loader.items.count == 80)
        #expect(vm.loader.totalCount == 120)
        #expect(!vm.loader.hasLoadedAll, "a full uncounted page is not the end")
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

    // « loadMore ne fait rien pendant qu'un chargement est en vol » simulait
    // l'état en vol en écrivant `isLoadingMore` de l'extérieur. Le drapeau
    // appartient désormais au chargeur seul (`private(set)`) et un appel qui
    // arrive pendant un autre n'est plus abandonné mais mis en file, ce que
    // `PaginatedLoaderInterlockTests` vérifie avec une passe réellement en vol,
    // tenue ouverte par une barrière — la seule façon honnête de le prouver.

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

    @Test("reset discards a stale in-flight loadMore instead of splicing its result into the fresh page")
    func resetDiscardsStaleInFlightLoadMore() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)

        // Seed an initial page so the subsequent loadMore mirrors the real
        // "scrolled to the last card, loadMore in flight" trigger scenario.
        await loader.loadMore { _ in (items: [1, 2], total: 10) }
        #expect(loader.items == [1, 2])

        let fetchStarted = PaginatedLoaderGate()
        let releaseStaleFetch = PaginatedLoaderGate()

        // Kick off a loadMore whose fetch suspends until released — simulating
        // a network call still in flight when a refresh notification fires.
        let staleTask = Task { @MainActor in
            await loader.loadMore { _ in
                await fetchStarted.signal()
                await releaseStaleFetch.wait()
                return (items: [999, 998], total: 999)
            }
        }

        // Wait until the stale fetch has actually started (isLoadingMore is
        // already true and the closure is suspended) before resetting.
        await fetchStarted.wait()

        // A refresh notification (e.g. .cinemaxItemUserDataChanged) fires while
        // that fetch is still in flight: reset, then re-fetch page 0.
        loader.reset()
        await loader.loadMore { _ in (items: [7, 8], total: 2) }

        #expect(loader.items == [7, 8])
        #expect(loader.totalCount == 2)
        #expect(loader.hasLoadedAll)

        // Now let the stale fetch resume and complete.
        await releaseStaleFetch.signal()
        await staleTask.value

        // The stale page must NOT be spliced in, and it must not clobber the
        // totalCount/hasLoadedAll the fresh fetch just established.
        #expect(loader.items == [7, 8])
        #expect(loader.totalCount == 2)
        #expect(loader.hasLoadedAll)
        #expect(!loader.isLoadingMore)
    }

    // MARK: refreshLoadedSpan
    //
    // The point of this method is that a notification-driven refresh must NOT
    // collapse a deeply-scrolled grid back to one page — that visibly jumped the
    // user to the top, and it became a live regression once the cards in these
    // grids gained a context menu raising those very notifications.

    @Test("refreshLoadedSpan re-requests the whole loaded span as one page from index 0")
    func refreshRequestsLoadedSpan() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [1, 2], total: 10) }
        await loader.loadMore { _ in (items: [3, 4], total: 10) }
        #expect(loader.items == [1, 2, 3, 4])

        await loader.refreshLoadedSpan { startIndex, limit in
            #expect(startIndex == 0)
            #expect(limit == 4) // the span already on screen, not the page size
            return (items: [1, 2, 3, 9], total: 10)
        }

        #expect(loader.items == [1, 2, 3, 9])
        #expect(loader.totalCount == 10)
        #expect(!loader.hasLoadedAll)
        #expect(!loader.isLoadingMore)
    }

    @Test("refreshLoadedSpan re-derives hasLoadedAll, so a shrunken set stops asking for more")
    func refreshRederivesHasLoadedAll() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [1, 2], total: 3) }
        #expect(!loader.hasLoadedAll)

        // An un-favorited item: the span comes back one short, and the total with it.
        await loader.refreshLoadedSpan { _, _ in (items: [1], total: 1) }

        #expect(loader.items == [1])
        #expect(loader.totalCount == 1)
        #expect(loader.hasLoadedAll)
    }

    @Test("refreshLoadedSpan is a no-op before anything is paged in")
    func refreshGuards() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)

        var fetchCalled = false
        await loader.refreshLoadedSpan { _, _ in
            fetchCalled = true
            return (items: [1], total: 1)
        }
        #expect(!fetchCalled) // nothing loaded yet — the caller must do a full load
        #expect(loader.items.isEmpty)
    }

    @Test("a thrown refreshLoadedSpan leaves the visible page intact")
    func refreshSwallowsErrors() async {
        struct Boom: Error {}
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [1, 2], total: 10) }

        await loader.refreshLoadedSpan { _, _ in throw Boom() }

        #expect(loader.items == [1, 2])
        #expect(loader.totalCount == 10)
        #expect(!loader.isLoadingMore)
    }

    @Test("reset discards a stale in-flight refreshLoadedSpan")
    func resetDiscardsStaleRefresh() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [1, 2], total: 10) }

        let fetchStarted = PaginatedLoaderGate()
        let releaseStaleFetch = PaginatedLoaderGate()

        let staleTask = Task { @MainActor in
            await loader.refreshLoadedSpan { _, _ in
                await fetchStarted.signal()
                await releaseStaleFetch.wait()
                return (items: [999, 998], total: 999)
            }
        }
        await fetchStarted.wait()

        loader.reset()
        await loader.loadMore { _ in (items: [7, 8], total: 2) }

        await releaseStaleFetch.signal()
        await staleTask.value

        #expect(loader.items == [7, 8])
        #expect(loader.totalCount == 2)
        #expect(loader.hasLoadedAll)
        #expect(!loader.isLoadingMore)
    }

    // MARK: Count once, end on a short page

    @Test("an uncounted later page keeps the first page's total and does not end a full page")
    func uncountedPageKeepsTotal() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [1, 2], total: 5) }
        // Fetched with `enableTotalRecordCount: false`: Jellyfin then reports
        // the page's own size as the total (measured on 10.11), never 0.
        await loader.loadMore { _ in (items: [3, 4], total: 2) }

        #expect(loader.items == [1, 2, 3, 4])
        #expect(loader.totalCount == 5, "the header keeps the first page's count")
        #expect(!loader.hasLoadedAll, "a FULL uncounted page is not the end")
    }

    @Test("an uncounted short page ends pagination")
    func uncountedShortPageEnds() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [1, 2], total: 3) }
        await loader.loadMore { _ in (items: [3], total: 1) }

        #expect(loader.items == [1, 2, 3])
        #expect(loader.hasLoadedAll)
        #expect(loader.totalCount == 3)
    }

    @Test("an uncounted full page ends the list once the first page's total is reached")
    func uncountedPageEndsAtFirstTotal() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [1, 2], total: 4) }
        await loader.loadMore { _ in (items: [3, 4], total: 2) }

        #expect(loader.hasLoadedAll, "4 of 4 — no empty extra request")
        #expect(loader.totalCount == 4)
    }

    @Test("an empty FIRST page reporting 0 is the end, not an uncounted page")
    func emptyFirstPageEnds() async {
        let loader = PaginatedLoader<Int>(pageSize: 2)
        await loader.loadMore { _ in (items: [], total: 0) }

        #expect(loader.hasLoadedAll)
        #expect(loader.totalCount == 0)
    }

    // MARK: Look-ahead trigger

    @Test("the next page is requested half a page before the last card")
    func shouldLoadMoreLooksAhead() async {
        let loader = PaginatedLoader<String>(pageSize: 40, identity: { $0 })
        await loader.loadMore { _ in (items: (0..<40).map { "m\($0)" }, total: 200) }

        #expect(loader.prefetchDistance == 20)
        #expect(PaginatedLoader<String>(pageSize: 1).prefetchDistance == 1, "never 0 — the trigger would be dead")
        #expect(!loader.shouldLoadMore(onAppearOf: "m19"), "outside the window")
        #expect(loader.shouldLoadMore(onAppearOf: "m20"), "first card of the window")
        #expect(loader.shouldLoadMore(onAppearOf: "m39"), "the last card still triggers")
        #expect(!loader.shouldLoadMore(onAppearOf: nil))
        #expect(!loader.shouldLoadMore(onAppearOf: "unknown"))
    }

    @Test("the look-ahead never fires once everything is loaded, or without an identity")
    func shouldLoadMoreRespectsEndAndIdentity() async {
        let done = PaginatedLoader<String>(pageSize: 40, identity: { $0 })
        await done.loadMore { _ in (items: ["a", "b"], total: 2) }
        #expect(done.hasLoadedAll)
        #expect(!done.shouldLoadMore(onAppearOf: "b"))

        let anonymous = PaginatedLoader<String>(pageSize: 40)
        await anonymous.loadMore { _ in (items: ["a", "b"], total: 10) }
        #expect(!anonymous.shouldLoadMore(onAppearOf: "b"))
    }
}

/// One-shot async gate used to deterministically interleave a stale in-flight
/// `loadMore` fetch with a `reset()` + fresh `loadMore` on the main actor,
/// without relying on `Task.yield()` scheduling order.
private actor PaginatedLoaderGate {
    private var isSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func signal() {
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }
}
