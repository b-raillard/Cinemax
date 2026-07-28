import Foundation
import Testing
@testable import Cinemax

/// Pure logic behind the playback Live Activity: the `ContentState` factory
/// (which converts a playhead sample into the wall-clock anchor the widget
/// renders from) and the push throttle (which keeps the app from spending an
/// ActivityKit update on every 1 s tick). The UI itself is manual QA.
@Suite("PlaybackLiveActivity")
struct PlaybackLiveActivityTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - ContentState.make

    @Test("playing state anchors startedAt at now minus elapsed")
    func playingAnchorsStart() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 120, duration: 3600, isPaused: false, now: Self.now
        )
        #expect(state.startedAt == Self.now.addingTimeInterval(-120))
        #expect(state.duration == 3600)
        #expect(state.isPaused == false)
        #expect(state.pausedElapsed == nil)
    }

    @Test("paused state freezes the elapsed value")
    func pausedFreezesElapsed() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 42, duration: 3600, isPaused: true, now: Self.now
        )
        #expect(state.pausedElapsed == 42)
        // Frozen: it must not drift with wall-clock time.
        #expect(state.elapsed(at: Self.now.addingTimeInterval(600)) == 42)
    }

    @Test("playing elapsed projects forward from the anchor")
    func playingElapsedProjects() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 3600, isPaused: false, now: Self.now
        )
        #expect(state.elapsed(at: Self.now.addingTimeInterval(30)) == 130)
    }

    @Test("playing elapsed never exceeds a known duration")
    func playingElapsedClampsToDuration() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 200, isPaused: false, now: Self.now
        )
        #expect(state.elapsed(at: Self.now.addingTimeInterval(1_000)) == 200)
    }

    @Test("non-finite and negative inputs are sanitised")
    func sanitisesGarbageInput() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: .nan, duration: .infinity, isPaused: false, now: Self.now
        )
        #expect(state.startedAt == Self.now)
        #expect(state.duration == 0)

        let negative = PlaybackActivityAttributes.ContentState.make(
            elapsed: -50, duration: -10, isPaused: true, now: Self.now
        )
        #expect(negative.pausedElapsed == 0)
        #expect(negative.duration == 0)
    }

    @Test("elapsed is clamped into the timeline before anchoring")
    func clampsElapsedPastDuration() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 5_000, duration: 1_000, isPaused: false, now: Self.now
        )
        #expect(state.startedAt == Self.now.addingTimeInterval(-1_000))
    }

    // MARK: - timerRange / staleDate

    @Test("timerRange is nil until the runtime is known")
    func timerRangeNilWithoutDuration() {
        let unknown = PlaybackActivityAttributes.ContentState.make(
            elapsed: 10, duration: 0, isPaused: false, now: Self.now
        )
        #expect(unknown.timerRange == nil)

        let known = PlaybackActivityAttributes.ContentState.make(
            elapsed: 10, duration: 600, isPaused: false, now: Self.now
        )
        #expect(known.timerRange?.lowerBound == known.startedAt)
        #expect(known.timerRange?.upperBound == known.startedAt.addingTimeInterval(600))
    }

    @Test("staleDate outlives the remaining runtime while playing")
    func staleDateWhilePlaying() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 1_000, isPaused: false, now: Self.now
        )
        // 900 s remaining + a 60 s grace.
        #expect(state.staleDate(at: Self.now) == Self.now.addingTimeInterval(960))
    }

    @Test("staleDate falls back to a fixed window when paused or runtime unknown")
    func staleDateIdle() {
        let paused = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 1_000, isPaused: true, now: Self.now
        )
        #expect(paused.staleDate(at: Self.now) == Self.now.addingTimeInterval(30 * 60))

        let unknown = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 0, isPaused: false, now: Self.now
        )
        #expect(unknown.staleDate(at: Self.now) == Self.now.addingTimeInterval(30 * 60))
    }

    // MARK: - Throttle

    private func snapshot(
        elapsed: TimeInterval, duration: TimeInterval = 3_600,
        isPaused: Bool = false, offset: TimeInterval = 0
    ) -> PlaybackActivitySnapshot {
        .init(
            elapsed: elapsed, duration: duration, isPaused: isPaused,
            at: Self.now.addingTimeInterval(offset)
        )
    }

    @Test("the first sample always pushes")
    func firstSamplePushes() {
        #expect(PlaybackActivityThrottle.shouldPush(previous: nil, next: snapshot(elapsed: 0)))
    }

    @Test("a tick that matches the wall-clock projection does not push")
    func steadyTickIsSilent() {
        let previous = snapshot(elapsed: 100)
        let next = snapshot(elapsed: 101, offset: 1)
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: next) == false)
    }

    @Test("a run of ordinary ticks never pushes")
    func manyTicksAreSilent() {
        var previous = snapshot(elapsed: 0)
        for tick in 1...600 {
            let next = snapshot(elapsed: Double(tick), offset: Double(tick))
            #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: next) == false)
            previous = next
        }
    }

    @Test("a play/pause flip always pushes")
    func pauseFlipPushes() {
        let previous = snapshot(elapsed: 100)
        let next = snapshot(elapsed: 101, isPaused: true, offset: 1)
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: next))
    }

    @Test("a paused playhead standing still does not push")
    func pausedIsSilent() {
        let previous = snapshot(elapsed: 100, isPaused: true)
        let next = snapshot(elapsed: 100, isPaused: true, offset: 5)
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: next) == false)
    }

    @Test("a seek beyond the tolerance pushes, in both directions")
    func seekPushes() {
        let previous = snapshot(elapsed: 100)
        // The app's smallest skip is ±10 s — comfortably past the tolerance.
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: snapshot(elapsed: 111, offset: 1)))
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: snapshot(elapsed: 91, offset: 1)))
    }

    @Test("drift inside the tolerance does not push")
    func smallDriftIsSilent() {
        let previous = snapshot(elapsed: 100)
        // Projected 101; a 2 s wobble is engine jitter, not a seek.
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: snapshot(elapsed: 103, offset: 1)) == false)
    }

    @Test("the runtime becoming known pushes")
    func durationDiscoveryPushes() {
        let previous = snapshot(elapsed: 3, duration: 0)
        let next = snapshot(elapsed: 4, duration: 3_600, offset: 1)
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: next))
    }

    // MARK: - Headline

    @Test("episodes read as series + SxEy · name")
    func episodeHeadline() {
        let headline = PlaybackLiveActivityController.headline(
            seriesName: "Severance", itemName: "Good News About Hell",
            season: 1, episode: 1, year: 2022, fallbackTitle: "fallback"
        )
        #expect(headline.title == "Severance")
        #expect(headline.subtitle == "S1E1 · Good News About Hell")
    }

    @Test("an episode without index numbers keeps just the name")
    func episodeHeadlineWithoutIndices() {
        let headline = PlaybackLiveActivityController.headline(
            seriesName: "Severance", itemName: "Pilot",
            season: nil, episode: nil, year: nil, fallbackTitle: "fallback"
        )
        #expect(headline.title == "Severance")
        #expect(headline.subtitle == "Pilot")
    }

    @Test("movies read as name + year")
    func movieHeadline() {
        let headline = PlaybackLiveActivityController.headline(
            seriesName: nil, itemName: "Dune", season: nil, episode: nil,
            year: 2021, fallbackTitle: "fallback"
        )
        #expect(headline.title == "Dune")
        #expect(headline.subtitle == "2021")
    }

    @Test("an unresolved item falls back to the presenter's title")
    func unresolvedHeadline() {
        let headline = PlaybackLiveActivityController.headline(
            seriesName: nil, itemName: nil, season: nil, episode: nil,
            year: nil, fallbackTitle: "Some Title"
        )
        #expect(headline.title == "Some Title")
        #expect(headline.subtitle.isEmpty)
    }
}
