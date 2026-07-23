import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Free function so it can be called from non-isolated `@Sendable` handler closures
/// without crossing actor boundaries. BaseItemDto is a struct; the returned value
/// is fully owned by the caller.
private func makeEpisode(id: String, name: String) -> BaseItemDto {
    var ep = BaseItemDto()
    ep.id = id
    ep.name = name
    return ep
}

/// Episode carrying a `userData` payload so played-state mutations have
/// something to flip (episodes are fetched with `enableUserData: true`).
private func makeWatchableEpisode(id: String, name: String, played: Bool) -> BaseItemDto {
    var ep = makeEpisode(id: id, name: name)
    var userData = UserItemDataDto()
    userData.isPlayed = played
    ep.userData = userData
    return ep
}

private func makeMovie(id: String, played: Bool) -> BaseItemDto {
    var item = BaseItemDto()
    item.id = id
    item.type = .movie
    var userData = UserItemDataDto()
    userData.isPlayed = played
    item.userData = userData
    return item
}

private func makeSeries(id: String, played: Bool) -> BaseItemDto {
    var item = BaseItemDto()
    item.id = id
    item.type = .series
    var userData = UserItemDataDto()
    userData.isPlayed = played
    item.userData = userData
    return item
}

/// Thread-safe monotonic counter so a `@Sendable` handler can tell which call it
/// is (the load-race test needs the first call to be slow, the second fast, but
/// both target the same `itemId`).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

