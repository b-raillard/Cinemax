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
    /// seek, item change, stop.
    struct ContentState: Codable, Hashable {
        /// Wall-clock instant the playhead maps to 00:00. Recomputed as
        /// `now - elapsed` on every push, so a seek is just a re-base.
        var startedAt: Date
        /// Total runtime in seconds; `0` when the engine hasn't reported one yet
        /// (the widget then draws no progress bar rather than a bogus one).
        var duration: TimeInterval
        var isPaused: Bool
        /// Playhead frozen at the moment of the pause (a paused timer can't be
        /// derived from wall-clock). `nil` while playing.
        var pausedElapsed: TimeInterval?
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
    /// Builds a state from a raw playhead sample. Pure — unit-tested
    /// (`PlaybackLiveActivityTests`).
    static func make(
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPaused: Bool,
        now: Date
    ) -> Self {
        let safeElapsed = max(0, elapsed.isFinite ? elapsed : 0)
        let safeDuration = (duration.isFinite && duration > 0) ? duration : 0
        let clamped = safeDuration > 0 ? min(safeElapsed, safeDuration) : safeElapsed
        return .init(
            startedAt: now.addingTimeInterval(-clamped),
            duration: safeDuration,
            isPaused: isPaused,
            pausedElapsed: isPaused ? clamped : nil
        )
    }

    /// Playhead in seconds at `now`: the frozen value while paused, the
    /// wall-clock projection while playing.
    func elapsed(at now: Date) -> TimeInterval {
        if isPaused { return max(0, pausedElapsed ?? 0) }
        let running = now.timeIntervalSince(startedAt)
        guard running.isFinite, running > 0 else { return 0 }
        return duration > 0 ? min(running, duration) : running
    }

    /// Range handed to `ProgressView(timerInterval:)` / `Text(timerInterval:)`.
    /// `nil` when the runtime is unknown, so the widget falls back to a static
    /// row instead of building an inverted range (SwiftUI traps on
    /// `lowerBound > upperBound`).
    var timerRange: ClosedRange<Date>? {
        guard duration > 0 else { return nil }
        return startedAt...startedAt.addingTimeInterval(duration)
    }

    /// When the system should dim the activity as stale. Playing: just past the
    /// point the media would have finished (the app normally ends it first —
    /// this only covers a crash / force-quit). Paused or unknown runtime: a
    /// generous window, since nothing on screen is counting down.
    func staleDate(at now: Date) -> Date {
        guard !isPaused, duration > 0 else {
            return now.addingTimeInterval(Self.idleStaleWindow)
        }
        let remaining = max(60, duration - elapsed(at: now))
        return now.addingTimeInterval(remaining + 60)
    }

    private static let idleStaleWindow: TimeInterval = 30 * 60
}
#endif
