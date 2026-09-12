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

    @Test("Flux direct jamais ouvert : c'est le chien de garde d'ouverture qui décide")
    func neverOpenedIsIgnored() {
        // Le média n'a jamais produit de démuxeur : `noteMediaOpened()` n'a
        // pas été appelé. Traiter ça comme un arrêt inattendu doublerait la
        // reprise déjà pilotée par le chien de garde d'ouverture. Hors HLS
        // seulement : un manifeste jamais ouvert a sa propre issue (voir plus
        // bas).
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

    // MARK: - HLS jamais ouvert (#164 : RST HTTP/2 sur le manifeste)
    //
    // Un RST de l'origine sur le manifeste du transcodage forcé : libVLC ne
    // réessaie pas un manifeste, aucun démuxeur ne naît, et l'arrêt arrive en
    // `.stopped` propre, sans `.encounteredError`. La reprise attendait tout le
    // chien de garde d'ouverture (15 s, puis 30 s) sur un écran figé à 0:00.

    @Test("HLS jamais ouvert, hors fenêtre d'échange : échec d'ouverture, reprise immédiate")
    func neverOpenedHLSIsFailedOpen() {
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 2.3,
            currentMs: 0, lengthMs: 0, mediaConfirmedOpen: false,
            isAdaptiveStream: true
        )
        #expect(decision == .failedOpen)
    }

    @Test("HLS jamais ouvert, dans la fenêtre d'échange : on redemande une fois la fenêtre passée")
    func neverOpenedHLSInsideSwapWindowIsRechecked() {
        // Un RST rapide fait échouer l'ouverture en moins d'une seconde, là où
        // l'arrêt peut encore être celui du média qu'on remplace. Ignorer
        // renverrait au chien de garde (30 s pour la reprise) : on redemande.
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 0.4,
            currentMs: 0, lengthMs: 0, mediaConfirmedOpen: false,
            isAdaptiveStream: true
        )
        #expect(decision == .recheck(
            after: PlaybackEndPolicy.minPlayDuration - 0.4 + PlaybackEndPolicy.recheckMargin
        ))
    }

    @Test("La relecture tombe hors fenêtre : elle ne peut pas en programmer une troisième")
    func recheckLandsOutsideTheWindow() {
        // Ce que la relecture repasse à la politique : le délai écoulé depuis
        // le play() est au moins la fenêtre plus la marge.
        let elapsed = PlaybackEndPolicy.minPlayDuration + PlaybackEndPolicy.recheckMargin
        let stillStopped = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: elapsed,
            currentMs: 0, lengthMs: 0, mediaConfirmedOpen: false,
            isAdaptiveStream: true, engineStopped: true
        )
        #expect(stillStopped == .failedOpen)
    }

    @Test("Relecture pendant qu'un nouveau média s'ouvre : c'était un échange, rien à faire")
    func recheckWithEngineOpeningIsIgnored() {
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 1.25,
            currentMs: 0, lengthMs: 0, mediaConfirmedOpen: false,
            isAdaptiveStream: true, engineStopped: false
        )
        #expect(decision == .ignore)
    }

    @Test("Relecture après ouverture confirmée entre-temps : le moteur joue, pas d'arrêt inattendu")
    func recheckAfterOpenIsIgnored() {
        // Sans le garde `engineStopped`, un média ouvert entre-temps passerait
        // par la branche « arrêt inattendu » et relancerait une lecture saine.
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 1.25,
            currentMs: 1_200, lengthMs: runtime, mediaConfirmedOpen: true,
            isAdaptiveStream: true, engineStopped: false
        )
        #expect(decision == .ignore)
    }

    @Test("Aucun play() émis pour le nouveau média : l'arrêt est celui du média remplacé")
    func stopBeforeNewPlayIsIgnored() {
        // Le `.stopped` final d'une tentative ratée, après son
        // `.encounteredError` et une fois la reprise lancée : il ne doit pas
        // compter comme un second échec, sinon l'alerte tomberait par-dessus
        // la reprise et libérerait la session serveur qu'elle utilise.
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: nil,
            currentMs: 0, lengthMs: 0, mediaConfirmedOpen: false,
            isAdaptiveStream: true
        )
        #expect(decision == .ignore)
        // Même garde pour un média ouvert : pas de fin inventée pendant
        // l'échange d'épisode.
        #expect(PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: nil,
            currentMs: runtime, lengthMs: runtime, mediaConfirmedOpen: true
        ) == .ignore)
    }

    @Test("Démontage d'un HLS jamais ouvert : silence")
    func teardownOfNeverOpenedHLSIsIgnored() {
        let decision = PlaybackEndPolicy.decide(
            isTearingDown: true, secondsSincePlayStart: 5,
            currentMs: 0, lengthMs: 0, mediaConfirmedOpen: false,
            isAdaptiveStream: true
        )
        #expect(decision == .ignore)
    }

    @Test("HLS ouvert : les issues existantes ne changent pas")
    func openedHLSKeepsExistingOutcomes() {
        #expect(PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 440,
            currentMs: 1_438_478, lengthMs: runtime, mediaConfirmedOpen: true,
            isAdaptiveStream: true
        ) == .ended)
        #expect(PlaybackEndPolicy.decide(
            isTearingDown: false, secondsSincePlayStart: 228,
            currentMs: 600_000, lengthMs: runtime, mediaConfirmedOpen: true,
            isAdaptiveStream: true
        ) == .unexpectedStop)
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
