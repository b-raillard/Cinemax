import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Jellyfin 12.0 lets EPISODES carry alternate versions, so the detail screen's
/// Version row now ranks the RESOLVED play target — a series' next-up episode —
/// instead of refusing series outright. The pick therefore has to be keyed by
/// the target's id: a single `String?` would carry a version chosen for
/// episode 4 onto episode 5 the moment next-up advanced.
@Suite("Episode version selection")
@MainActor
struct EpisodeVersionSelectionTests {

    @Test("a pick is stored for the item it was made on and for no other")
    func keyedByTarget() {
        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        vm.selectMediaSource("src-b", for: "ep-4")

        #expect(vm.selectedMediaSourceId(for: "ep-4") == "src-b")
        #expect(vm.selectedMediaSourceId(for: "ep-5") == nil,
                "advancing next-up must fall back to the ranked default, not inherit episode 4's pick")
        #expect(vm.selectedMediaSourceId(for: "series-1") == nil)
    }

    @Test("a later pick on the same target replaces the earlier one")
    func replaced() {
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        vm.selectMediaSource("src-a", for: "movie-1")
        vm.selectMediaSource("src-c", for: "movie-1")
        #expect(vm.selectedMediaSourceId(for: "movie-1") == "src-c")
    }

    @Test("picks on two targets coexist")
    func independent() {
        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        vm.selectMediaSource("src-a", for: "ep-1")
        vm.selectMediaSource("src-b", for: "ep-2")
        #expect(vm.selectedMediaSourceId(for: "ep-1") == "src-a")
        #expect(vm.selectedMediaSourceId(for: "ep-2") == "src-b")
    }

    @Test("a stale pick falls back to the ranked source instead of failing")
    func stalePickFallsBack() {
        var a = MediaSourceInfo(); a.id = "a"; a.bitrate = 5_000_000
        var b = MediaSourceInfo(); b.id = "b"; b.bitrate = 20_000_000
        let ranked = MediaSourceQuality.ranked([a, b], maxBitrate: 120_000_000)
        let pick = MediaSourceQuality.resolve(ranked, preferredID: "gone", maxBitrate: 120_000_000)
        #expect(pick?.id == ranked.first?.id)
    }
}
