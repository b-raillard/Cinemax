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
            .brightness(isFocused ? CinemaTVFocus.rowBrightness : 0)
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(
                        accent.opacity(isFocused ? CinemaTVFocus.strokeOpacity : 0),
                        lineWidth: CinemaTVFocus.strokeWidth
                    )
                    .padding(1)
            )
            .animation(motionEnabled ? .easeOut(duration: CinemaTVFocus.rowDuration) : nil, value: isFocused)
    }
}

/// Capsule pill style for the season picker row (selected vs idle, with focus stroke).
struct SeasonTabButtonStyle: ButtonStyle {
    let isSelected: Bool
    let accent: Color
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(isFocused ? CinemaTVFocus.rowBrightness : 0)
            .overlay(
                Capsule()
                    .strokeBorder(
                        accent.opacity(isFocused ? CinemaTVFocus.strokeOpacity : 0),
                        lineWidth: CinemaTVFocus.strokeWidth
                    )
            )
            .animation(motionEnabled ? .easeOut(duration: CinemaTVFocus.rowDuration) : nil, value: isFocused)
    }
}

/// Focus treatment for a non-interactive prose block that is nevertheless
/// `.focusable()` so the remote can reach and scroll it.
///
/// Without one, focus lands on the synopsis **invisibly**: the user presses
/// down, the highlight disappears from the action row, and nothing on screen
/// says where it went. A paragraph is the wrong shape for the card ring, so it
/// gets a soft accent wash plus a full-strength text colour instead of a
/// border.
struct TVFocusableProseModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
            // The wash BLEEDS OUTWARD instead of insetting the text: padding
            // here would shift the paragraph relative to every block above and
            // below it the moment focus arrives.
            .background {
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .fill(themeManager.accent.opacity(isFocused ? 0.12 : 0))
                    .padding(-CinemaSpacing.spacing3)
            }
            .animation(motionEnabled ? .easeOut(duration: 0.15) : nil, value: isFocused)
    }
}

extension View {
    /// Applies the prose focus wash. Must sit INSIDE `.focusable()` — the
    /// environment's `isFocused` is published to the focusable view's content,
    /// not to modifiers wrapped around it.
    func tvFocusableProse() -> some View {
        modifier(TVFocusableProseModifier())
    }
}

#endif

#if os(tvOS)
/// One accessory action beside Play on the detail fiche: favourite, watched,
/// add to a playlist, watch together, play on another device.
///
/// The five were unlabelled 28 pt glyphs, which asks the viewer to recognise
/// `text.badge.plus` and `tv.badge.wifi` from three metres — a guessing game
/// iOS never sets, since its own secondary row carries labelled chips. The
/// label is ALWAYS visible rather than revealed on focus: a button that grows a
/// caption when focused reflows the whole row, moving its neighbours under the
/// remote just as the user reaches for them.
struct TVAccessoryActionButton: View {
    let systemImage: String
    let label: String
    /// Accessibility phrasing — the full action ("Add to favorites"), where the
    /// visible label is the short noun ("Favorite").
    let accessibilityLabel: String
    var isActive: Bool = false
    let action: () -> Void

    @Environment(ThemeManager.self) private var themeManager

    /// Fixed so the row's geometry never depends on how long a translation is.
    private let width: CGFloat = 150

    var body: some View {
        Button(action: action) {
            VStack(spacing: CinemaSpacing.spacing2) {
                Image(systemName: systemImage)
                    .font(.system(size: CinemaScale.pt(28), weight: .bold))
                Text(label)
                    .font(CinemaFont.label(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? themeManager.accent : CinemaColor.onSurface)
            .frame(width: width)
            .padding(.vertical, CinemaSpacing.spacing3)
        }
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
        .accessibilityLabel(accessibilityLabel)
    }
}
#endif
