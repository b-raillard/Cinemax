import SwiftUI

// MARK: - tvOS Button Styles for MediaDetailScreen

#if os(tvOS)

/// Focus indicator for an individual zone inside a shared card background.
/// Shows an accent stroke around the focused zone without adding its own background.
/// Used by the two-zone unified episode row.
struct TVEpisodeZoneButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(isFocused ? 0.06 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(accent.opacity(isFocused ? 0.75 : 0), lineWidth: 2)
                    .padding(1)
            )
            .animation(motionEnabled ? .easeOut(duration: 0.15) : nil, value: isFocused)
    }
}

/// Capsule pill style for the season picker row (selected vs idle, with focus stroke).
struct SeasonTabButtonStyle: ButtonStyle {
    let isSelected: Bool
    let accent: Color
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                Capsule()
                    .strokeBorder(accent.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#endif
