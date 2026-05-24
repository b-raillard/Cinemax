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
        // `.ignoresSafeArea()` is required: SwiftUI's safe area on tvOS is the
        // TV's overscan margin (~5% inset per edge); on iOS it's the status
        // bar / notch area. Without it the hosted `UIViewRepresentable`
        // shrinks inside the inset and libVLC's drawable sits in a centered
        // rectangle smaller than the screen — "video in a smaller window with
        // black bars on all 4 sides." `AVPlayerViewController` is unaffected
        // because it's pure UIKit and never traverses SwiftUI layout.
        #if os(iOS)
        PiPVideoView(player, controller: Binding(
            get: { controller },
            set: { controller = $0; onController($0) }
        ))
        .ignoresSafeArea()
        #else
        VideoView(player)
            .ignoresSafeArea()
        #endif
    }
}
