import SwiftUI

enum CinemaButtonStyle {
    case primary
    case ghost
    case accent
}

struct CinemaButton: View {
    @Environment(ThemeManager.self) private var themeManager
    let title: String
    var style: CinemaButtonStyle = .primary
    var icon: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CinemaSpacing.spacing2) {
                if isLoading {
                    ProgressView()
                        .tint(textColor)
                        .scaleEffect(0.8)
                } else {
                    Text(title)
                        .font(.system(size: fontSize, weight: .bold))
                        .tracking(-0.3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: fontSize - 2, weight: .bold))
                    }
                }
            }
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, CinemaSpacing.spacing4)
            #if os(iOS)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: style))
        #else
        .buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    var background: some View {
        switch style {
        case .primary:
            CinemaGradient.primaryButton
        case .ghost:
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: CinemaRadius.large)
                        .stroke(CinemaColor.outline.opacity(0.2), lineWidth: 1)
                )
        case .accent:
            themeManager.accentContainer
        }
    }

    private var textColor: Color {
        switch style {
        case .primary: CinemaColor.onPrimary
        case .ghost: CinemaColor.onSurface
        case .accent: .white
        }
    }

    private var fontSize: CGFloat {
        #if os(tvOS)
        28
        #else
        18
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing4
        #else
        CinemaSpacing.spacing2
        #endif
    }
}

// MARK: - tvOS Button Style

#if os(tvOS)
struct CinemaTVButtonStyle: ButtonStyle {
    let cinemaStyle: CinemaButtonStyle
    // ThemeManager is read from environment so every call site auto-picks up
    // the current accent color without needing to pass it explicitly.
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(backgroundView(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            .scaleEffect(isFocused ? 1.05 : (configuration.isPressed ? 0.95 : 1.0))
            .shadow(
                color: shadowColor.opacity(isFocused ? 0.3 : 0),
                radius: 20,
                y: 10
            )
            .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
            .animation(motionEnabled ? .easeInOut(duration: 0.1) : nil, value: configuration.isPressed)
    }

    @ViewBuilder
    private func backgroundView(pressed: Bool) -> some View {
        switch cinemaStyle {
        case .primary:
            CinemaGradient.primaryButton
        case .ghost:
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .fill(CinemaColor.surfaceContainerHigh.opacity(pressed ? 0.8 : 0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: CinemaRadius.large)
                        .stroke(CinemaColor.outline.opacity(0.3), lineWidth: 1)
                )
        case .accent:
            themeManager.accentContainer
        }
    }

    private var shadowColor: Color {
        switch cinemaStyle {
        case .primary: CinemaColor.primary
        case .ghost: CinemaColor.surfaceTint
        case .accent: themeManager.accentContainer
        }
    }
}
#endif
