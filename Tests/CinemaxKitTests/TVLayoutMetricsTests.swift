// tvOS-only: `CinemaTVLayout` and `CinemaTVFocus` exist only in the tvOS
// build, and the type multiplier below is an `#if os(tvOS)` branch — so these
// run in `CinemaxTVTests` alone. They are the proof that the tvOS bundle runs
// at all: a failure here fails CI while the iOS bundle stays green.
#if os(tvOS)
import Testing
import Foundation
import CoreGraphics
@testable import Cinemax

@Suite("tvOS layout metrics")
struct TVLayoutMetricsTests {

    @Test("the poster grid is the documented 6 columns × 32 pt gutter")
    func gridShape() {
        #expect(CinemaTVLayout.gridColumnCount == 6)
        #expect(CinemaTVLayout.gridGutter == 32)
        #expect(CinemaTVLayout.posterGridColumns.count == CinemaTVLayout.gridColumnCount)
    }

    @Test("a focused grid poster grows by less than half a gutter on each side")
    func focusGrowthNeverOverlapsNeighbours() {
        // The CLAUDE.md focus RULE: the 1.06 card growth never overlaps a
        // neighbour on the 6-column grid. Both cards of a gutter grow towards
        // it, so each side may take at most half of it.
        let canvasWidth: CGFloat = 1920
        let columns = CGFloat(CinemaTVLayout.gridColumnCount)
        let cardWidth = (canvasWidth
            - 2 * CinemaTVLayout.pagePadding
            - (columns - 1) * CinemaTVLayout.gridGutter) / columns
        let growthPerSide = cardWidth * (CinemaTVFocus.cardScale - 1) / 2
        #expect(growthPerSide < CinemaTVLayout.gridGutter / 2)
    }

    @Test("rows and chips accuse focus with one stroke, never a ghost")
    func rowFocusIsOpaque() {
        #expect(CinemaTVFocus.strokeOpacity == 1)
        #expect(CinemaTVFocus.strokeWidth > 0)
        #expect(CinemaTVFocus.cardRingWidth >= CinemaTVFocus.strokeWidth)
    }

    @MainActor
    @Test("type is scaled 1.4× on top of the user's size setting")
    func typeScaleCarriesTheTVMultiplier() {
        CinemaScale.invalidateFactorCache()
        let stored = UserDefaults.standard.object(forKey: SettingsKey.uiScale) as? Double
            ?? SettingsKey.Default.uiScale
        #expect(abs(CinemaScale.factor - CGFloat(stored) * 1.4) < 0.000_1)
    }
}
#endif
