import SwiftUI

/// A season's STILL decor in the two top corners of the screen — for
/// « Sapin de Noël », fir boughs with their glass balls and micro lights.
/// Two places: OVER the content on the tab roots that have a hero (Home, the
/// libraries, as the last layer of their root stack: the boughs hang in front
/// of the hero, as the owner asked on device), and inside `SeasonalBackdrop`, BEHIND the
/// content, on every other browsing screen — where a bough in front would sit
/// on the back button. The images are rendered by `design/noel/decor.py`.
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
        if ambianceEnabled, SeasonalThemeCatalogue.theme(id: seasonID)?.decor == .firBoughs {
            ZStack {
                Image("SeasonFirLeft")
                    .resizable()
                    .scaledToFit()
                    .frame(width: cornerWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: -Self.outward)
                Image("SeasonFirRight")
                    .resizable()
                    .scaledToFit()
                    .frame(width: cornerWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: Self.outward)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// How far each corner is pushed off its edge, so the two boughs leave
    /// the middle of the navigation bar — the screen's title — free.
    #if os(tvOS)
    private static let outward: CGFloat = 0
    #else
    private static let outward: CGFloat = 0
    #endif

    /// The width of ONE corner image (its height follows: 260 × 230).
    private var cornerWidth: CGFloat {
        #if os(tvOS)
        800
        #else
        sizeClass == .regular ? 400 : 260
        #endif
    }
}

/// Garlands of coloured fairy lights strung across a browsing screen's
/// backdrop, BEHIND the content: they show in the gaps between the rows and
/// in the margins. One swag (`SeasonGarland`, rendered by
/// `design/noel/decor.py`) tiled across the width, at three heights.
struct SeasonalGarlands: View {
    @Environment(\.seasonID) private var seasonID
    @Environment(\.seasonalAmbianceEnabled) private var ambianceEnabled

    /// Where each garland hangs, as a fraction of the screen's height, and
    /// how far it is slid sideways (a fraction of one swag) so the three do
    /// not line up.
    private static let lines: [(y: CGFloat, shift: CGFloat)] = [(0.13, 0), (0.44, 0.5), (0.74, 0.25)]

    var body: some View {
        if ambianceEnabled, SeasonalThemeCatalogue.theme(id: seasonID)?.decor == .firBoughs {
            GeometryReader { geo in
                ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
                    Image("SeasonGarland")
                        .resizable(resizingMode: .tile)
                        .frame(width: geo.size.width + Self.swag, height: Self.height)
                        .offset(x: -Self.swag * line.shift, y: geo.size.height * line.y)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    #if os(tvOS)
    private static let swag: CGFloat = 800
    private static let height: CGFloat = 300
    #else
    private static let swag: CGFloat = 200
    private static let height: CGFloat = 75
    #endif
}
