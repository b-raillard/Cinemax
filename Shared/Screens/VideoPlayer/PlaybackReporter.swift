import AVFoundation
import CinemaxKit

/// Owns the Jellyfin playback-reporting contract:
/// `reportPlaybackStart` on play, `reportPlaybackProgress` every ~10 s, and
/// `reportPlaybackStopped` on dismiss / episode-nav. Without these calls the
/// server never updates `playbackPositionTicks` / `isPlayed`, so `getNextUp`
/// and resume data stay stale.
///
/// The presenter owns the shared periodic time observer (used by both segment
/// skip detection and progress reporting). It fans out ticks to this reporter
/// via `onTick()`, which applies the 10-tick throttle before reporting.
/// Why a playback session stopped.
///
/// The distinction exists for exactly one reason: `.sessionEnded` announces the
/// userData change to the rest of the app, `.episodeSwap` does not. Both still
/// report the stop to the server — the position of the episode being left has
/// genuinely moved — but the user is still watching, so refreshing every rail
/// mid-session would cost a burst of requests per episode and change nothing
/// the user can see. The announcement happens once, when playback really ends.
enum PlaybackStopReason {
    case sessionEnded
    case episodeSwap
}

@MainActor
final class PlaybackReporter {
    struct Context {
        let itemId: String
        let info: PlaybackInfo
        let player: AVPlayer?
    }

    typealias ContextProvider = @MainActor () -> Context?
    /// Engine-agnostic playback position. `AVPlayer` path leaves this nil and
    /// the reporter reads `Context.player`; the VLC path injects this closure
    /// so the same reporter works without an `AVPlayer`.
    typealias TimeSource = @MainActor () -> (seconds: Double, isPaused: Bool)
    /// A resume position that was asked for and that the engine has not
    /// reached yet (`nil` once it has, or when there is none).
    typealias PendingResumeSource = @MainActor () -> Double?

    private let apiClient: any PlaybackAPI
    private let context: ContextProvider
    private let timeSource: TimeSource?
    private let pendingResume: PendingResumeSource?
    /// Play sessions whose END has already been reported. Jellyfin records
    /// `PositionTicks` from EVERY stop it receives, so a second end report of
    /// the same session (the end-of-series card's « Terminé » after the end
    /// branch already ended it) could only overwrite the first with a worse
    /// position. Only a `.sessionEnded` latches: after an `.episodeSwap` stop
    /// the closing stop must still go out — it carries the position reached
    /// since (a failed swap leaves the old episode playing) and it is the one
    /// that announces tier-2. Cleared per session by `reportStart`.
    private var endedPlaySessionIds: Set<String> = []
    private var tickCounter = 0
    /// The last report in flight. Every start / progress / stop is chained
    /// behind it so they reach the server in the order they were raised: as
    /// independent detached tasks, a slow start could land AFTER the stop of
    /// the same session (re-opening it server-side with a stale position), and
    /// a late progress report could overwrite the position the stop had just
    /// persisted. The keep-alive ping stays outside the chain — it carries no
    /// position and must not wait behind a hung report.
    private var tail: Task<Void, Never>?
    /// Progress reports still queued or in flight. A stop supersedes them —
    /// its own position is the newer truth — so it cancels them rather than
    /// wait: behind a progress stuck on a slow server (30 s request timeout)
    /// the stop that persists the resume point would otherwise wait too, and
    /// an app suspended in that window never sends it. A cancelled progress
    /// still waits its turn, then its request fails at once. A START is never
    /// cancelled: a stop must not overtake the start of its own session.
    private var pendingProgress: [Task<Void, Never>] = []
    /// Separate from `tickCounter`: the cadence differs (30 s vs 10 s) and the
    /// keep-alive carries conditions progress reporting doesn't have.
    private var pingCounter = 0
    private static let pingTickInterval = 30
    /// The most recent keep-alive ping. Nothing in the app waits on it — it is
    /// held only so `drain()` can, which is what lets a test prove a ping was
    /// NOT sent without sleeping (the decision is taken synchronously in
    /// `onTick`, so once the last one launched has landed, none is left).
    private var lastKeepAlive: Task<Void, Never>?

    init(
        apiClient: any PlaybackAPI,
        context: @escaping ContextProvider,
        timeSource: TimeSource? = nil,
        pendingResume: PendingResumeSource? = nil
    ) {
        self.apiClient = apiClient
        self.context = context
        self.timeSource = timeSource
        self.pendingResume = pendingResume
    }

