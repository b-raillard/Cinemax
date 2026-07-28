import Foundation
import CinemaxKit

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import UIKit
import os

private let logger = Logger(subsystem: "com.cinemax", category: "LiveActivity")

/// Owns the playback Live Activity (Lock Screen banner + Dynamic Island) for the
/// current session. Third sibling of `RemoteCommandController` (the buttons) and
/// `NowPlayingInfoController` (the Now Playing metadata) — same discipline, same
/// seams, and deliberately NOT merged with either: this one drives a completely
/// separate system surface with its own budget and lifecycle rules.
///
/// Presenter contract, mirroring `NowPlayingInfoController`:
/// `attach` on play / episode-nav, `update` from the existing 1 s tick + on every
/// play/pause and rate transition, `detach` on teardown. It adds no timer.
///
/// **Budget discipline**: `update` is called every second but pushes to
/// ActivityKit only when the timeline *shape* changes — the widget renders the
/// moving playhead client-side off `ContentState.startedAt`, and the throttle's
/// projection is rate-aware so steady playback at ANY speed pushes nothing. See
/// `PlaybackActivityThrottle`.
///
/// **Lifecycle**: `desired` is what should be on screen, `presented` is what the
/// running activity actually carries; `reconcile()` closes the gap whenever it
/// can. That indirection exists because `Activity.request` **throws from the
/// background** — an episode swap while the phone is locked must NOT end the old
/// activity (it could never be replaced), so it keeps it and only re-bases the
/// timeline, deferring the real re-attach to the next foregrounding. The same
/// path retries a request that failed for any other reason.
///
/// v1 is display-only. Interactive pause/play (a `LiveActivityIntent` button in
/// the widget) is explicitly v2.
@MainActor
final class PlaybackLiveActivityController {
    /// The static attributes an activity carries. Frozen for its lifetime by
    /// ActivityKit, so a change here means end + re-request.
    private struct Descriptor: Equatable {
        var itemId: String
        var title: String
        var subtitle: String
    }

    private let apiClient: any LibraryAPI
    private let userId: String

    private var activity: Activity<PlaybackActivityAttributes>?
    /// What the running activity carries; `nil` when none is running.
    private var presented: Descriptor?
    /// What we want on screen. Diverges from `presented` while a re-attach is
    /// pending (backgrounded episode swap, or a request that failed).
    private var desired: Descriptor?

    /// Last sample actually pushed; drives the throttle.
    private var lastPush: PlaybackActivitySnapshot?
    /// Newest sample seen, pushed or not. The request is deferred behind the
    /// title/subtitle lookup and the user can pause or seek inside that window,
    /// so the eventual request reads this rather than a stale zero.
    private var latestSample: PlaybackActivitySnapshot?

    /// Race guard, same pattern as `NowPlayingInfoController`: bumped whenever
    /// the attached item changes, re-read at write-back so a lookup that lands
    /// after an episode swap can't describe the episode the user already left.
    private var generation = 0
    /// Generation whose descriptor already reached `desired` — the sentinel that
    /// keeps the lookup and its deadline from both starting an activity.
    private var resolvedGeneration = -1
    private var enrichTask: Task<Void, Never>?
    private var enrichDeadlineTask: Task<Void, Never>?
    /// Serialises every ActivityKit mutation (see `enqueue`).
    private var pushChain: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    /// How long to wait for the item lookup before starting the banner with the
    /// presenter's own title. The client's request timeout is 30 s, and a
    /// stalled server must not hold the Lock Screen back that long.
    private static let enrichDeadline: Duration = .milliseconds(1500)

    init(apiClient: any LibraryAPI, userId: String) {
        self.apiClient = apiClient
        self.userId = userId
    }

    // MARK: - Presenter seams

