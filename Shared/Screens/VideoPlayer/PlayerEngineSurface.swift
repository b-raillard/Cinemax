import SwiftUI
import SwiftVLC

/// Shared SwiftUI host for the SwiftVLC rendering surface. iOS uses
/// `PiPVideoView` (libVLC pixel-buffer → `AVPictureInPictureController`) and
/// publishes the `PiPController` back to the presenter; tvOS uses plain
/// `VideoView` (no PiP). Used by `VLCStreamPresenter` in both its stream
/// (iOS + tvOS) and offline (iOS-only) modes.
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
