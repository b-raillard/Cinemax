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

// MARK: - Motion tokens

/// The timings of the app's state-change animations (see
/// `docs/design-system/motion.md`). A new animation takes its curve from here
/// and goes through `gated`, so Motion Effects / Reduce Motion turn it off by
/// passing `nil` — never a zero-duration animation.
enum CinemaMotion {
    /// Favourite / watched glyph bounce.
    static let symbolPop: Animation = .bouncy(duration: 0.45)
    /// Artwork arriving from the network or the disk cache.
    static let imageFade: Animation = .easeOut(duration: 0.3)
    /// Content rising in after a skeleton.
    static let contentReveal: Animation = .easeOut(duration: 0.45)
    /// Delay between two consecutive revealed blocks.
    static let revealStagger: Double = 0.08
    /// Digits rolling inside a label.
    static let numeric: Animation = .snappy(duration: 0.35)
    /// Progress bar filling or gliding to a new position.
    static let progressFill: Animation = .easeOut(duration: 0.7)
    /// A list replaced by another (season change).
    static let listSwap: Animation = .easeOut(duration: 0.34)
    /// UIKit player overlays sliding in and out.
    static let overlaySlide: TimeInterval = 0.3
    static let overlaySlideOut: TimeInterval = 0.2

    /// `animation` when motion is allowed, else `nil` (= apply instantly).
    nonisolated static func gated(_ animation: Animation, enabled: Bool) -> Animation? {
        enabled ? animation : nil
    }
}

/// A toggled SF Symbol (favourite, watched) bounces once and morphs into its
/// new variant instead of swapping in one frame.
private struct SymbolPopModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func body(content: Content) -> some View {
        if motionEnabled {
            content
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: value)
                .animation(CinemaMotion.symbolPop, value: value)
        } else {
            content
        }
    }
}

/// A number inside a label rolls: only the digits that change slide.
private struct RollingNumberModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func body(content: Content) -> some View {
        content
            .contentTransition(motionEnabled ? .numericText() : .identity)
            .animation(CinemaMotion.gated(CinemaMotion.numeric, enabled: motionEnabled), value: value)
    }
}

extension View {
    /// Bounce + symbol replace when `value` changes (gated by Motion Effects).
    func symbolPop<Value: Equatable>(on value: Value) -> some View {
        modifier(SymbolPopModifier(value: value))
    }

    /// Rolling digits when `value` changes. Key it on the NUMBER, never on the
    /// formatted string, so a language change does not roll.
    func rollingNumber<Value: Equatable>(_ value: Value) -> some View {
        modifier(RollingNumberModifier(value: value))
    }
}

// MARK: - Cinema Focus Modifier

struct CinemaFocusModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    #if os(tvOS)
    @Environment(\.seasonID) private var seasonID
    @Environment(\.seasonalAmbianceEnabled) private var ambianceEnabled

    private var seasonGlow: Bool {
        AmbiancePolicy.effects(
            theme: SeasonalThemeCatalogue.theme(id: seasonID),
            ambianceEnabled: ambianceEnabled, motionEnabled: motionEnabled
        ).contains(.focusGlow)
    }
    #endif

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
            // Seasonal « lueur » behind the FOCUSED card only — one glow view on
            // screen, not one per card. Outside the two shadows, so they never
            // re-render an animated layer. The closure keeps the content's
            // identity when the season or the focus changes.
            .background {
                if seasonGlow && isFocused {
                    SeasonalFocusGlow(active: true, color: themeManager.accent, cornerRadius: CinemaRadius.large)
                }
            }
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
