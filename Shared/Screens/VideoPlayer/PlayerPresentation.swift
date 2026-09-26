import UIKit
import CinemaxKit

/// What both players (and the tvOS coordinator, and `VideoPlayerView`) did in
/// their own copies (audit 2026-09-22, Q4): find the view controller to
/// present from, and hand back a negotiated stream no stop report will close.
@MainActor
enum PlayerPresentation {
    /// The view controller a player, alert or picker is presented from: the top
    /// of the foreground scene's MAIN window.
    ///
    /// Written four times before, each taking the KEY window — and the toast
    /// window (`ToastPassthroughWindow`) is a full-screen window of its own. Had
    /// it ever become key, the player would have been presented INSIDE it,
    /// where every touch outside the toast falls through: a player nobody can
    /// operate. That window is skipped here, and refuses to become key anyway.
    static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return nil
        }
        let windows = scene.windows.filter { !($0 is ToastPassthroughWindow) }
        guard let root = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Hands back the server resources of a `PlaybackInfo` that will never get
    /// a stop report — a failed open, an abandoned negotiation, a superseded
    /// re-resolve. `stopEncoding` fires unconditionally: the engine may have
    /// pulled enough for the server to have started a job before failing.
    nonisolated static func releaseServerSession(_ info: PlaybackInfo, client: any PlaybackAPI) {
        let liveStreamId = info.liveStreamId
        let playSessionId = info.playSessionId
        guard liveStreamId != nil || playSessionId != nil else { return }
        Task.detached {
            if let liveStreamId {
                await client.closeLiveStream(liveStreamId: liveStreamId)
            }
            if let playSessionId {
                await client.stopEncoding(playSessionId: playSessionId)
            }
        }
    }
}
