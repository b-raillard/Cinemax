import SwiftUI
import UIKit

/// Hosts `ToastOverlay` in its own window, ABOVE the app's window.
///
/// **Why a window and not an overlay in the view tree:** every sheet, cover
/// and UIKit modal (the VLC player included) is presented ABOVE the root
/// SwiftUI hierarchy, so a root `ToastOverlay` drew underneath all of them — a
/// toast raised from inside « Mes serveurs », « Changer de compte », the admin
/// editors or the player was only seen once the modal was gone (measured
/// 2026-09-23). A window one level above `.normal` sits above every
/// presentation of the app's own window, whichever raised the toast, so no
/// modal has to remember to mount its own overlay.
///
/// The window never becomes key, passes every touch outside the toast pill
/// through (`ToastPassthroughWindow`), and on tvOS takes no input at all: a
/// second window holding a focusable button would compete with the focus
/// engine, and on tvOS a toast is read, not tapped.
struct ToastWindowHost: UIViewRepresentable {
    let toasts: ToastCenter
    let loc: LocalizationManager
    let themeManager: ThemeManager

    func makeUIView(context: Context) -> ToastWindowInstallerView {
        let view = ToastWindowInstallerView()
        view.isUserInteractionEnabled = false
        view.makeRoot = { [toasts, loc, themeManager] window in
            AnyView(ToastWindowRoot(window: window)
                .environment(toasts)
                .environment(loc)
                .environment(themeManager))
        }
        return view
    }

    func updateUIView(_ uiView: ToastWindowInstallerView, context: Context) {}
}

/// Zero-size view whose only job is to learn which `UIWindowScene` the app
/// runs in, then install the toast window there once.
final class ToastWindowInstallerView: UIView {
    var makeRoot: ((ToastPassthroughWindow) -> AnyView)?
    private var toastWindow: ToastPassthroughWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard toastWindow == nil, let scene = window?.windowScene, let makeRoot else { return }
        let overlay = ToastPassthroughWindow(windowScene: scene)
        overlay.windowLevel = .normal + 1
        overlay.backgroundColor = .clear
        let host = ToastHostingController(rootView: makeRoot(overlay))
        host.appWindow = window
        host.view.backgroundColor = .clear
        overlay.rootViewController = host
        #if os(tvOS)
        overlay.isUserInteractionEnabled = false
        #endif
        overlay.isHidden = false
        toastWindow = overlay
    }
}

/// The toast window's root controller, which answers every system-chrome
/// question with the APP window's answer.
///
/// A visible full-screen window above the app is a candidate when UIKit asks
/// who decides the status bar and the home indicator. A plain
/// `UIHostingController` would say "shown" over the VLC player, which asks
/// for both hidden (review of 142db6e, lot 9). Forwarding to the app window's
/// top-most presented controller keeps the player — or a sheet — in charge.
final class ToastHostingController: UIHostingController<AnyView> {
    weak var appWindow: UIWindow?

    #if os(iOS)
    private var appTop: UIViewController? {
        var top = appWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    override var prefersStatusBarHidden: Bool { appTop?.prefersStatusBarHidden ?? false }
    override var preferredStatusBarStyle: UIStatusBarStyle { appTop?.preferredStatusBarStyle ?? .default }
    override var prefersHomeIndicatorAutoHidden: Bool { appTop?.prefersHomeIndicatorAutoHidden ?? false }
    #endif
}

/// Lets every touch that does not land on the toast itself reach the app's
/// window below.
///
/// The toast's frame is REPORTED by SwiftUI (`toastFrame`, window
/// coordinates) rather than inferred from the hit view: SwiftUI hosts its
/// content in internal subviews, so "the hit is the hosting view" is not a
/// reliable test for empty space — measured, it let a tap on the toast's ✕
/// fall through to the sheet button underneath.
final class ToastPassthroughWindow: UIWindow {
    var toastFrame: CGRect = .zero

    /// Never key: the keyboard and the responder chain belong to the app's
    /// window, and every « top view controller » lookup takes the key window
    /// (see `PlayerPresentation.topMostViewController`).
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard toastFrame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The window's root: the same `ToastOverlay`, with the two environment
/// values the app root would have given it recomputed here — a separate
/// window inherits nothing from the SwiftUI tree.
private struct ToastWindowRoot: View {
    weak var window: ToastPassthroughWindow?

    @Environment(ThemeManager.self) private var themeManager
    @AppStorage(SettingsKey.motionEffects) private var motionEffects: Bool = SettingsKey.Default.motionEffects
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        ToastOverlay(onToastFrameChange: { window?.toastFrame = $0 })
            .environment(\.motionEffectsEnabled, MotionEffects.isEnabled(
                appToggle: motionEffects,
                systemReduceMotion: systemReduceMotion
            ))
            // `CinemaColor` resolves through `UITraitCollection`, i.e. the
            // WINDOW's interface style, so the app's own dark/light choice has
            // to be pushed onto this window explicitly.
            .onAppear { applyStyle() }
            // `colorScheme`, not `darkModeEnabled`: the latter reads an
            // `@ObservationIgnored` store and is not tracked, so a switch made in
            // Réglages → Apparence never reached this window until relaunch.
            .onChange(of: themeManager.colorScheme) { _, _ in applyStyle() }
    }

    private func applyStyle() {
        window?.overrideUserInterfaceStyle = themeManager.darkModeEnabled ? .dark : .light
    }
}
