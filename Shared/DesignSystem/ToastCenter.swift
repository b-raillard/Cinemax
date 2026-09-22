import Foundation
import SwiftUI
import UIKit

/// A single queued toast message.
struct Toast: Identifiable, Equatable {
    enum Level: Equatable {
        case success
        case error
        case info

        var systemImage: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error:   return "exclamationmark.triangle.fill"
            case .info:    return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: return .green
            case .error:   return CinemaColor.error
            case .info:    return .blue
            }
        }
    }

    let id = UUID()
    let level: Level
    let title: String
    let message: String?
    let duration: TimeInterval
}

/// Central queue for user-facing feedback toasts. Injected via `.environment`.
/// View layer is `ToastOverlay`.
@MainActor @Observable
final class ToastCenter {
    /// The current visible toast (if any). Only one is displayed at a time.
    private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?

    /// Enqueue and display a toast. If another toast is currently showing, it is replaced.
    ///
    /// Announced to VoiceOver HERE, not by the overlay (audit 2026-09-22, U3):
    /// a toast is feedback for an action — « Ajouté aux favoris », « Marqué
    /// comme vu », an error — and VoiceOver said nothing about any of them. The
    /// overlay also sits under every sheet, so a toast raised from one is never
    /// SEEN; an announcement still reaches the user. Under VoiceOver the toast
    /// also stays up longer, so it can still be reached (and dismissed through
    /// its combined element's action) after the announcement.
    func show(_ toast: Toast) {
        dismissTask?.cancel()
        current = toast
        let voiceOver = UIAccessibility.isVoiceOverRunning
        if voiceOver {
            UIAccessibility.post(notification: .announcement, argument: Self.announcement(for: toast))
        }
        let duration = Self.effectiveDuration(toast.duration, voiceOverRunning: voiceOver)
        dismissTask = Task { [weak self, id = toast.id, duration] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only dismiss if we're still showing the same toast.
                if self?.current?.id == id {
                    self?.current = nil
                }
            }
        }
    }

    func success(_ title: String, message: String? = nil, duration: TimeInterval = 2.5) {
        show(Toast(level: .success, title: title, message: message, duration: duration))
    }

    func error(_ title: String, message: String? = nil, duration: TimeInterval = 4.0) {
        show(Toast(level: .error, title: title, message: message, duration: duration))
    }

    func info(_ title: String, message: String? = nil, duration: TimeInterval = 2.5) {
        show(Toast(level: .info, title: title, message: message, duration: duration))
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    /// What VoiceOver speaks: the title, then the message when there is one.
    nonisolated static func announcement(for toast: Toast) -> String {
        guard let message = toast.message, !message.isEmpty else { return toast.title }
        return "\(toast.title). \(message)"
    }

    /// A toast read by VoiceOver must outlive the announcement and leave time
    /// to reach it: never under 6 s, and twice the sighted duration beyond that.
    nonisolated static func effectiveDuration(_ duration: TimeInterval, voiceOverRunning: Bool) -> TimeInterval {
        voiceOverRunning ? max(duration * 2, 6) : duration
    }
}
