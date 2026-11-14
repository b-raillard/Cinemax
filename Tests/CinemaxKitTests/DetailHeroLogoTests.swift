import Testing
import CoreGraphics
import JellyfinAPI
@testable import Cinemax

/// Jellyfin lists a person once per credit, so someone who plays two roles —
/// or directs and acts — came twice with the same id. `ForEach` then rendered
/// one view for the duplicated identity: a hole in the cast row and a role
/// that changed from launch to launch (recette 2026-10-26, FIC-08-A2).
@Suite("Fiche cast cards")
struct CastCardTests {
    @Test("one card per person, actor credit first, roles joined, id-less credits dropped")
    func dedupes() {
        let people = [
            BaseItemPerson(id: "a", name: "Ana", role: "Rôle 1", type: .actor),
            BaseItemPerson(id: "b", name: "Ben", role: "Director", type: .director),
            BaseItemPerson(id: "a", name: "Ana", role: "Rôle 2", type: .actor),
            BaseItemPerson(id: nil, name: "Sans id", role: "X", type: .actor),
            BaseItemPerson(id: "", name: "Vide", role: "Y", type: .actor),
            BaseItemPerson(id: "b", name: "Ben", role: "Lui-même", type: .actor),
            BaseItemPerson(id: "a", name: "Ana", role: "Rôle 1", type: .actor),
        ]
        let cards = MediaDetailCastSection.cards(from: people)
        #expect(cards.map(\.id) == ["a", "b"])
        #expect(cards.map(\.role) == ["Rôle 1 / Rôle 2", "Lui-même"])
        #expect(cards.map(\.type) == [.actor, .actor])
    }

    @Test("the row keeps at most 20 people, counted after de-duplication")
    func capsAfterDedup() {
        let people = (0..<30).flatMap { index in
            [BaseItemPerson(id: "p\(index)", name: "P\(index)", role: "A", type: .actor),
             BaseItemPerson(id: "p\(index)", name: "P\(index)", role: "B", type: .actor)]
        }
        let cards = MediaDetailCastSection.cards(from: people)
        #expect(cards.count == 20)
        #expect(Set(cards.compactMap(\.id)).count == 20)
    }
}

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

/// The scroll-linked effects of the fiche hero and of the media rows: pure
/// math, so the views only read it (spec 2026-11-14, `parallaxe` / `rangee`).
@Suite("Scroll motion")
struct ScrollMotionTests {
    @Test("parallax, hero title fade, bar title and row edge recede")
    func scrollMotionMath() {
        // The backdrop moves down by 45 % of the upward scroll, never on overscroll.
        #expect(ScrollMotion.parallaxOffset(minY: -100) == 45)
        #expect(ScrollMotion.parallaxOffset(minY: 30) == 0)
        // The hero title fades over 90 pt of scroll.
        #expect(ScrollMotion.heroTitleOpacity(scrolled: 0) == 1)
        #expect(ScrollMotion.heroTitleOpacity(scrolled: 45) == 0.5)
        #expect(ScrollMotion.heroTitleOpacity(scrolled: 200) == 0)
        #expect(ScrollMotion.heroTitleOpacity(scrolled: -40) == 1)
        // The bar title appears once the hero has scrolled away.
        #expect(!ScrollMotion.showsBarTitle(scrolled: 300, heroHeight: 400))
        #expect(ScrollMotion.showsBarTitle(scrolled: 420, heroHeight: 400))
        // A row's edge card recedes: full size at rest, 0.9 / 0.55 at the edge.
        #expect(ScrollMotion.edgeRecede(phase: 0).scale == 1)
        #expect(ScrollMotion.edgeRecede(phase: 0).opacity == 1)
        #expect(abs(ScrollMotion.edgeRecede(phase: 1).scale - 0.9) < 0.0001)
        #expect(abs(ScrollMotion.edgeRecede(phase: 1).opacity - 0.55) < 0.0001)
        #expect(ScrollMotion.edgeRecede(phase: -1).scale == ScrollMotion.edgeRecede(phase: 1).scale)
    }
}
