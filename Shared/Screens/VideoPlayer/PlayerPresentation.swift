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
        guard let root = mainRootViewController() else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Whether UIKit will accept a presentation from `presenter`: its view must
    /// be in a window (a popover on its way out is not). A presentation
    /// requested during another transition is DEFERRED by UIKit, not refused,
    /// so this is asked BEFORE presenting, never judged after.
    static func canPresent(from presenter: UIViewController) -> Bool {
        presenter.viewIfLoaded?.window != nil && !presenter.isBeingDismissed
    }

    /// Closes whatever is presented over the main window — a sheet, a cover,
    /// a popover, a player — then runs `then`. For a request to open a title
    /// NOW (« Lire sur… » from another device, a widget, Siri): with the
    /// account switcher open, the fiche's sheet was refused, the player too,
    /// and nothing appeared (recette 2026-10-27, NEW-1). Runs `then` at once
    /// when nothing is presented.
    static func dismissPresentations(then: @escaping @MainActor () -> Void) {
        guard let root = mainRootViewController(), root.presentedViewController != nil else {
            then()
            return
        }
        root.dismiss(animated: false) { then() }
    }

    private static func mainRootViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return nil
        }
        let windows = scene.windows.filter { !($0 is ToastPassthroughWindow) }
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
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