@MainActor
@Suite("MediaDetailViewModel")
struct MediaDetailViewModelTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    /// When the user rapidly taps two seasons, the first season's episode fetch can
    /// resolve after the second one due to network ordering. The generation counter
    /// inside `selectSeason` must discard the stale result and keep the latest
    /// season's episodes.
    @Test("selectSeason discards stale results when a newer selection completes first")
    func selectSeasonRaceKeepsLatest() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { seasonId in
            // Season A intentionally sleeps longer so it resolves *after* Season B,
            // simulating the race described in the audit.
            if seasonId == "season-A" {
                try? await Task.sleep(for: .milliseconds(200))
                return [makeEpisode(id: "ep-a1", name: "A1"), makeEpisode(id: "ep-a2", name: "A2")]
            } else {
                try? await Task.sleep(for: .milliseconds(20))
                return [makeEpisode(id: "ep-b1", name: "B1")]
            }
        }

        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        let appState = makeAppState(api: api)

        async let firstCall: Void = vm.selectSeason("season-A", seriesId: "series-1", using: appState)
        // Ensure Season A's generation is captured before B increments it.
        try? await Task.sleep(for: .milliseconds(10))
        async let secondCall: Void = vm.selectSeason("season-B", seriesId: "series-1", using: appState)

        _ = await (firstCall, secondCall)

        #expect(vm.selectedSeasonId == "season-B")
        #expect(vm.episodes.map(\.id) == ["ep-b1"])
    }

    @Test("selectSeason applies episodes when no race occurs")
    func selectSeasonAppliesEpisodes() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in
            [makeEpisode(id: "ep-1", name: "Pilot")]
        }

        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        let appState = makeAppState(api: api)

        await vm.selectSeason("season-A", seriesId: "series-1", using: appState)

        #expect(vm.selectedSeasonId == "season-A")
        #expect(vm.episodes.map(\.id) == ["ep-1"])
    }

    @Test("togglePlayed flips state and marks the movie played, then unplayed")
    func togglePlayedRoundTrip() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        vm.item = makeMovie(id: "movie-1", played: false)
        vm.isPlayed = false

        await vm.togglePlayed(using: appState)
        #expect(vm.isPlayed == true)
        #expect(api.markPlayedCalls == ["movie-1"])

        await vm.togglePlayed(using: appState)
        #expect(vm.isPlayed == false)
        #expect(api.markUnplayedCalls == ["movie-1"])
    }

    @Test("toggleEpisodeWatched flips the local episode payload and clears resume")
    func toggleEpisodeWatchedUpdatesLocalState() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        var episode = makeWatchableEpisode(id: "ep-1", name: "Pilot", played: false)
        episode.userData?.playbackPositionTicks = 500
        vm.episodes = [episode]

        await vm.toggleEpisodeWatched(episode, using: appState)
        #expect(vm.episodes.first?.userData?.isPlayed == true)
        #expect(vm.episodes.first?.userData?.playbackPositionTicks == 0)
        #expect(api.markPlayedCalls == ["ep-1"])
    }

    // MARK: - refreshAfterPlayback (targeted post-playback refresh)

    /// A movie's post-playback refresh re-fetches ONLY the item (for fresh
    /// userData) — never the similar/seasons/next-up fan-out a full `load()`
    /// would run.
    @Test("refreshAfterPlayback for a movie fetches item once, skips similar/seasons/nextUp")
    func refreshAfterPlaybackMovieTargeted() async {
        let api = MockAPIClient()
        api.getItemHandler = { _ in makeMovie(id: "movie-1", played: true) }
        let appState = makeAppState(api: api)

        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        vm.item = makeMovie(id: "movie-1", played: false)
        vm.resolvedType = .movie
        vm.isPlayed = false
        vm.isLoading = false // post-load state — a refresh must not flash the spinner back

        await vm.refreshAfterPlayback(using: appState)

        #expect(api.getItemCallCount == 1)
        #expect(api.getSimilarItemsCallCount == 0)
        #expect(api.getSeasonsCallCount == 0)
        #expect(api.getNextUpCallCount == 0)
        // Fresh userData is reflected without an isLoading spinner flash.
        #expect(vm.isPlayed == true)
        #expect(vm.isLoading == false)
    }

    /// A series' post-playback refresh re-fetches the item (userData), next-up,
    /// and the visible season's episodes concurrently — but NOT seasons or
    /// similar (those don't change from watching).
    @Test("refreshAfterPlayback for a series refreshes episodes + nextUp, skips seasons/similar")
    func refreshAfterPlaybackSeriesTargeted() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in makeSeries(id: id, played: false) }
        api.stubbedNextUp = makeEpisode(id: "next-ep", name: "Next")
        api.getEpisodesHandler = { _ in
            [makeEpisode(id: "ep-1", name: "One"), makeEpisode(id: "ep-2", name: "Two")]
        }
        let appState = makeAppState(api: api)

        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        vm.item = makeSeries(id: "series-1", played: false)
        vm.resolvedType = .series
        vm.selectedSeasonId = "season-1"
        vm.isLoading = false // post-load state — a refresh must not flash the spinner back

        await vm.refreshAfterPlayback(using: appState)

        #expect(api.getItemCallCount == 1)
        #expect(api.getNextUpCallCount == 1)
        #expect(api.getEpisodesCallCount == 1)
        #expect(api.getSeasonsCallCount == 0)
        #expect(api.getSimilarItemsCallCount == 0)
        #expect(vm.nextUpEpisode?.id == "next-ep")
        #expect(vm.episodes.map(\.id) == ["ep-1", "ep-2"])
        #expect(vm.isLoading == false)
    }

    /// A slow first `load()` must not clobber the state a fast second `load()`
    /// already produced — the generation guard discards the stale pass (mirrors
    /// the `selectSeason` race test).
    @Test("load discards stale results when a newer load completes first")
    func loadRaceKeepsLatest() async {
        let api = MockAPIClient()
        let counter = CallCounter()
        api.getItemHandler = { _ in
            // The first-started load resolves LAST (slow); the second resolves
            // first (fast) — last-writer-wins would leave "old" without a guard.
            if counter.next() == 1 {
                try? await Task.sleep(for: .milliseconds(200))
                return makeMovie(id: "old", played: false)
            } else {
                try? await Task.sleep(for: .milliseconds(20))
                return makeMovie(id: "new", played: true)
            }
        }
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        let loc = LocalizationManager()

        async let firstCall: Void = vm.load(using: appState, loc: loc)
        // Ensure the first load bumps + snapshots its generation before the second.
        try? await Task.sleep(for: .milliseconds(10))
        async let secondCall: Void = vm.load(using: appState, loc: loc)

        _ = await (firstCall, secondCall)

        #expect(vm.item?.id == "new")
        #expect(vm.isPlayed == true)
    }

    @Test("selectSeason without userId short-circuits")
    func selectSeasonWithoutUserIdNoop() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in
            [makeEpisode(id: "ep-1", name: "Pilot")]
        }

        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = nil

        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        await vm.selectSeason("season-A", seriesId: "series-1", using: appState)

        #expect(vm.episodes.isEmpty)
    }
}
