import SwiftUI

/// The season's STILL decor in the corners of the screen — for « Givre »,
/// frost on the window: a cold haze and fine ice feathers that thicken toward
/// the corners, as if the film were watched through a frosted pane. Two
/// places: OVER the content on the tab roots that have a hero (Home, the
/// libraries, as the last layer of their root stack) and inside
/// `SeasonalBackdrop`, BEHIND the content, on every other browsing screen —
/// where frost in front would sit on the back button. The texture is rendered
/// by `design/noel/givre.py`.
///
/// Nothing moves, so Reduce Motion keeps it; the « Animations d'ambiance »
/// switch removes it (`\.seasonalAmbianceEnabled`). Not interactive, hidden
/// from VoiceOver.
struct SeasonalTopDecor: View {
    @Environment(\.seasonID) private var seasonID
    @Environment(\.seasonalAmbianceEnabled) private var ambianceEnabled
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        if ambianceEnabled, SeasonalThemeCatalogue.theme(id: seasonID)?.decor == .frost {
            GeometryReader { geo in
                // The corner radius follows the screen's size (CSS's
                // `circle at 0 0` percentage, the artifact's reference).
                let reference = ((geo.size.width * geo.size.width + geo.size.height * geo.size.height) / 2).squareRoot()
                let top = reference * reach.top
                let bottom = reference * reach.bottom
                SeasonalFrostMaterial()
                    .mask {
                        ZStack {
                            corner(.topLeading, radius: top)
                            corner(.topTrailing, radius: top)
                            if bottom > 0 {
                                corner(.bottomLeading, radius: bottom)
                                corner(.bottomTrailing, radius: bottom)
                            }
                        }
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// How far the frost reaches from the corners, as a fraction of the
    /// screen's reference size. The iPhone keeps its bottom corners clear: the
    /// tab bar sits there.
    private var reach: (top: CGFloat, bottom: CGFloat) {
        #if os(tvOS)
        (0.18, 0.14)
        #else
        sizeClass == .regular ? (0.16, 0.12) : (0.22, 0)
        #endif
    }

    private func corner(_ point: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.8), location: 0.35),
                .init(color: .clear, location: 1)
            ],
            center: point, startRadius: 0, endRadius: radius
        )
    }
}

/// Frost on the edges of a hero's backdrop — the middle of the image stays
/// clear, the frost gathers at the borders like on a cold window. An overlay
/// of the backdrop, under the hero's text (`HomeScreen.heroSection`,
/// `LibraryHeroSection`). Same switch as the corners.
struct SeasonalHeroFrost: View {
    @Environment(\.seasonID) private var seasonID
    @Environment(\.seasonalAmbianceEnabled) private var ambianceEnabled

    var body: some View {
        if ambianceEnabled, SeasonalThemeCatalogue.theme(id: seasonID)?.decor == .frost {
            SeasonalFrostMaterial()
                .mask {
                    EllipticalGradient(
                        stops: [.init(color: .clear, location: 0.64), .init(color: .black, location: 0.96)],
                        center: UnitPoint(x: 0.62, y: 0.42),
                        startRadiusFraction: 0, endRadiusFraction: 0.72
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The frost itself: a cold haze under the tiled ice texture
/// (`SeasonFrost`). White frost on the light page would vanish; there the
/// haze is a whiter veil and the texture shows at full strength.
struct SeasonalFrostMaterial: View {
    @Environment(\.colorScheme) private var colorScheme

    /// The haze is part of the decor's material, like the colours baked
    /// into a rendered image — not a surface or text token.
    private static let darkHaze = Color(red: 0xCF / 255, green: 0xE2 / 255, blue: 0xF5 / 255).opacity(0.14)   // Bleu givré
    private static let lightHaze = Color(red: 1, green: 1, blue: 1).opacity(0.42)

    /// Bleu nuit, for the light mode's relief.
    private static let nightBlue = Color(red: 0x0B / 255, green: 0x1A / 255, blue: 0x2E / 255)

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            dark ? Self.darkHaze : Self.lightHaze
            if !dark {
                // White crystals vanish on a pale page: in light mode each one
                // casts a faint night-blue shadow a point below, so the frost
                // reads in RELIEF, like ice on a window against a bright sky.
                Image("SeasonFrost")
                    .resizable(resizingMode: .tile)
                    .colorMultiply(Self.nightBlue)
                    .opacity(0.28)
                    .offset(x: 0.8, y: 1.2)
            }
            Image("SeasonFrost")
                .resizable(resizingMode: .tile)
                .opacity(dark ? 0.6 : 1)
        }
    }
}

/// « Givre »'s light-mode ground: a winter sky behind the browsing screens —
/// a pale sun glowing in the top corner, the frost blue deepening toward the
/// bottom (never white where the rows sit: owner, « ne le laisse pas blanc »). Inside `SeasonalBackdrop`, behind everything;
/// the flat `surface` stays under it for every screen without a backdrop.
struct SeasonalWinterSky: View {
    // The sky's tones are steps of Bleu givré #CFE2F5 — decor colours, like
    // the frost's haze, not surface or text tokens.
    private static let top = Color(red: 0xD6 / 255, green: 0xE7 / 255, blue: 0xF8 / 255)
    private static let middle = Color(red: 0xC4 / 255, green: 0xDA / 255, blue: 0xF2 / 255)
    private static let bottom = Color(red: 0xAC / 255, green: 0xC8 / 255, blue: 0xE7 / 255)
    private static let sun = Color(red: 1, green: 1, blue: 1)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: Self.top, location: 0),
                        .init(color: Self.middle, location: 0.45),
                        .init(color: Self.bottom, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                RadialGradient(
                    colors: [Self.sun.opacity(0.45), Self.sun.opacity(0.14), Self.sun.opacity(0)],
                    center: UnitPoint(x: 0.82, y: 0.02),
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.55
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
