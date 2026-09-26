import SwiftUI
import UIKit

// MARK: - Motion Effects Environment Key

extension EnvironmentValues {
    /// The EFFECTIVE motion preference: the app's own Motion Effects toggle AND
    /// the system's Reduce Motion being off. Written once at the root
    /// (`AppNavigation`) through `MotionEffects.isEnabled`; every animation in
    /// the app reads this, never the raw `@AppStorage` key.
    @Entry var motionEffectsEnabled: Bool = true
}

/// Single source of truth for "may this app animate right now?".
///
/// Two inputs: the app's Motion Effects toggle (`SettingsKey.motionEffects`)
/// and the system's Reduce Motion (Accessibility → Motion). Either one turning
/// motion off wins — a user who asked the OS for less motion must not have to
/// find a second switch inside the app, and the app toggle keeps working on
/// its own for people who only dislike Cinemax's effects.
enum MotionEffects {
    /// Pure combination rule, unit-tested (`MotionEffectsTests`).
    nonisolated static func isEnabled(appToggle: Bool, systemReduceMotion: Bool) -> Bool {
        appToggle && !systemReduceMotion
    }

    /// For readers that have no SwiftUI environment (the rainbow accent tick
    /// in `ThemeManager`, the sign-in success dwell in `LoginViewModel`).
    /// Views read `\.motionEffectsEnabled` instead.
    @MainActor static var isEnabledNow: Bool {
        let appToggle = UserDefaults.standard.object(forKey: SettingsKey.motionEffects) as? Bool
            ?? SettingsKey.Default.motionEffects
        return isEnabled(appToggle: appToggle, systemReduceMotion: UIAccessibility.isReduceMotionEnabled)
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
            // Crisper 3 pt accent ring at full opacity (was 2 pt @ 0.8) so the
            // focused card reads unambiguously from the couch.
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(
                        themeManager.accent.opacity(isFocused ? 1 : 0),
                        lineWidth: CinemaTVFocus.cardRingWidth
                    )
            )
            // Accent-tinted halo (was a near-invisible grey glow, off a
            // `surfaceTint` token since deleted)
            // for relief, over a darker ambient shadow that lifts the card off
            // the background without any vertical translation.
            .shadow(
                color: themeManager.accent.opacity(isFocused ? CinemaTVFocus.haloOpacity : 0),
                radius: CinemaTVFocus.haloRadius,
                x: 0, y: 8
            )
            .shadow(
                color: Color.black.opacity(isFocused ? CinemaTVFocus.ambientOpacity : 0),
                radius: CinemaTVFocus.ambientRadius,
                x: 0, y: 16
            )
            .animation(motionEnabled ? .easeInOut(duration: CinemaTVFocus.cardDuration) : nil, value: isFocused)
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
