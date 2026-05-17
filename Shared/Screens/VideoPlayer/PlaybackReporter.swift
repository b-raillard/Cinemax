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

    func reportStart(startTime: Double?) {
        guard let ctx = context() else { return }
        let positionTicks = startTime.map { Int($0 * 10_000_000) } ?? 0
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

    func reportStop() {
        guard let ctx = context() else { return }
        let positionTicks = Int((currentState(ctx)?.seconds ?? 0) * 10_000_000)
        let client = apiClient
        let uid = userId
        let itemId = ctx.itemId
        let info = ctx.info
        Task.detached {
            await client.reportPlaybackStopped(
                itemId: itemId, userId: uid,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks
            )
        }
    }

    /// Background entry: app moved to background. Always reports `isPaused: true`
    /// regardless of player rate, so the server shows a paused state even if the
    /// AVPlayer is still technically playing audio.
    func reportBackgroundProgress() {
        guard let ctx = context(), let state = currentState(ctx) else { return }
        let positionTicks = Int(state.seconds * 10_000_000)
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
    }

    /// Call once per second from the presenter's shared time observer.
    /// Reports progress every 10 ticks (~10 s).
    func onTick() {
        tickCounter += 1
        guard tickCounter >= 10 else { return }
        tickCounter = 0
        reportPeriodicProgress()
    }

    private func reportPeriodicProgress() {
        guard let ctx = context(), let state = currentState(ctx) else { return }
        let positionTicks = Int(state.seconds * 10_000_000)
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
