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

    private let apiClient: any PlaybackAPI
    private let userId: String
    private let context: ContextProvider
    private let timeSource: TimeSource?
    private var tickCounter = 0
    /// Separate from `tickCounter`: the cadence differs (30 s vs 10 s) and the
    /// keep-alive carries conditions progress reporting doesn't have.
    private var pingCounter = 0
    private static let pingTickInterval = 30

    init(
        apiClient: any PlaybackAPI,
        userId: String,
        context: @escaping ContextProvider,
        timeSource: TimeSource? = nil
    ) {
        self.apiClient = apiClient
        self.userId = userId
        self.context = context
        self.timeSource = timeSource
    }

    /// Current (positionSeconds, isPaused) from the injected time source if
    /// present, else from the AVPlayer in `Context`.
    private func currentState(_ ctx: Context) -> (seconds: Double, isPaused: Bool)? {
        if let timeSource { return timeSource() }
        guard let player = ctx.player else { return nil }
        return (player.currentTime().seconds, player.rate == 0)
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
        let positionTicks = startTime.map { Self.positionTicks(fromSeconds: $0) } ?? 0
        let client = apiClient
        let uid = userId
        let itemId = ctx.itemId
        let info = ctx.info
        Task.detached {
            await client.reportPlaybackStart(
                itemId: itemId, userId: uid,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, playMethod: info.playMethod
            )
        }
    }

    /// Reports the stop to the server and, for a real end of session, announces
    /// the userData change so every surface can resynchronise.
    ///
    /// **The announcement is deliberately inside the detached task, after the
    /// `reportPlaybackStopped` await.** That call is what persists the new
    /// position server-side AND drops the client's userData caches, so it is the
    /// first instant at which a listener can refetch and get truth. Posting at
    /// call time instead would hand every consumer the pre-playback value — the
    /// exact bug this notification exists to fix, made intermittent by the race.
    func reportStop(reason: PlaybackStopReason = .sessionEnded) {
        guard let ctx = context() else { return }
        let positionTicks = Self.positionTicks(fromSeconds: currentState(ctx)?.seconds ?? 0)
        let client = apiClient
        let uid = userId
        let itemId = ctx.itemId
        let info = ctx.info
        Task.detached {
            await client.reportPlaybackStopped(
                itemId: itemId, userId: uid,
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
        let uid = userId
        let itemId = ctx.itemId
        let info = ctx.info
        Task.detached {
            await client.reportPlaybackProgress(
                itemId: itemId, userId: uid,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, isPaused: true, playMethod: info.playMethod
            )
        }
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
        Task.detached {
            await client.pingPlaybackSession(playSessionId: playSessionId)
        }
    }

    private func reportPeriodicProgress() {
        guard let ctx = context(), let state = currentState(ctx) else { return }
        let positionTicks = Self.positionTicks(fromSeconds: state.seconds)
        let isPaused = state.isPaused
        let client = apiClient
        let uid = userId
        let itemId = ctx.itemId
        let info = ctx.info
        Task.detached {
            await client.reportPlaybackProgress(
                itemId: itemId, userId: uid,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, isPaused: isPaused, playMethod: info.playMethod
            )
        }
    }
}
