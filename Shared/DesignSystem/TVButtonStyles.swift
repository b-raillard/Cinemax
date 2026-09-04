import SwiftUI

#if os(tvOS)

// MARK: - tvOS Focus Language

/// The two focus levels tvOS uses, and nothing else.
///
/// Four unrelated treatments used to coexist — a 3 pt ring on cards, a 2 pt
/// stroke on chips, a 1.5 pt stroke at 0.8 opacity on settings rows, and a
/// bespoke fill-plus-shadow on the settings landing pills. The visible symptom
/// was that a settings row's focus read markedly fainter than a filter chip's
/// on the same screen, so "where am I?" answered differently depending on which
/// control the remote happened to be over.
///
/// **Card** — a poster, a still, a tile: accent ring, accent halo, and it grows.
/// Composed of `cinemaFocus()` (ring + halo) and `CinemaTVCardButtonStyle`
/// (scale + brightness).
///
/// **Row / chip** — a settings row, a filter pill, a season tab, an episode
/// zone: accent stroke and it brightens, but it does NOT grow. A full-width row
/// that scales visibly shifts its own content sideways, and a chip that grows
/// crowds its neighbours in a `FlowLayout`.
enum CinemaTVFocus {
    // MARK: Card level

    /// Ring around a focused card. Full opacity and 3 pt so it reads
    /// unambiguously from the couch.
    static let cardRingWidth: CGFloat = 3
    /// Growth on focus. ~8 pt on the 6-column grid poster, well inside the
    /// 32 pt gutter, so a focused card never overlaps its neighbours — every
    /// card-bearing scroll row still needs `.scrollClipDisabled()` so the edge
    /// card is not clipped.
    static let cardScale: CGFloat = 1.06
    static let cardBrightness: Double = 0.08
    /// Accent halo, over a darker ambient shadow that lifts the card off the
    /// background without any vertical translation.
    static let haloRadius: CGFloat = 22
    static let haloOpacity: Double = 0.35
    static let ambientRadius: CGFloat = 26
    static let ambientOpacity: Double = 0.45

    // MARK: Row / chip level

    /// One stroke width and one opacity for every row and chip in the app.
    static let strokeWidth: CGFloat = 2
    static let strokeOpacity: Double = 1
    static let rowBrightness: Double = 0.06

    // MARK: Shared

    /// Press feedback. Cards dip further because they are larger.
    static let cardPressScale: CGFloat = 0.97
    static let chipPressScale: CGFloat = 0.95
    /// Focus transitions. Rows settle faster than cards: they carry no scale,
    /// so a slower curve reads as lag rather than as motion.
    static let cardDuration: Double = 0.2
    static let rowDuration: Double = 0.15
    static let pressDuration: Double = 0.1
}

// MARK: - tvOS Card Button Style

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
            .scaleEffect(
                configuration.isPressed
                    ? CinemaTVFocus.cardPressScale
                    : (isFocused ? CinemaTVFocus.cardScale : 1.0)
            )
            .brightness(isFocused ? CinemaTVFocus.cardBrightness : 0)
            .animation(motionEnabled ? .easeInOut(duration: CinemaTVFocus.cardDuration) : nil, value: isFocused)
            .animation(motionEnabled ? .easeInOut(duration: CinemaTVFocus.pressDuration) : nil, value: configuration.isPressed)
    }
}

struct TVFilterChipButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(isFocused ? CinemaTVFocus.rowBrightness : 0)
            .scaleEffect(configuration.isPressed ? CinemaTVFocus.chipPressScale : 1.0)
            .overlay(
                Capsule()
                    .strokeBorder(
                        accent.opacity(isFocused ? CinemaTVFocus.strokeOpacity : 0),
                        lineWidth: CinemaTVFocus.strokeWidth
                    )
            )
            .animation(motionEnabled ? .easeOut(duration: CinemaTVFocus.rowDuration) : nil, value: isFocused)
            .animation(motionEnabled ? .easeInOut(duration: CinemaTVFocus.pressDuration) : nil, value: configuration.isPressed)
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
            .brightness(isFocused ? CinemaTVFocus.rowBrightness : 0)
            .overlay(
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(
                        accent.opacity(isFocused ? CinemaTVFocus.strokeOpacity : 0),
                        lineWidth: CinemaTVFocus.strokeWidth
                    )
            )
            .animation(motionEnabled ? .easeOut(duration: CinemaTVFocus.rowDuration) : nil, value: isFocused)
    }
}
#endif
