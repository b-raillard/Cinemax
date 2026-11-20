import SwiftUI

/// A season's STILL decor in the two top corners of a browsing screen's
/// backdrop (`SeasonalBackdrop`) — where Halloween hangs its cobwebs: for
/// « Sapin de Noël », fir boughs with their glass balls and micro lights.
/// BEHIND the content, pinned to the very top of the screen: the page scrolls
/// over it, and it never sits on a button. The images are rendered by
/// `design/noel/decor.py`.
///
/// Nothing moves, so Reduce Motion keeps it; the « Animations d'ambiance »
/// switch removes it (`\.seasonalAmbianceEnabled`).
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
                Image("SeasonFirRight")
                    .resizable()
                    .scaledToFit()
                    .frame(width: cornerWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    /// The width of ONE corner image (its height follows: 260 × 230). Sized to
    /// the strip above the first content: status and navigation bar on iPhone
    /// and iPad, the tab bar's band on Apple TV.
    private var cornerWidth: CGFloat {
        #if os(tvOS)
        480
        #else
        sizeClass == .regular ? 240 : 150
        #endif
    }
}
