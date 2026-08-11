import SwiftUI
import UIKit
import OSLog

/// **DIAGNOSTIC ONLY — recette 2026-08 point 3 (zone de clic en recherche).**
///
/// Not a feature. Exists to settle one question with evidence rather than
/// reading: when a long press on the right of card *N* opens card *N+1*'s
/// menu, is the touch genuinely hit-testing into the neighbour's view (a
/// geometry problem), or is it landing on the right card whose modifier holds
/// the wrong item (an identity problem)?
///
/// Answering that needs three facts on one timeline, which is exactly what
/// this emits:
///  1. `touch` — where the finger went down, in window coordinates, plus the
///     screen/orientation context that changes the grid's column maths.
///  2. `frame` — each card's real frame in global coordinates, with its title.
///  3. `menu`  — which item's menu actually got built.
///
/// Read the trace bottom-up: a `menu` line names the item; the `frame` line
/// for that item says whether the preceding `touch` point was inside it.
///
/// Remove this file (and its three call sites) once the point is closed.
enum CardHitLog {
    static let log = Logger(subsystem: "com.cinemax", category: "CardHitDiag")

    // MARK: - Touch probe

    /// Attaches an observer recognizer to **every** window, so every touch-down
    /// is seen **without being intercepted**. The recognizer fails itself
    /// immediately, so it can never claim the gesture, and it neither delays nor
    /// cancels delivery — the point is to watch the existing routing, not to
    /// alter it (changing hit testing while measuring hit testing would make the
    /// trace worthless).
    ///
    /// Idempotent, and meant to be re-called (launch, foreground, tab change):
    /// probing only the key window once at launch was measurably unreliable —
    /// SwiftUI swaps the window afterwards and the probe then went silent with
    /// no error, which reads exactly like "no touch happened".
    @MainActor
    static func installTouchProbe() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                let already = (window.gestureRecognizers ?? []).contains { $0 is TouchProbeRecognizer }
                guard !already else { continue }
                // A target is required: UIKit does not feed touches to a recognizer
                // with no target-action pair (measured — it logged nothing without).
                let recognizer = TouchProbeRecognizer(
                    target: TouchProbeRecognizer.sink, action: #selector(TouchProbeSink.noop)
                )
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                window.addGestureRecognizer(recognizer)
                log.notice("""
                    probe installed on window \
                    \(window.bounds.width, format: .fixed(precision: 1), privacy: .public)\
                    ×\(window.bounds.height, format: .fixed(precision: 1), privacy: .public) \
                    key=\(window.isKeyWindow, privacy: .public)
                    """)
            }
        }
    }

    // MARK: - Emitters

    /// The order the grid actually builds, as (index, id, name). Titles alone
    /// are ambiguous — a search can return several items with the SAME name —
    /// so position↔id is the only way to say whether the menu's item is the one
    /// at the touched position or its neighbour.
    static func noteGridOrder(_ entries: [(id: String?, name: String?)]) {
        let rendered = entries.enumerated()
            .map { "\($0.offset)=\($0.element.id ?? "<nil>") \"\($0.element.name ?? "")\"" }
            .joined(separator: " | ")
        log.notice("grid order (\(entries.count, privacy: .public)) \(rendered, privacy: .public)")
    }

    /// One card's frame in the global coordinate space. Emitted on change only
    /// (`onGeometryChange` already dedups), so a settled grid stays quiet.
    static func noteCardFrame(_ frame: CGRect, name: String?, id: String?) {
        log.notice("""
            frame id=\(id ?? "<nil>", privacy: .public) \
            "\(name ?? "<sans nom>", privacy: .public)" \
            x=\(frame.minX, format: .fixed(precision: 1), privacy: .public) \
            y=\(frame.minY, format: .fixed(precision: 1), privacy: .public) \
            w=\(frame.width, format: .fixed(precision: 1), privacy: .public) \
            h=\(frame.height, format: .fixed(precision: 1), privacy: .public) \
            (xMax=\(frame.maxX, format: .fixed(precision: 1), privacy: .public))
            """)
    }

    /// The menu actually being built — i.e. the item the long press resolved to.
    static func noteMenuOpened(name: String?, id: String?) {
        log.notice("""
            menu OUVERT pour "\(name ?? "<sans nom>", privacy: .public)" \
            id=\(id ?? "<nil>", privacy: .public)
            """)
    }
}

/// Target for the probe. The recognizer never reaches `.began`, so this never
/// fires; it exists only because UIKit requires a target-action pair.
private final class TouchProbeSink: NSObject {
    @objc func noop() {}
}

/// Observer-only recognizer: logs the touch-down point and the display context,
/// then fails so the responder chain is untouched.
private final class TouchProbeRecognizer: UIGestureRecognizer {
    static let sink = TouchProbeSink()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // The recognizer is attached TO the window, so `view` IS the window and
        // `view?.window` is nil — reading it that way silently logged nothing.
        if let touch = touches.first, let window = (view as? UIWindow) ?? view?.window {
            let p = touch.location(in: window)
            let screen = window.screen
            #if os(iOS)
            let orientation = window.windowScene.map { describe($0.interfaceOrientation) } ?? "?"
            #else
            let orientation = "n/a"
            #endif
            let traits = window.traitCollection
            let hSize = describe(traits.horizontalSizeClass)
            let vSize = describe(traits.verticalSizeClass)
            CardHitLog.log.notice("""
                touch x=\(p.x, format: .fixed(precision: 1), privacy: .public) \
                y=\(p.y, format: .fixed(precision: 1), privacy: .public) \
                window=\(window.bounds.width, format: .fixed(precision: 1), privacy: .public)\
                ×\(window.bounds.height, format: .fixed(precision: 1), privacy: .public) \
                screen=\(screen.bounds.width, format: .fixed(precision: 1), privacy: .public)\
                ×\(screen.bounds.height, format: .fixed(precision: 1), privacy: .public) \
                scale=\(screen.scale, format: .fixed(precision: 1), privacy: .public) \
                orientation=\(orientation, privacy: .public) \
                hSize=\(hSize, privacy: .public) \
                vSize=\(vSize, privacy: .public) \
                dynamicType=\(traits.preferredContentSizeCategory.rawValue, privacy: .public) \
                safeLeft=\(window.safeAreaInsets.left, format: .fixed(precision: 1), privacy: .public) \
                safeRight=\(window.safeAreaInsets.right, format: .fixed(precision: 1), privacy: .public)
                """)
        }
        // Never claim the gesture — observation must not change routing.
        state = .failed
    }

    #if os(iOS)
    private func describe(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        default: "unknown"
        }
    }
    #endif

    private func describe(_ sizeClass: UIUserInterfaceSizeClass) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        default: "unspecified"
        }
    }
}
