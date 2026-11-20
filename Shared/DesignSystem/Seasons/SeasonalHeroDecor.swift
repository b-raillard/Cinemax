import SwiftUI

/// A season's STILL decor on the top of a hero (Home, library): for
/// « Sapin de Noël », fir boughs in the two top corners with their glass balls
/// and micro lights. It belongs to the hero — it scrolls away with it and never
/// sits on a navigation bar. The images are rendered by `design/noel/decor.py`.
///
/// Nothing moves, so Reduce Motion keeps it; the « Animations d'ambiance »
/// switch removes it (`\.seasonalAmbianceEnabled`). Not interactive, hidden
/// from VoiceOver.
struct SeasonalHeroDecor: View {
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
                Image("SeasonFirRight")
                    .resizable()
                    .scaledToFit()
                    .frame(width: cornerWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The width of ONE corner image (its height follows: 260 × 230).
    private var cornerWidth: CGFloat {
        #if os(tvOS)
        1040
        #else
        sizeClass == .regular ? 380 : 260
        #endif
    }
}
