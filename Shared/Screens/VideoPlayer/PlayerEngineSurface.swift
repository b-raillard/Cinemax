import SwiftUI
import SwiftVLC

/// Shared SwiftUI host for the SwiftVLC rendering surface. iOS uses
/// `PiPVideoView` (libVLC pixel-buffer → `AVPictureInPictureController`) and
/// publishes the `PiPController` back to the presenter; tvOS uses plain
/// `VideoView` (no PiP). Was duplicated as private `EngineSurface`
/// (VLCStreamPresenter, iOS+tvOS) and `OfflineEngineSurface`
/// (VLCOfflinePresenter, iOS) — the offline copy was byte-equivalent to the
/// stream copy's iOS branch, so one type serves both.
@MainActor
struct PlayerEngineSurface: View {
    let player: Player
    var onController: (AnyObject?) -> Void = { _ in }
    #if os(iOS)
    @State private var controller: PiPController?
    #endif

    var body: some View {
        #if os(iOS)
        PiPVideoView(player, controller: Binding(
            get: { controller },
            set: { controller = $0; onController($0) }
        ))
        #else
        VideoView(player)
        #endif
    }
}
