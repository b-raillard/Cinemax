import Testing
import Foundation
@testable import Cinemax

/// Verrouille D2, trouvé en recette adversariale.
///
/// libVLC 4.0 n'a pas d'état `.ended` distinct : démontage, changement de
/// média, vraie fin de lecture et mort du flux amont arrivent tous en
/// `.stopped`. Le présentateur répondait par un unique `guard … else { return }`
/// qui confondait ces quatre cas — dont un est un défaut : quand le flux meurt
/// en cours de film, libVLC signale un EOF propre, le test de fin échoue, et
/// **rien** ne s'exécute. Écran noir, aucune alerte, aucune reprise, pas même
/// le loader. 95 s de silence mesurées en recette.
///
/// La trace de fin d'épisode capturée le 2026-08-12 confirme l'autre moitié :
/// à la fin naturelle, `currentMs=1438478` contre `lengthMs=1438656`, soit
/// 178 ms d'écart — la tolérance de 2 s est largement suffisante et ne doit
/// pas être resserrée.
@Suite("Fin de lecture — décision")
struct PlaybackEndDecisionTests {

    private let runtime: Int64 = 1_438_656 // épisode réel de la trace

    // MARK: - Vraie fin

    @Test("Fin naturelle : la lecture est terminée")
    func naturalEndIsEnded() {
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 440.92,
            currentMs: 1_438_478, lengthMs: runtime, mediaConfirmedOpen: true
        )
        #expect(decision == .ended)
    }

    @Test("Juste dans la tolérance de fin")
    func justInsideToleranceIsEnded() {
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 60,
            currentMs: runtime - PlaybackEndPolicy.endToleranceMs,
            lengthMs: runtime, mediaConfirmedOpen: true
        )
        #expect(decision == .ended)
    }

    // MARK: - Le défaut : arrêt prématuré

    @Test("Mort du flux en cours de film : arrêt inattendu, pas un no-op")
    func prematureStopOnOpenedMediaIsUnexpected() {
        // Les valeurs exactes de la recette : arrêt à 41 min de la fin.
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 228.23,
            currentMs: 4_620_782, lengthMs: 7_070_439, mediaConfirmedOpen: true
        )
        #expect(decision == .unexpectedStop)
    }

    @Test("Arrêt prématuré juste hors tolérance")
    func justOutsideToleranceIsUnexpected() {
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 60,
            currentMs: runtime - PlaybackEndPolicy.endToleranceMs - 1,
            lengthMs: runtime, mediaConfirmedOpen: true
        )
        #expect(decision == .unexpectedStop)
    }

    // MARK: - Ce qui doit rester silencieux

    @Test("Démontage : rien à faire")
    func teardownIsIgnored() {
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: true, secondsSincePlayStart: 300,
            currentMs: 1_000, lengthMs: runtime, mediaConfirmedOpen: true
        )
        #expect(decision == .ignore)
    }

    @Test("Changement de média : trop tôt pour être une fin")
    func mediaSwapIsIgnored() {
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 0.4,
            currentMs: 0, lengthMs: runtime, mediaConfirmedOpen: true
        )
        #expect(decision == .ignore)
    }

    @Test("Flux jamais ouvert : c'est le chien de garde d'ouverture qui décide")
    func neverOpenedIsIgnored() {
        // Le média n'a jamais produit de démuxeur : `noteMediaOpened()` n'a
        // pas été appelé. Traiter ça comme un arrêt inattendu doublerait la
        // reprise déjà pilotée par le chien de garde d'ouverture.
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 30,
            currentMs: 0, lengthMs: 0, mediaConfirmedOpen: false
        )
        #expect(decision == .ignore)
    }

    @Test("Longueur inconnue sur un média pourtant ouvert : on n'invente rien")
    func unknownLengthIsIgnored() {
        // `lengthMs == 0` veut dire qu'on ne sait pas où est la fin : on ne
        // peut donc pas qualifier l'arrêt de prématuré.
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 30,
            currentMs: 500_000, lengthMs: 0, mediaConfirmedOpen: true
        )
        #expect(decision == .ignore)
    }
}

/// Verrouille la carte « Épisode suivant dans N s ».
///
/// La carte compte à rebours jusqu'à la FIN DU MÉDIA — c'est là que
/// l'enchaînement se déclenche — et le segment « générique » ne dit que quand
/// commencer à l'afficher. Les deux divergent dès que le segment est faux, et
/// un générique détecté par le plugin s'est ouvert 13 minutes avant la fin :
/// « Épisode suivant dans 788 s » à l'écran, mesuré sur Apple TV le
/// 2026-09-04. Un compte qu'on ne peut pas lire comme un compte à rebours est
/// une nuisance, et 788 s n'est le générique d'aucune série.
///
/// Vit dans ce fichier faute de pouvoir en ajouter un depuis une session
/// distante (le `project.pbxproj` généré par XcodeGen ne peut pas y être
/// régénéré — voir la RULE « Adding a new file under `Shared/` »).
@Suite("Carte épisode suivant — admission")
struct NextUpCountdownPolicyTests {

    @Test("Un épisode : la carte n'apparaît qu'à moins de deux minutes de la fin")
    func episodeCardIsBoundedToTheLastTwoMinutes() {
        #expect(NextUpCountdownPolicy.episodeMaxSeconds == 120)
        #expect(NextUpCountdownPolicy.shouldShowCard(secondsRemaining: 45, isEpisode: true))
        #expect(NextUpCountdownPolicy.shouldShowCard(secondsRemaining: 120, isEpisode: true))
        #expect(!NextUpCountdownPolicy.shouldShowCard(secondsRemaining: 121, isEpisode: true))
    }

    @Test("Le cas mesuré : 788 s restantes sur un épisode, pas de carte")
    func theMeasuredDefectIsRefused() {
        #expect(!NextUpCountdownPolicy.shouldShowCard(secondsRemaining: 788, isEpisode: true))
    }

    @Test("Un film enchaîné depuis une collection : son générique peut durer dix minutes")
    func aFilmKeepsTheFullCredits() {
        #expect(NextUpCountdownPolicy.shouldShowCard(secondsRemaining: 788, isEpisode: false))
        #expect(NextUpCountdownPolicy.shouldShowCard(secondsRemaining: 45, isEpisode: false))
    }

    @Test("Plus rien à compter : la fin appartient au gestionnaire de fin")
    func nothingLeftToCountShowsNoCard() {
        #expect(!NextUpCountdownPolicy.shouldShowCard(secondsRemaining: 0, isEpisode: true))
        #expect(!NextUpCountdownPolicy.shouldShowCard(secondsRemaining: -3, isEpisode: false))
    }
}