    /// Current (positionSeconds, isPaused) from the injected time source if
    /// present, else from the AVPlayer in `Context` — with a pending resume
    /// position taking precedence over the engine (see `reportableSeconds`).
    private func currentState(_ ctx: Context) -> (seconds: Double, isPaused: Bool)? {
        let engine: (seconds: Double, isPaused: Bool)
        if let timeSource {
            engine = timeSource()
        } else {
            guard let player = ctx.player else { return nil }
            engine = (player.currentTime().seconds, player.rate == 0)
        }
        return (Self.reportableSeconds(engineSeconds: engine.seconds, pendingResumeSeconds: pendingResume?()),
                engine.isPaused)
    }

    /// The position a report may carry.
    ///
    /// **Until the engine has reached the resume position it was asked for, the
    /// report carries THAT position, never the engine's.** Before the media is
    /// open — or before the resume seek has landed — the engine reads 0 (or NaN
    /// on AVPlayer, which `positionTicks` also maps to 0), and Jellyfin persists
    /// `PositionTicks` from every progress AND stop report. So closing the
    /// player during the loading spinner, or on « Lecture impossible », used to
    /// write 0 over a resume point at 1 h 20: the film went back to the start
    /// and dropped out of Continue Watching. Reporting the pending position
    /// instead leaves the server exactly where it was. The position is never
    /// omitted: Jellyfin reads a stop with no `PositionTicks` as "watched".
    nonisolated static func reportableSeconds(engineSeconds: Double, pendingResumeSeconds: Double?) -> Double {
        if let pending = pendingResumeSeconds, pending.isFinite, pending > 0 { return pending }
        return engineSeconds
    }

    /// Converts a playback position in seconds to Jellyfin's 100 ns ticks.
    ///
    /// `Int(seconds * 10_000_000)` **traps** ("Double value cannot be converted
    /// to Int because it is either infinite or NaN") the moment the source
    /// isn't finite — and `AVPlayer.currentTime()` is exactly that whenever no
    /// item is attached: `NativeVideoPresenter.present` builds
    /// `AVPlayer(playerItem: nil)` and only hands it the item after an async
    /// audio-session hop, so a dismiss (`reportStop`) or a background
    /// (`reportBackgroundProgress`) inside that window crashed. Same trap class
    /// as the `Int32(clamping:)` conversions in `VLCStreamPresenter`:
    /// non-finite ⇒ 0, out of `Int` range ⇒ clamped, negative ⇒ 0.
    nonisolated static func positionTicks(fromSeconds seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        let ticks = (seconds * 10_000_000).rounded()
        // `ticks` can itself be infinite here (a finite but astronomically
        // large `seconds` overflows the multiply), so never force the cast.
        guard let exact = Int(exactly: ticks) else { return ticks < 0 ? 0 : Int.max }
        return max(0, exact)
    }

    func reportStart(startTime: Double?) {
        guard let ctx = context() else { return }
        if let id = ctx.info.playSessionId { endedPlaySessionIds.remove(id) }
        let positionTicks = startTime.map { Self.positionTicks(fromSeconds: $0) } ?? 0
        let client = apiClient
        let itemId = ctx.itemId
        let info = ctx.info
        enqueue {
            await client.reportPlaybackStart(
                itemId: itemId,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, playMethod: info.playMethod
            )
        }
    }

