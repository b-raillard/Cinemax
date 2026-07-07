import SwiftUI

/// Top-anchored toast renderer. Reads `ToastCenter.current` and animates a glass pill
/// in/out from the top safe area. Only one toast is visible at a time.
struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    var body: some View {
        VStack {
            if let toast = toasts.current {
                ToastView(toast: toast) {
                    toasts.dismiss()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.top, CinemaSpacing.spacing3)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(toasts.current != nil)
        .animation(motionEnabled ? .spring(response: 0.4, dampingFraction: 0.82) : nil,
                   value: toasts.current)
        #if os(iOS)
        // Haptic feedback paired to toast level — fires only when a new toast
        // appears (guard drops the dismiss → nil transition). Routed through the
        // `Haptics` SSOT so all app haptics live in one place. tvOS has no Taptic Engine.
        .onChange(of: toasts.current) { _, new in
            guard let new else { return }
            switch new.level {
            case .success: Haptics.success()
            case .error:   Haptics.error()
            case .info:    Haptics.selection()
            }
        }
        #endif
    }
}

private struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
            Image(systemName: toast.level.systemImage)
                .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                .foregroundStyle(toast.level.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(2)
                if let msg = toast.message {
                    Text(msg)
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: CinemaScale.pt(13), weight: .bold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.localized("toast.dismiss"))
        }
        .padding(.horizontal, CinemaSpacing.spacing4)
        .padding(.vertical, CinemaSpacing.spacing3)
        .background(.ultraThinMaterial)
        .background(CinemaColor.surfaceContainerHigh.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .strokeBorder(toast.level.tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 20, x: 0, y: 8)
        .accessibilityElement(children: .combine)
    }
}
