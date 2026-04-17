import Foundation
import SwiftUI

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
    func show(_ toast: Toast) {
        dismissTask?.cancel()
        current = toast
        dismissTask = Task { [weak self, id = toast.id, duration = toast.duration] in
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
}
