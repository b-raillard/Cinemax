import SwiftUI

// MARK: - Motion Effects Environment Key

extension EnvironmentValues {
    @Entry var motionEffectsEnabled: Bool = true
}

// MARK: - Cinema Focus Modifier

struct CinemaFocusModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func body(content: Content) -> some View {
        content
            #if os(tvOS)
            // Crisper 3 pt accent ring at full opacity (was 2 pt @ 0.8) so the
            // focused card reads unambiguously from the couch.
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(
                        themeManager.accent.opacity(isFocused ? 1 : 0),
                        lineWidth: 3
                    )
            )
            // Accent-tinted halo (was a near-invisible grey `surfaceTint` glow)
            // for relief, over a darker ambient shadow that lifts the card off
            // the background without any vertical translation.
            .shadow(
                color: themeManager.accent.opacity(isFocused ? 0.35 : 0),
                radius: 22,
                x: 0, y: 8
            )
            .shadow(
                color: Color.black.opacity(isFocused ? 0.45 : 0),
                radius: 26,
                x: 0, y: 16
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
