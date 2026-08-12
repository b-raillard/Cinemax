import Testing
import Foundation
@testable import Cinemax

/// Verrouille les deux défauts trouvés en recette adversariale sur le menu
/// contextuel des vignettes (D5 et D6).
///
/// D5 — l'étiquette « vu » était dérivée de l'override optimiste tandis que le
/// groupe « lecture » repartait de l'instantané brut : après « Marquer comme
/// vu » dans ce même menu, « Reprendre » restait proposé et ouvrait réellement
/// le film en cours de route.
///
/// D6 — l'override ne s'annulait que si l'instantané de la carte changeait. Sur
/// Recherche, qui n'observe aucune notification de rafraîchissement, il ne
/// s'annulait donc jamais : après lecture puis arrêt (le serveur repasse l'item
/// en non-lu), la valeur serveur redevient égale à `base` et même une nouvelle
/// recherche ne l'aurait pas purgé.
@Suite("Menu contextuel — état optimiste")
struct CardMenuOptimisticStateTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - D5 : le groupe « lecture » doit suivre l'override

    @Test("Marquer comme vu dans le menu retire la reprise")
    func playedOverrideSuppressesResume() {
        // L'instantané dit : position résiduelle, non lu → reprise légitime.
        // L'utilisateur vient de taper « Marquer comme vu » dans ce menu.
        let override = OptimisticFlag(base: false, value: true, setAt: t0)

        let resumable = CardPlayTargetResolver.isResumable(
            positionTicks: 6_000_000_000,
            isPlayed: false,
            playedOverride: override,
            now: t0.addingTimeInterval(1)
        )

        #expect(resumable == false)
    }

    @Test("Marquer comme non vu dans le menu rétablit la reprise")
    func unplayedOverrideRestoresResume() {
        // L'instantané dit : lu (donc pas de reprise). L'utilisateur vient de
        // taper « Marquer comme non vu ».
        let override = OptimisticFlag(base: true, value: false, setAt: t0)

        let resumable = CardPlayTargetResolver.isResumable(
            positionTicks: 6_000_000_000,
            isPlayed: true,
            playedOverride: override,
            now: t0.addingTimeInterval(1)
        )

        #expect(resumable == true)
    }

    @Test("Sans override, la règle d'origine est inchangée")
    func noOverrideKeepsBaseRule() {
        #expect(CardPlayTargetResolver.isResumable(
            positionTicks: 6_000_000_000, isPlayed: false,
            playedOverride: nil, now: t0
        ) == true)

        // Le cœur de la règle SSOT : une position résiduelle sur un item lu
        // n'est pas une reprise.
        #expect(CardPlayTargetResolver.isResumable(
            positionTicks: 6_000_000_000, isPlayed: true,
            playedOverride: nil, now: t0
        ) == false)

        #expect(CardPlayTargetResolver.isResumable(
            positionTicks: 0, isPlayed: false,
            playedOverride: nil, now: t0
        ) == false)
    }

    // MARK: - D6 : l'override doit s'éteindre tout seul

    @Test("Un override périmé rend la main à la vérité serveur")
    func staleOverrideExpires() {
        let override = OptimisticFlag(base: false, value: true, setAt: t0)
        let wellAfter = t0.addingTimeInterval(OptimisticFlag.lifetime + 1)

        // C'est exactement le cas Recherche : la valeur serveur est revenue à
        // `base`, donc l'ancien test `base == serverValue` gardait l'override
        // pour toujours. Seule l'expiration peut le purger.
        #expect(override.resolved(against: false, now: wellAfter) == nil)
    }

    @Test("Un override frais reste appliqué")
    func freshOverrideApplies() {
        let override = OptimisticFlag(base: false, value: true, setAt: t0)
        #expect(override.resolved(against: false, now: t0.addingTimeInterval(1)) == true)
    }

    @Test("Un override dont la base a bougé rend la main immédiatement")
    func supersededOverrideDiscarded() {
        // Comportement d'origine, préservé : des données fraîches contredisent
        // l'instantané dont l'override est dérivé → la vérité serveur gagne
        // sans attendre l'expiration.
        let override = OptimisticFlag(base: false, value: true, setAt: t0)
        #expect(override.resolved(against: true, now: t0.addingTimeInterval(1)) == nil)
    }
}
