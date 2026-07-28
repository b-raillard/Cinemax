import Foundation
import Testing
@testable import Cinemax

/// Pure logic behind the playback Live Activity: the `ContentState` factory
/// (which converts a playhead sample into the rate-scaled wall-clock anchor the
/// widget renders from) and the push throttle (which keeps the app from spending
/// an ActivityKit update on every 1 s tick). The UI itself is manual QA.
@Suite("PlaybackLiveActivity")
struct PlaybackLiveActivityTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - ContentState.make

    @Test("playing at 1x anchors startedAt at now minus elapsed")
    func playingAnchorsStart() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 120, duration: 3600, rate: 1, now: Self.now
        )
        #expect(state.startedAt == Self.now.addingTimeInterval(-120))
        #expect(state.duration == 3600)
        #expect(state.isPaused == false)
        #expect(state.pausedElapsed == nil)
        #expect(state.rate == 1)
    }

    @Test("off-speed playback scales the anchor by the rate")
    func offSpeedScalesAnchor() {
        // At 2x, 100 media seconds took only 50 wall-clock seconds.
        let fast = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 3600, rate: 2, now: Self.now
        )
        #expect(fast.startedAt == Self.now.addingTimeInterval(-50))
        #expect(fast.rate == 2)

        // At 0.5x they took 200.
        let slow = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 3600, rate: 0.5, now: Self.now
        )
        #expect(slow.startedAt == Self.now.addingTimeInterval(-200))
    }

    @Test("a zero or negative rate means paused")
    func pausedFreezesElapsed() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 42, duration: 3600, rate: 0, now: Self.now
        )
        #expect(state.isPaused)
        #expect(state.pausedElapsed == 42)
        #expect(state.rate == 1) // display default; the badge is hidden while paused
        // Frozen: it must not drift with wall-clock time.
        #expect(state.elapsed(at: Self.now.addingTimeInterval(600)) == 42)
    }

    @Test("playing elapsed projects forward at the anchored rate")
    func playingElapsedProjects() {
        let normal = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 3600, rate: 1, now: Self.now
        )
        #expect(normal.elapsed(at: Self.now.addingTimeInterval(30)) == 130)

        let fast = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 3600, rate: 2, now: Self.now
        )
        // 30 wall-clock seconds at 2x advance the media playhead by 60.
        #expect(fast.elapsed(at: Self.now.addingTimeInterval(30)) == 160)
    }

    @Test("playing elapsed never exceeds a known duration")
    func playingElapsedClampsToDuration() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 200, rate: 1, now: Self.now
        )
        #expect(state.elapsed(at: Self.now.addingTimeInterval(1_000)) == 200)
    }

    @Test("non-finite and negative inputs are sanitised")
    func sanitisesGarbageInput() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: .nan, duration: .infinity, rate: 1, now: Self.now
        )
        #expect(state.startedAt == Self.now)
        #expect(state.duration == 0)

        let negative = PlaybackActivityAttributes.ContentState.make(
            elapsed: -50, duration: -10, rate: -1, now: Self.now
        )
        #expect(negative.isPaused)
        #expect(negative.pausedElapsed == 0)
        #expect(negative.duration == 0)

        // A NaN rate must not poison the anchor.
        let nanRate = PlaybackActivityAttributes.ContentState.make(
            elapsed: 10, duration: 100, rate: .nan, now: Self.now
        )
        #expect(nanRate.isPaused)
    }

    @Test("absurd rates are clamped so the anchor stays finite")
    func clampsRate() {
        let bounds = PlaybackActivityAttributes.ContentState.rateBounds
        let tiny = PlaybackActivityAttributes.ContentState.make(
            elapsed: 10, duration: 100, rate: 0.0001, now: Self.now
        )
        #expect(tiny.rate == bounds.lowerBound)

        let huge = PlaybackActivityAttributes.ContentState.make(
            elapsed: 10, duration: 100, rate: 1_000, now: Self.now
        )
        #expect(huge.rate == bounds.upperBound)
    }

    @Test("elapsed is clamped into the timeline before anchoring")
    func clampsElapsedPastDuration() {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: 5_000, duration: 1_000, rate: 1, now: Self.now
        )
        #expect(state.startedAt == Self.now.addingTimeInterval(-1_000))
    }

    // MARK: - isOffSpeed / timerRange / progressFraction / staleDate

    @Test("isOffSpeed is true only while playing at a rate other than 1x")
    func offSpeedFlag() {
        func state(rate: Double) -> PlaybackActivityAttributes.ContentState {
            .make(elapsed: 10, duration: 100, rate: rate, now: Self.now)
        }
        #expect(state(rate: 1).isOffSpeed == false)
        #expect(state(rate: 0).isOffSpeed == false)     // paused
        #expect(state(rate: 2).isOffSpeed)
        #expect(state(rate: 0.5).isOffSpeed)
    }

    @Test("timerRange spans wall-clock, so it shrinks as the rate rises")
    func timerRangeIsWallClock() {
        let normal = PlaybackActivityAttributes.ContentState.make(
            elapsed: 0, duration: 600, rate: 1, now: Self.now
        )
        #expect(normal.timerRange?.lowerBound == Self.now)
        #expect(normal.timerRange?.upperBound == Self.now.addingTimeInterval(600))

        let fast = PlaybackActivityAttributes.ContentState.make(
            elapsed: 0, duration: 600, rate: 2, now: Self.now
        )
        // 600 media seconds at 2x end 300 wall-clock seconds from now.
        #expect(fast.timerRange?.upperBound == Self.now.addingTimeInterval(300))
    }

    @Test("timerRange is nil when paused or the runtime is unknown")
    func timerRangeNilWhenStatic() {
        let unknown = PlaybackActivityAttributes.ContentState.make(
            elapsed: 10, duration: 0, rate: 1, now: Self.now
        )
        #expect(unknown.timerRange == nil)

        let paused = PlaybackActivityAttributes.ContentState.make(
            elapsed: 10, duration: 600, rate: 0, now: Self.now
        )
        #expect(paused.timerRange == nil)
    }

    @Test("progressFraction stays inside 0...1")
    func progressFractionBounds() {
        let paused = PlaybackActivityAttributes.ContentState.make(
            elapsed: 150, duration: 600, rate: 0, now: Self.now
        )
        #expect(paused.progressFraction(at: Self.now) == 0.25)

        let unknown = PlaybackActivityAttributes.ContentState.make(
            elapsed: 150, duration: 0, rate: 0, now: Self.now
        )
        #expect(unknown.progressFraction(at: Self.now) == 0)

        let playing = PlaybackActivityAttributes.ContentState.make(
            elapsed: 0, duration: 100, rate: 1, now: Self.now
        )
        #expect(playing.progressFraction(at: Self.now.addingTimeInterval(10_000)) == 1)
    }

    @Test("staleDate follows the wall-clock end, so it comes sooner at 2x")
    func staleDateWhilePlaying() {
        let normal = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 1_000, rate: 1, now: Self.now
        )
        // 900 s of media remaining at 1x + a 60 s grace.
        #expect(normal.staleDate(at: Self.now) == Self.now.addingTimeInterval(960))

        let fast = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 1_000, rate: 2, now: Self.now
        )
        // The same 900 s of media take 450 wall-clock seconds at 2x.
        #expect(fast.staleDate(at: Self.now) == Self.now.addingTimeInterval(510))
    }

    @Test("staleDate falls back to a fixed window when paused or runtime unknown")
    func staleDateIdle() {
        let paused = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 1_000, rate: 0, now: Self.now
        )
        #expect(paused.staleDate(at: Self.now) == Self.now.addingTimeInterval(30 * 60))

        let unknown = PlaybackActivityAttributes.ContentState.make(
            elapsed: 100, duration: 0, rate: 1, now: Self.now
        )
        #expect(unknown.staleDate(at: Self.now) == Self.now.addingTimeInterval(30 * 60))
    }

    // MARK: - Throttle

    private func snapshot(
        elapsed: TimeInterval, duration: TimeInterval = 3_600,
        rate: Double = 1, offset: TimeInterval = 0
    ) -> PlaybackActivitySnapshot {
        .init(
            elapsed: elapsed, duration: duration, rate: rate,
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

    /// The core budget guarantee: 10 minutes of uninterrupted playback costs
    /// zero pushes — at ANY speed. Before the projection became rate-aware, 2x
    /// drifted 1 s per wall-clock second and crossed `seekTolerance` every ~4 s
    /// (≈675 pushes per 45-minute episode).
    @Test("a run of ordinary ticks never pushes, at any rate", arguments: [0.5, 1.0, 1.25, 2.0])
    func manyTicksAreSilent(rate: Double) {
        var previous = snapshot(elapsed: 0, duration: 100_000, rate: rate)
        for tick in 1...600 {
            let next = snapshot(
                elapsed: Double(tick) * rate, duration: 100_000,
                rate: rate, offset: Double(tick)
            )
            #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: next) == false)
            previous = next
        }
    }

    @Test("a play/pause flip always pushes")
    func pauseFlipPushes() {
        let previous = snapshot(elapsed: 100)
        let next = snapshot(elapsed: 101, rate: 0, offset: 1)
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: next))
        // …and back again.
        #expect(PlaybackActivityThrottle.shouldPush(previous: next, next: snapshot(elapsed: 101, offset: 2)))
    }

    @Test("a speed-picker move pushes so the widget re-anchors")
    func rateChangePushes() {
        let previous = snapshot(elapsed: 100)
        // The projection is satisfied (1 s of media in 1 s), but the rate changed.
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: snapshot(elapsed: 101, rate: 1.5, offset: 1)))
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: snapshot(elapsed: 101, rate: 0.5, offset: 1)))
    }

    @Test("float noise on the rate does not push")
    func rateNoiseIsSilent() {
        let previous = snapshot(elapsed: 100)
        let next = snapshot(elapsed: 101, rate: 1.005, offset: 1)
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: next) == false)
    }

    @Test("a paused playhead standing still does not push")
    func pausedIsSilent() {
        let previous = snapshot(elapsed: 100, rate: 0)
        let next = snapshot(elapsed: 100, rate: 0, offset: 5)
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: next) == false)
    }

    @Test("a seek beyond the tolerance pushes, in both directions")
    func seekPushes() {
        let previous = snapshot(elapsed: 100)
        // The app's smallest skip is ±10 s — comfortably past the tolerance.
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: snapshot(elapsed: 111, offset: 1)))
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: snapshot(elapsed: 91, offset: 1)))
    }

    @Test("a seek is still detected while playing off-speed")
    func seekPushesAtDoubleSpeed() {
        let previous = snapshot(elapsed: 100, rate: 2)
        // The projection at 2x is 102; a ±10 s skip lands well outside it.
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: snapshot(elapsed: 112, rate: 2, offset: 1)))
        #expect(PlaybackActivityThrottle.shouldPush(previous: previous, next: snapshot(elapsed: 92, rate: 2, offset: 1)))
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
