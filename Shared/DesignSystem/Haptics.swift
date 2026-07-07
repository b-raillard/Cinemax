import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Central tactile-feedback helper. All haptics in the app route through here so
/// there is a single place that owns the `UIFeedbackGenerator` calls, and so the
/// whole thing collapses to a no-op on tvOS (no Taptic Engine).
///
/// `@MainActor` because `UIFeedbackGenerator` must be driven from the main thread.
/// The video-player HUD deliberately does **not** use this — its feedback is
/// owned by the presenter files.
@MainActor
enum Haptics {
    /// Light impact — toggle flips and other small, discrete state changes.
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Notification-success — a completed / confirmed action (success toasts).
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// Notification-warning — a recoverable problem worth a softer nudge.
    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// Notification-error — a failed action (error toasts).
    static func error() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    /// Selection change — light informational feedback (info toasts).
    static func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}
