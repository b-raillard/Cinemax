import Foundation
import CinemaxKit

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import os

private let logger = Logger(subsystem: "com.cinemax", category: "LiveActivity")

/// Owns the playback Live Activity (Lock Screen banner + Dynamic Island) for the
/// current session. Third sibling of `RemoteCommandController` (the buttons) and
/// `NowPlayingInfoController` (the Now Playing metadata) — same discipline, same
/// seams, and deliberately NOT merged with either: this one drives a completely
/// separate system surface with its own budget rules.
///
/// Presenter contract, mirroring `NowPlayingInfoController`:
/// `attach` on play / episode-nav, `update` from the existing 1 s tick + on every
/// play/pause transition, `detach` on teardown. It adds no timer of its own.
///
/// **Budget discipline**: `update` is called every second but pushes to
/// ActivityKit only when the timeline *shape* changes (play/pause flip, a seek,
/// the runtime becoming known) — the widget renders the moving playhead
/// client-side off `ContentState.startedAt`. See `PlaybackActivityThrottle`.
///
/// v1 is display-only. Interactive pause/play (a `LiveActivityIntent` button in
/// the widget) is explicitly v2.
@MainActor
final class PlaybackLiveActivityController {
    private let apiClient: any LibraryAPI
    private let userId: String

    private var activity: Activity<PlaybackActivityAttributes>?
    /// Last sample actually pushed to ActivityKit; `nil` until the activity starts.
    private var lastPush: PlaybackActivitySnapshot?
    /// Newest playhead sample seen, pushed or not. The activity request is
    /// deferred behind the item lookup (the subtitle is a static attribute, so it
    /// must be right at request time), and the user can pause or seek inside that
    /// window — the deferred request reads this rather than a stale zero.
    private var latestSample: (elapsed: Double, duration: Double, isPaused: Bool)?

    /// Race guard, same pattern as `NowPlayingInfoController`: bumped in `attach`
    /// and `detach` before spawning the lookup, re-read at write-back so an
    /// episode-nav that lands mid-flight can't start an activity for the episode
    /// the user already left.
    private var generation = 0
    private var enrichTask: Task<Void, Never>?

    init(apiClient: any LibraryAPI, userId: String) {
        self.apiClient = apiClient
        self.userId = userId
    }

    // MARK: - Presenter seams

    /// Resolves the display strings, then starts the activity. `subtitle` lets a
    /// caller that already knows it skip the lookup; both presenters pass `nil`
    /// (neither carries a resolved series / S×E× at this point).
    func attach(itemId: String, title: String, subtitle: String?, durationSeconds: Double?) {
        detach()
        generation += 1
        let gen = generation
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A crash or force-quit leaves the previous session's banner on the Lock
        // Screen forever — sweep before starting a new one.
        Self.endStaleActivities()

        latestSample = (0, durationSeconds ?? 0, false)

        if let subtitle, !subtitle.isEmpty {
            start(itemId: itemId, title: title, subtitle: subtitle)
            return
        }
        // `getItem` is single-flighted + 10 s cached, and `NowPlayingInfoController`
        // fires the same lookup for the same item in the same breath — so this is
        // normally a cache hit, not a second round trip. Starting the activity
        // behind it (rather than starting bare and updating) is required:
        // ActivityKit freezes `ActivityAttributes` for the activity's lifetime,
        // only `ContentState` can be updated.
        let apiClient = self.apiClient
        let userId = self.userId
        enrichTask = Task { @MainActor [weak self] in
            let item = try? await apiClient.getItem(userId: userId, itemId: itemId)
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            let headline = Self.headline(
                seriesName: item?.seriesName,
                itemName: item?.name,
                season: item?.parentIndexNumber,
                episode: item?.indexNumber,
                year: item?.productionYear,
                fallbackTitle: title
            )
            self.start(itemId: itemId, title: headline.title, subtitle: headline.subtitle)
        }
    }

    /// Cheap per-tick call from the presenter's existing 1 s heartbeat and from
    /// its play/pause transitions. Records the sample always; pushes to
    /// ActivityKit only when the throttle says the widget's client-side timer has
    /// gone wrong.
    func update(elapsed: Double, duration: Double?, rate: Double) {
        let isPaused = rate <= 0
        let resolvedDuration: Double = {
            if let duration, duration.isFinite, duration > 0 { return duration }
            return latestSample?.duration ?? 0
        }()
        latestSample = (elapsed, resolvedDuration, isPaused)

        guard let activity else { return }
        let now = Date()
        let next = PlaybackActivitySnapshot(
            elapsed: elapsed, duration: resolvedDuration, isPaused: isPaused, at: now
        )
        guard PlaybackActivityThrottle.shouldPush(previous: lastPush, next: next) else { return }
        lastPush = next
        push(to: activity, snapshot: next)
    }

