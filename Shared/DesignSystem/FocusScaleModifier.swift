import SwiftUI

// MARK: - Motion Effects Environment Key

private struct MotionEffectsEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var motionEffectsEnabled: Bool {
        get { self[MotionEffectsEnabledKey.self] }
        set { self[MotionEffectsEnabledKey.self] = newValue }
    }
}

// MARK: - Cinema Focus Modifier

struct CinemaFocusModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func body(content: Content) -> some View {
        content
            #if os(tvOS)
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(
                        themeManager.accent.opacity(isFocused ? 0.8 : 0),
                        lineWidth: 2
                    )
            )
            .shadow(
                color: CinemaColor.surfaceTint.opacity(isFocused ? 0.12 : 0),
                radius: 24,
                x: 0, y: 12
            )
            .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
            #else
            // iPad pointer hover. No-op on iPhone (no hover). `.lift` gives a gentle
            // scale + shadow when motion is on; `.highlight` keeps the dim-only fallback
            // when the user disables motion effects.
            .hoverEffect(motionEnabled ? .lift : .highlight)
            #endif
    }
}

extension View {
    func cinemaFocus() -> some View {
        modifier(CinemaFocusModifier())
    }
}