    /// Resolves the display strings, then reconciles the activity onto them.
    ///
    /// - Parameters:
    ///   - subtitle: lets a caller that already knows it skip the lookup; both
    ///     presenters pass `nil` (neither carries a resolved series / S×E× yet).
    ///   - startAtSeconds: the resume position the player is about to seek to.
    ///     Seeding it here means the banner opens on the right playhead instead
    ///     of anchoring at 0 and self-correcting one tick (and one push) later.
    func attach(
        itemId: String,
        title: String,
        subtitle: String?,
        durationSeconds: Double?,
        startAtSeconds: Double?
    ) {
        cancelPendingResolution()
        let gen = generation
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            desired = nil
            endCurrentActivity()
            stopObservingForeground()
            return
        }
        latestSample = PlaybackActivitySnapshot(
            elapsed: max(0, startAtSeconds ?? 0),
            duration: durationSeconds ?? 0,
            rate: 1,
            at: Date()
        )
        lastPush = nil
        startObservingForeground()

        if let subtitle, !subtitle.isEmpty {
            applyDescriptor(Descriptor(itemId: itemId, title: title, subtitle: subtitle), generation: gen)
            return
        }
        // `getItem` is single-flighted + 10 s cached, and `NowPlayingInfoController`
        // fires the same lookup for the same item in the same breath — so this is
        // normally a cache hit, not a second round trip. Resolving BEFORE the
        // request (rather than starting bare and updating) is required:
        // ActivityKit freezes `ActivityAttributes` for the activity's lifetime.
        let apiClient = self.apiClient
        let userId = self.userId
        enrichTask = Task { @MainActor [weak self] in
            let item = try? await apiClient.getItem(userId: userId, itemId: itemId)
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            let headline = Self.headline(
                seriesName: item?.seriesName,
                itemName: item?.name,
                season: item?.parentIndexNumber,
                episode: item?.indexNumber,
                year: item?.productionYear,
                fallbackTitle: title
            )
            self.applyDescriptor(
                Descriptor(itemId: itemId, title: headline.title, subtitle: headline.subtitle),
                generation: gen
            )
        }
        // Deadline: whoever gets there first wins, and a late lookup is dropped
        // rather than tearing the banner down to re-request with better strings.
        enrichDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.enrichDeadline)
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.applyDescriptor(
                Descriptor(itemId: itemId, title: title, subtitle: ""),
                generation: gen
            )
        }
    }

    /// Cheap per-tick call from the presenter's existing 1 s heartbeat and from
    /// its play/pause + rate transitions. `rate` is the REAL engine rate (`0`
    /// when paused, `0.5`–`2` from the speed picker / hold-to-boost) — collapsing
    /// it to 0/1 makes the throttle's projection drift a second per second and
    /// mis-renders the widget's client-side timer.
    func update(elapsed: Double, duration: Double?, rate: Double) {
        // The user can turn the feature off mid-playback; the banner must go.
        guard isEnabled else {
            if activity != nil || desired != nil { detach() }
            return
        }
        let resolvedDuration: Double = {
            if let duration, duration.isFinite, duration > 0 { return duration }
            return latestSample?.duration ?? 0
        }()
        let next = PlaybackActivitySnapshot(
            elapsed: elapsed, duration: resolvedDuration, rate: rate, at: Date()
        )
        latestSample = next
        guard activity != nil else { return }
        guard PlaybackActivityThrottle.shouldPush(previous: lastPush, next: next) else { return }
        push(next)
    }

    /// Ends the activity and drops all pending work. Idempotent.
    func detach() {
        cancelPendingResolution()
        desired = nil
        latestSample = nil
        stopObservingForeground()
        endCurrentActivity()
    }

    /// Sweeps activities orphaned by a crash / force-quit. Called once at launch
    /// from `AppNavigation`'s root task; the controller sweeps again per attach
    /// through `endOtherActivities()`, which spares the one it owns.
    static func endStaleActivities() {
        for activity in Activity<PlaybackActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: - Lifecycle reconciliation

    private func applyDescriptor(_ descriptor: Descriptor, generation gen: Int) {
        guard resolvedGeneration != gen else { return }
        resolvedGeneration = gen
        desired = descriptor
        reconcile()
    }

    /// Closes the gap between `desired` and `presented`, if the OS lets us.
    private func reconcile() {
        guard let desired else {
            endCurrentActivity()
            return
        }
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            self.desired = nil
            endCurrentActivity()
            return
        }
        if activity != nil, presented == desired { return }

        guard UIApplication.shared.applicationState == .active else {
            // `Activity.request` throws from the background. Ending the running
            // activity here would strand the session with no banner and no way
            // to make one — so keep it, re-base its timeline onto the new item,
            // and let the next foregrounding do the real swap. The title stays
            // the previous episode's until then: an accepted v1 trade, since the
            // attributes are frozen and can't be updated in place.
            if activity != nil, let latestSample { push(latestSample) }
            return
        }
        endCurrentActivity()
        start(desired)
    }

    private func start(_ descriptor: Descriptor) {
        // A crash or force-quit leaves the previous session's banner pinned to
        // the Lock Screen. Ours is already ended by `reconcile`, so this only
        // catches orphans.
        endOtherActivities()

        let sample = latestSample
            ?? PlaybackActivitySnapshot(elapsed: 0, duration: 0, rate: 1, at: Date())
        let now = Date()
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: sample.elapsed, duration: sample.duration, rate: sample.rate, now: now
        )
        do {
            activity = try Activity.request(
                attributes: PlaybackActivityAttributes(
                    itemId: descriptor.itemId, title: descriptor.title, subtitle: descriptor.subtitle
                ),
                content: ActivityContent(state: state, staleDate: state.staleDate(at: now)),
                pushType: nil
            )
            presented = descriptor
            lastPush = PlaybackActivitySnapshot(
                elapsed: sample.elapsed, duration: sample.duration, rate: sample.rate, at: now
            )
        } catch {
            // Denied / budget exhausted / requested too early. `presented` stays
            // out of step with `desired`, so the next foregrounding retries.
            logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            activity = nil
            presented = nil
            lastPush = nil
        }
    }

    private func endCurrentActivity() {
        presented = nil
        lastPush = nil
        guard let activity else { return }
        self.activity = nil
        let box = ActivityBox(activity)
        enqueue { await box.activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ends every activity of ours EXCEPT the one this controller holds.
    private func endOtherActivities() {
        let mine = activity?.id
        for orphan in Activity<PlaybackActivityAttributes>.activities where orphan.id != mine {
            let box = ActivityBox(orphan)
            enqueue { await box.activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func push(_ snapshot: PlaybackActivitySnapshot) {
        guard let activity else { return }
        lastPush = snapshot
        let state = PlaybackActivityAttributes.ContentState.make(
            elapsed: snapshot.elapsed,
            duration: snapshot.duration,
            rate: snapshot.rate,
            now: snapshot.at
        )
        let content = ActivityContent(state: state, staleDate: state.staleDate(at: snapshot.at))
        let box = ActivityBox(activity)
        enqueue { await box.activity.update(content) }
    }

    /// Launders a non-Sendable `Activity` into a `Sendable` value so the async
    /// `update`/`end` calls can cross into the serialising chain's executor.
    /// `Activity` is non-Sendable and its async methods "send" the instance off
    /// the main actor — which Xcode 26.5's region checker rejects (local 26.2 was
    /// laxer) — but ActivityKit documents those methods as thread-safe, so the
    /// `@unchecked` assertion is sound. Same escape-hatch class as
    /// `PiPRestoreHandlerBox`.
    private struct ActivityBox: @unchecked Sendable {
        let activity: Activity<PlaybackActivityAttributes>
        init(_ activity: Activity<PlaybackActivityAttributes>) { self.activity = activity }
    }

    /// Serialises every ActivityKit mutation. `update` / `end` are async, and two
    /// independent `Task`s can complete out of order — a pause immediately
    /// followed by a seek would then leave the banner showing the pause. Chaining
    /// each call behind the previous one guarantees the widget observes the same
    /// order the player produced. Each closure captures only a `Sendable`
    /// `ActivityBox` plus `Sendable` content, never a raw `Activity`.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pushChain
        pushChain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func cancelPendingResolution() {
        generation += 1
        enrichTask?.cancel()
        enrichTask = nil
        enrichDeadlineTask?.cancel()
        enrichDeadlineTask = nil
    }

    // MARK: - Foreground observation

    private func startObservingForeground() {
        guard foregroundObserver == nil else { return }
        // `[weak self]` belongs on the OUTER observer block: that is the closure
        // NotificationCenter retains until `removeObserver`, so capturing self
        // strongly there pins the controller for the observer's whole lifetime
        // (the inner capture list only weakened an already-strong reference).
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    private func stopObservingForeground() {
        guard let foregroundObserver else { return }
        NotificationCenter.default.removeObserver(foregroundObserver)
        self.foregroundObserver = nil
    }

    // MARK: - Private

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.playbackLiveActivity) as? Bool
            ?? SettingsKey.Default.playbackLiveActivity
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

/// One playhead sample as seen by the throttle. `rate <= 0` means paused. Value
/// type, no ActivityKit involvement — unit-tested directly.
struct PlaybackActivitySnapshot: Equatable, Sendable {
    var elapsed: TimeInterval
    var duration: TimeInterval
    /// Real engine rate: `0` paused, `1` normal, `0.5`–`2` off-speed.
    var rate: Double
    var at: Date

    var isPaused: Bool { !(rate.isFinite && rate > 0) }
}

/// Decides whether a 1 s tick warrants an ActivityKit push. Pure.
///
/// The widget already advances the playhead on its own — at whatever rate the
/// state was anchored to — so a tick that merely confirms "time passed as
/// expected" carries no information; pushing it would spend budget on an
/// identical frame. Only a *discontinuity* matters.
enum PlaybackActivityThrottle {
    /// Drift between the projected and the reported playhead beyond this means
    /// the user seeked (or the engine jumped): the widget's client-side timer is
    /// now wrong and must be re-based. Kept above the ±1 s slop of a 1 s tick and
    /// below the smallest skip in the app (±10 s).
    static let seekTolerance: TimeInterval = 3
    /// Runtime changes below this are reporting noise, not a real re-negotiation.
    static let durationTolerance: TimeInterval = 1
    /// Rate changes below this are float noise, not a speed-picker move.
    static let rateTolerance: Double = 0.01

    static func shouldPush(previous: PlaybackActivitySnapshot?, next: PlaybackActivitySnapshot) -> Bool {
        guard let previous else { return true }
        if previous.isPaused != next.isPaused { return true }
        // A speed change re-scales the widget's whole timeline anchor.
        if !next.isPaused, abs(previous.rate - next.rate) > rateTolerance { return true }
        if abs(previous.duration - next.duration) > durationTolerance { return true }
        // Rate-aware projection: at 2× the playhead legitimately advances 2 s per
        // wall-clock second, and treating that as drift would push every ~4 s.
        let wallClock = max(0, next.at.timeIntervalSince(previous.at))
        let projected = previous.elapsed + max(0, previous.rate) * wallClock
        return abs(next.elapsed - projected) > seekTolerance
    }
}

#else

/// No-op twin for platforms without ActivityKit (tvOS). Keeps the presenters —
/// which are shared iOS/tvOS files — free of `#if` noise at every call site.
@MainActor
final class PlaybackLiveActivityController {
    init(apiClient: any LibraryAPI, userId: String) {}
    func attach(
        itemId: String,
        title: String,
        subtitle: String?,
        durationSeconds: Double?,
        startAtSeconds: Double?
    ) {}
    func update(elapsed: Double, duration: Double?, rate: Double) {}
    func detach() {}
    static func endStaleActivities() {}
}

#endif