    /// Ends the activity and cancels any in-flight lookup. Idempotent.
    func detach() {
        generation += 1
        enrichTask?.cancel()
        enrichTask = nil
        lastPush = nil
        latestSample = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Sweeps activities orphaned by a crash / force-quit. Called from `attach`
    /// and once at launch from `AppNavigation`'s root task.
    static func endStaleActivities() {
        for activity in Activity<PlaybackActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: - Private

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.playbackLiveActivity) as? Bool
            ?? SettingsKey.Default.playbackLiveActivity
    }

    private func start(itemId: String, title: String, subtitle: String) {
        let sample = latestSample ?? (0, 0, false)
        let now = Date()
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: sample.elapsed, duration: sample.duration, isPaused: sample.isPaused, now: now
        )
        do {
            activity = try Activity.request(
                attributes: PlaybackActivityAttributes(itemId: itemId, title: title, subtitle: subtitle),
                content: ActivityContent(state: state, staleDate: state.staleDate(at: now)),
                pushType: nil
            )
            lastPush = PlaybackActivitySnapshot(
                elapsed: sample.elapsed, duration: sample.duration, isPaused: sample.isPaused, at: now
            )
        } catch {
            // Denied / budget exhausted / activities disabled mid-flight. The
            // player is unaffected — log and stay silent.
            logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            activity = nil
            lastPush = nil
        }
    }

    private func push(to activity: Activity<PlaybackActivityAttributes>, snapshot: PlaybackActivitySnapshot) {
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: snapshot.elapsed,
            duration: snapshot.duration,
            isPaused: snapshot.isPaused,
            now: snapshot.at
        )
        let content = ActivityContent(state: state, staleDate: state.staleDate(at: snapshot.at))
        Task { await activity.update(content) }
    }

    /// Title / subtitle split, pure so it can be unit-tested: episodes read as
    /// "Series" + "S2E5 · Episode name", movies as "Name" + "Year".
    nonisolated static func headline(
        seriesName: String?,
        itemName: String?,
        season: Int?,
        episode: Int?,
        year: Int?,
        fallbackTitle: String
    ) -> (title: String, subtitle: String) {
        let name = itemName?.isEmpty == false ? itemName : nil
        if let seriesName, !seriesName.isEmpty {
            var subtitle = ""
            if let season, let episode { subtitle = "S\(season)E\(episode)" }
            if let name {
                subtitle = subtitle.isEmpty ? name : "\(subtitle) · \(name)"
            }
            return (seriesName, subtitle)
        }
        return (name ?? fallbackTitle, year.map(String.init) ?? "")
    }
}

/// One playhead sample as seen by the throttle. Value type, no ActivityKit
/// involvement — unit-tested directly.
struct PlaybackActivitySnapshot: Equatable, Sendable {
    var elapsed: TimeInterval
    var duration: TimeInterval
    var isPaused: Bool
    var at: Date
}

/// Decides whether a 1 s tick warrants an ActivityKit push. Pure.
///
/// The widget already advances the playhead on its own, so a tick that merely
/// confirms "time passed as expected" carries no information — pushing it would
/// spend budget for an identical frame. Only a *discontinuity* matters.
enum PlaybackActivityThrottle {
    /// Drift between the projected and the reported playhead beyond this means
    /// the user seeked (or the engine jumped): the widget's client-side timer is
    /// now wrong and must be re-based. Kept above the ±1 s slop of a 1 s tick and
    /// below the smallest skip in the app (±10 s).
    static let seekTolerance: TimeInterval = 3
    /// Runtime changes below this are reporting noise, not a real re-negotiation.
    static let durationTolerance: TimeInterval = 1

    static func shouldPush(previous: PlaybackActivitySnapshot?, next: PlaybackActivitySnapshot) -> Bool {
        guard let previous else { return true }
        if previous.isPaused != next.isPaused { return true }
        if abs(previous.duration - next.duration) > durationTolerance { return true }
        let projected = previous.isPaused
            ? previous.elapsed
            : previous.elapsed + max(0, next.at.timeIntervalSince(previous.at))
        return abs(next.elapsed - projected) > seekTolerance
    }
}

#else

/// No-op twin for platforms without ActivityKit (tvOS). Keeps the presenters —
/// which are shared iOS/tvOS files — free of `#if` noise at every call site.
@MainActor
final class PlaybackLiveActivityController {
    init(apiClient: any LibraryAPI, userId: String) {}
    func attach(itemId: String, title: String, subtitle: String?, durationSeconds: Double?) {}
    func update(elapsed: Double, duration: Double?, rate: Double) {}
    func detach() {}
    static func endStaleActivities() {}
}

#endif
