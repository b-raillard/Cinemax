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
                        lineWidth: CinemaTVFocus.cardRingWidth
                    )
            )
            // Accent-tinted halo (was a near-invisible grey `surfaceTint` glow)
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

// MARK: - Hero Ken Burns Drift

#if os(tvOS)
/// A very slow scale drift on a full-bleed hero backdrop.
///
/// iOS heroes rotate through up to five candidates with a crossfade; tvOS was
/// deliberately excluded, because auto-advancing focusable chrome fights the
/// focus engine — so its hero is a single still image that never changes for
/// the life of the screen. This gives the page life without moving anything the
/// remote can aim at: nothing is focusable inside the backdrop, and the drift
/// is far too slow to read as motion while the user is looking at a card.
///
/// The hero clips, so the scaled edges never escape their box. Off entirely
/// when the user has turned motion effects off — this is exactly the kind of
/// ambient animation that setting exists to stop.
struct HeroKenBurnsModifier: ViewModifier {
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    @State private var drifted = false

    /// 1.08 over 24 s, autoreversing — about 0.3 % of the frame per second.
    private let scale: CGFloat = 1.08
    private let period: Double = 24

    func body(content: Content) -> some View {
        content
            .scaleEffect(motionEnabled && drifted ? scale : 1.0)
            .animation(
                motionEnabled
                    ? .easeInOut(duration: period).repeatForever(autoreverses: true)
                    : nil,
                value: drifted
            )
            .onAppear { drifted = true }
    }
}

extension View {
    /// Applies the hero backdrop drift. tvOS only — see `HeroKenBurnsModifier`.
    func heroKenBurns() -> some View {
        modifier(HeroKenBurnsModifier())
    }
}
#endif