    /// Reports the stop to the server and, for a real end of session, announces
    /// the userData change so every surface can resynchronise.
    ///
    /// **The announcement is deliberately inside the queued report, after the
    /// `reportPlaybackStopped` await.** That call is what persists the new
    /// position server-side AND drops the client's userData caches, so it is the
    /// first instant at which a listener can refetch and get truth. Posting at
    /// call time instead would hand every consumer the pre-playback value — the
    /// exact bug this notification exists to fix, made intermittent by the race.
    func reportStop(reason: PlaybackStopReason = .sessionEnded) {
        guard let ctx = context() else { return }
        if let id = ctx.info.playSessionId {
            guard !endedPlaySessionIds.contains(id) else { return }
            if reason == .sessionEnded { endedPlaySessionIds.insert(id) }
        }
        let positionTicks = Self.positionTicks(fromSeconds: currentState(ctx)?.seconds ?? 0)
        let client = apiClient
        let itemId = ctx.itemId
        let info = ctx.info
        pendingProgress.forEach { $0.cancel() }
        pendingProgress.removeAll()
        enqueue {
            await client.reportPlaybackStopped(
                itemId: itemId,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, liveStreamId: info.liveStreamId
            )
            // Announce now, and in its own task so a slow `stopEncoding` below
            // can't delay the UI catching up. Playback is the only producer of
            // this change that used to stay silent: every consumer already
            // listens to tier-2, they were simply never told.
            if reason == .sessionEnded {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .cinemaxItemUserDataChanged, object: nil)
                }
            }
            // Sequential, not concurrent: the server has to record the resume
            // position before we tear the encoding job down. Unconditional —
            // the call is a server-side no-op when nothing was transcoding, and
            // the server can transcode without the client having deduced it.
            if let playSessionId = info.playSessionId {
                await client.stopEncoding(playSessionId: playSessionId)
            }
        }
    }

    /// Background entry: app moved to background. Always reports `isPaused: true`
    /// regardless of player rate, so the server shows a paused state even if the
    /// AVPlayer is still technically playing audio.
    func reportBackgroundProgress() {
        guard let ctx = context(), let state = currentState(ctx) else { return }
        let positionTicks = Self.positionTicks(fromSeconds: state.seconds)
        let client = apiClient
        let itemId = ctx.itemId
        let info = ctx.info
        enqueueProgress {
            await client.reportPlaybackProgress(
                itemId: itemId,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, isPaused: true, playMethod: info.playMethod
            )
        }
    }

    /// Runs `work` after every report raised before it, on this reporter's
    /// chain — including an episode swap's stop followed by the next
    /// episode's start when the presenter reuses its reporter.
    @discardableResult
    private func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task.detached {
            await previous?.value
            await work()
        }
        tail = task
        return task
    }

    private func enqueueProgress(_ work: @escaping @Sendable () async -> Void) {
        pendingProgress.removeAll { $0.isCancelled }
        pendingProgress.append(enqueue(work))
        if pendingProgress.count > 8 { pendingProgress.removeFirst(pendingProgress.count - 8) }
    }

    /// Resolves once every report raised so far has been sent, and the most
    /// recent keep-alive ping with them. Test seam — nothing in the app waits
    /// on reports.
    func drain() async {
        await tail?.value
        await lastKeepAlive?.value
    }

    func resetTicking() {
        tickCounter = 0
        pingCounter = 0
    }

    /// Call once per second from the presenter's shared time observer.
    /// Reports progress every 10 ticks (~10 s), and keeps a transcoding session
    /// alive every 30 ticks while paused.
    func onTick() {
        tickCounter += 1
        if tickCounter >= 10 {
            tickCounter = 0
            reportPeriodicProgress()
        }
        tickKeepAlive()
    }

    /// The server reaps an encoding job it believes idle. While the engine is
    /// pulling segments the job stays active on its own, so the ping only earns
    /// its keep while **paused** — and only on a **transcoding** session, since
    /// a DirectPlay session has no job to keep alive. Net cost on ordinary
    /// playback: zero requests.
    ///
    /// Any unmet condition resets the counter, so a resume can't leave a
    /// residual ping to fire moments later.
    private func tickKeepAlive() {
        guard let ctx = context(),
              ctx.info.playMethod == .transcode,
              let playSessionId = ctx.info.playSessionId,
              let state = currentState(ctx),
              state.isPaused else {
            pingCounter = 0
            return
        }
        pingCounter += 1
        guard pingCounter >= Self.pingTickInterval else { return }
        pingCounter = 0
        let client = apiClient
        lastKeepAlive = Task.detached {
            await client.pingPlaybackSession(playSessionId: playSessionId)
        }
    }

    private func reportPeriodicProgress() {
        guard let ctx = context(), let state = currentState(ctx) else { return }
        let positionTicks = Self.positionTicks(fromSeconds: state.seconds)
        let isPaused = state.isPaused
        let client = apiClient
        let itemId = ctx.itemId
        let info = ctx.info
        enqueueProgress {
            await client.reportPlaybackProgress(
                itemId: itemId,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, isPaused: isPaused, playMethod: info.playMethod
            )
        }
    }
}
