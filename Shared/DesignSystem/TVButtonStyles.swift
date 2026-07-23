import SwiftUI

// MARK: - tvOS Card Button Style

#if os(tvOS)
struct CinemaTVCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Focus grows the card 1.06× so it visibly "pops" out of a dense
            // grid at 10-foot distance (repérage). A pressed card wins with the
            // 0.97 dip. The growth (~8 pt on a ~274 pt tvOS grid poster) stays
            // well inside the 32 pt gutter, so a single focused card never
            // overlaps its neighbours — see the grid's `.scrollClipDisabled()`.
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1.0))
            .brightness(isFocused ? 0.08 : 0)
            .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
            .animation(motionEnabled ? .easeInOut(duration: 0.1) : nil, value: configuration.isPressed)
    }
}

struct TVFilterChipButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .overlay(
                Capsule()
                    .strokeBorder(accent, lineWidth: isFocused ? 2 : 0)
            )
            .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
            .animation(motionEnabled ? .easeInOut(duration: 0.1) : nil, value: configuration.isPressed)
    }
}

/// Full-width rectangular row variant. Same focus accent stroke as
/// `TVFilterChipButtonStyle` but no press-scale (the row is wide enough that
/// scaling makes its internal content visibly shift sideways) and a rounded
/// rectangle border that matches a row shape rather than a capsule.
struct TVFilterRowButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(accent, lineWidth: isFocused ? 2 : 0)
            )
            .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
    }
}
#endif
