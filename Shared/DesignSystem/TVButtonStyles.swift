import SwiftUI

// MARK: - tvOS Card Button Style

#if os(tvOS)
struct CinemaTVCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .brightness(isFocused ? 0.05 : 0)
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
