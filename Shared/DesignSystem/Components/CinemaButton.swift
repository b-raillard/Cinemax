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

    /// Bumped on every tap so `.sensoryFeedback` fires once per press without
    /// needing the caller to provide a state value to observe.
    @State private var tapCount = 0

    var body: some View {
        Button {
            tapCount &+= 1
            action()
        } label: {
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
        .sensoryFeedback(hapticForStyle, trigger: tapCount)
        #endif
    }

    #if os(iOS)
    /// Accent CTAs (Play, Login, Save) get a meatier impact; primary/ghost get
    /// a light selection tap. Skip when isLoading so multi-tap during async
    /// work doesn't fire repeated haptics.
    private var hapticForStyle: SensoryFeedback {
        isLoading ? .selection : (style == .accent ? .impact(weight: .medium) : .selection)
    }
    #endif

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
            .background(backgroundView(pressed: configuration.isPressed, focused: isFocused))
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            // Accent ring on focus — previously the CTA relied on scale + a
            // faint shadow alone and got lost over a busy backdrop. The accent
            // button gets a light ring (it's already saturated); neutral/ghost
            // buttons get the accent itself.
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(focusRingColor.opacity(isFocused ? 1 : 0), lineWidth: 2.5)
            )
            .scaleEffect(isFocused ? 1.05 : (configuration.isPressed ? 0.95 : 1.0))
            // Subtle lift for relief (buttons are self-contained, so a vertical
            // offset is safe here — unlike poster cards whose title sits outside).
            .offset(y: isFocused && !configuration.isPressed ? -3 : 0)
            .shadow(
                color: focusHaloColor.opacity(isFocused ? 0.42 : 0),
                radius: 24,
                y: 12
            )
            .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
            .animation(motionEnabled ? .easeInOut(duration: 0.1) : nil, value: configuration.isPressed)
    }

    @ViewBuilder
    private func backgroundView(pressed: Bool, focused: Bool) -> some View {
        switch cinemaStyle {
        case .primary:
            CinemaGradient.primaryButton
        case .ghost:
            // Ghost fill brightens on focus so secondary actions (Retry, "From
            // the start", audio/subtitle) read clearly as selected.
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .fill(CinemaColor.surfaceContainerHigh.opacity(focused ? 0.95 : (pressed ? 0.8 : 0.6)))
                .overlay(
                    RoundedRectangle(cornerRadius: CinemaRadius.large)
                        .stroke(CinemaColor.outline.opacity(0.3), lineWidth: 1)
                )
        case .accent:
            themeManager.accentContainer
        }
    }

    /// Focus ring colour — a light ring on the already-saturated accent button,
    /// the accent hue on neutral/ghost buttons.
    private var focusRingColor: Color {
        switch cinemaStyle {
        case .accent:          Color.white.opacity(0.65)
        case .ghost, .primary: themeManager.accent
        }
    }

    /// Focus halo colour. Ghost buttons glow accent (their idle shadow is grey);
    /// the accent button keeps its container tint; primary stays neutral.
    private var focusHaloColor: Color {
        switch cinemaStyle {
        case .primary: CinemaColor.primary
        case .ghost:   themeManager.accent
        case .accent:  themeManager.accentContainer
        }
    }
}
#endif

#if DEBUG
#Preview("CinemaButton styles") {
    VStack(spacing: CinemaSpacing.spacing3) {
        CinemaButton(title: "Play", style: .accent, icon: "play.fill") {}
        CinemaButton(title: "Cancel", style: .primary) {}
        CinemaButton(title: "Retry", style: .ghost, icon: "arrow.clockwise") {}
        CinemaButton(title: "Loading", style: .accent, isLoading: true) {}
    }
    .padding(CinemaSpacing.spacing4)
    .frame(maxWidth: 400)
    .background(CinemaColor.surfaceContainerLowest)
    .environment(ThemeManager())
}
#endif
