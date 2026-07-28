import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Contract between the app (starts / updates / ends the playback Live Activity)
/// and the widget extension (renders it on the Lock Screen + Dynamic Island).
///
/// **Shared by SOURCE, not by linkage**: the extension deliberately links none
/// of our frameworks (CinemaxKit pulls Nuke + the generated Jellyfin entities,
/// which the widget memory budget can't afford — see CLAUDE.md), so the only way
/// to share a type is to list this single file in BOTH targets' `sources` in
/// `project.yml`. Keep it dependency-free: Foundation + ActivityKit only.
struct PlaybackActivityAttributes: ActivityAttributes {
    /// The only part that changes while playback runs.
    ///
    /// **Deliberately carries no "current elapsed" number.** Pushing a fresh
    /// elapsed every second would burn through ActivityKit's update budget in
    /// minutes. Instead the widget derives the playhead client-side from
    /// `startedAt` (`Text(timerInterval:)` / `ProgressView(timerInterval:)`) and
    /// the app pushes only when the *shape* of the timeline changes: play/pause,
    /// a rate change, a seek, item change, stop.
    struct ContentState: Codable, Hashable {
        /// Wall-clock instant the playhead maps to media position 00:00 **at the
        /// current `rate`**. Recomputed as `now - elapsed / rate` on every push,
        /// so a seek or a speed change is just a re-base — and the widget's own
        /// wall-clock timer stays correct at 0.5× as well as at 2×.
        var startedAt: Date
        /// Total runtime in **media** seconds; `0` when the engine hasn't
        /// reported one yet (the widget then draws no progress bar rather than a
        /// bogus one).
        var duration: TimeInterval
        var isPaused: Bool
        /// Playhead frozen at the moment of the pause (a paused timer can't be
        /// derived from wall-clock). `nil` while playing.
        var pausedElapsed: TimeInterval?
        /// Playback speed the timeline is anchored to. `1` while paused or at
        /// normal speed; the app's picker spans 0.5×–2× and iOS hold-to-boost
        /// reaches 2×. Off-speed playback changes how the widget labels the
        /// timeline — see `isOffSpeed`.
        var rate: Double
    }

    var itemId: String
    /// Series name for episodes, movie name otherwise.
    var title: String
    /// "S2E5 · Episode name" for episodes, the release year for movies, empty
    /// when neither is known. Static for the activity's lifetime — ActivityKit
    /// only ever updates `ContentState`, which is why the app resolves this
    /// BEFORE requesting the activity.
    var subtitle: String
}

extension PlaybackActivityAttributes.ContentState {
    /// Rates outside this band are engine noise, not a user speed — clamped so
    /// the `elapsed / rate` anchoring can never divide by ~0 and throw the
    /// timeline into the distant past.
    static let rateBounds: ClosedRange<Double> = 0.1...8.0

    /// Builds a state from a raw playhead sample. `rate <= 0` means paused.
    /// Pure — unit-tested (`PlaybackLiveActivityTests`).
    static func make(
        elapsed: TimeInterval,
        duration: TimeInterval,
        rate: Double,
        now: Date
    ) -> Self {
        let safeElapsed = max(0, elapsed.isFinite ? elapsed : 0)
        let safeDuration = (duration.isFinite && duration > 0) ? duration : 0
        let clamped = safeDuration > 0 ? min(safeElapsed, safeDuration) : safeElapsed
        let isPaused = !(rate.isFinite && rate > 0)
        let playRate = isPaused
            ? 1.0
            : min(rateBounds.upperBound, max(rateBounds.lowerBound, rate))
        return .init(
            startedAt: now.addingTimeInterval(-clamped / playRate),
            duration: safeDuration,
            isPaused: isPaused,
            pausedElapsed: isPaused ? clamped : nil,
            rate: playRate
        )
    }

    /// Playhead in **media** seconds at `now`: the frozen value while paused,
    /// the rate-scaled wall-clock projection while playing.
    func elapsed(at now: Date) -> TimeInterval {
        if isPaused { return max(0, pausedElapsed ?? 0) }
        let wallClock = now.timeIntervalSince(startedAt)
        guard wallClock.isFinite, wallClock > 0 else { return 0 }
        let media = wallClock * rate
        return duration > 0 ? min(media, duration) : media
    }

    /// Playing at a speed other than 1×. The widget keeps the progress bar and
    /// the "ends in" countdown live (both stay wall-clock accurate once the
    /// anchor is rate-scaled) but replaces the elapsed label with a rate badge —
    /// a wall-clock timer cannot count in media time, so a live elapsed there
    /// would simply be wrong.
    var isOffSpeed: Bool {
        !isPaused && abs(rate - 1) > 0.01
    }

    /// **Wall-clock** range handed to `ProgressView(timerInterval:)` /
    /// `Text(timerInterval:)`: from the anchor to the instant the media ends at
    /// the current rate. `nil` when paused or the runtime is unknown, so the
    /// widget falls back to static rendering instead of building an inverted
    /// range (SwiftUI traps on `lowerBound > upperBound`).
    var timerRange: ClosedRange<Date>? {
        guard !isPaused, duration > 0, rate > 0 else { return nil }
        return startedAt...startedAt.addingTimeInterval(duration / rate)
    }

    /// 0…1 progress at `now`, for the static (paused) rendering path.
    func progressFraction(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed(at: now) / duration))
    }

    /// When the system should dim the activity as stale. Playing: just past the
    /// **wall-clock** instant the media would finish at this rate (the app
    /// normally ends it first — this only covers a crash / force-quit). Paused
    /// or unknown runtime: a generous window, since nothing on screen is
    /// counting down.
    func staleDate(at now: Date) -> Date {
        guard !isPaused, duration > 0, rate > 0 else {
            return now.addingTimeInterval(Self.idleStaleWindow)
        }
        let remainingWallClock = max(60, (duration - elapsed(at: now)) / rate)
        return now.addingTimeInterval(remainingWallClock + 60)
    }

    private static let idleStaleWindow: TimeInterval = 30 * 60
}
#endif
