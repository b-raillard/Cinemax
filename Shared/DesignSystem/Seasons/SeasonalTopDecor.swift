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

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            dark ? Self.darkHaze : Self.lightHaze
            Image("SeasonFrost")
                .resizable(resizingMode: .tile)
                .opacity(dark ? 0.6 : 1)
        }
    }
}
