import Testing
import CoreGraphics
@testable import Cinemax

/// Locks when the iOS fiche swaps its text title for the work's logo (#180),
/// and how tall that logo may be. The swap is keyed on the MEASURED hero width,
/// not the size class, because an iPhone in landscape is still `.compact`.
@Suite("Detail hero logo sizing")
struct DetailHeroLogoTests {

    @Test("iPhone portrait keeps the text title")
    func narrowHeroHasNoLogo() {
        #expect(AdaptiveLayout.detailLogoHeight(forHero: CGSize(width: 402, height: 310)) == nil)
    }

    @Test("the width threshold is inclusive")
    func thresholdIsInclusive() {
        #expect(AdaptiveLayout.detailLogoHeight(forHero: CGSize(width: 599.5, height: 460)) == nil)
        #expect(AdaptiveLayout.detailLogoHeight(forHero: CGSize(width: 600, height: 460)) == 96)
    }

    @Test("an iPad hero gets the full 0.6 × tvOS height")
    func iPadGetsFullHeight() {
        #expect(AdaptiveLayout.detailLogoHeight(forHero: CGSize(width: 820, height: 460)) == 96)
    }

    @Test("a clamped landscape hero shrinks the logo instead of clipping the badges")
    func shortHeroCapsTheLogo() {
        // iPhone in landscape: the hero clamps to ~200 pt of a short viewport.
        let height = AdaptiveLayout.detailLogoHeight(forHero: CGSize(width: 874, height: 200))
        #expect(height.map { abs($0 - 60) < 0.001 } == true)
    }
}
