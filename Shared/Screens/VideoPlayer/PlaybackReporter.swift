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

    func reportStop() {
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
                positionTicks: positionTicks
            )
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
