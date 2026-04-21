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
