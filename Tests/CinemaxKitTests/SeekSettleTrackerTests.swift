import Testing
import Foundation
@testable import Cinemax

/// Verrouille le défaut de la fenêtre de stabilisation d'un seek, mesuré sur
/// appareil le 2026-08-12.
///
/// Après un seek, la lecture repart **immédiatement** (relevé : position à
/// 1 413 175 ms à `since=0.19`, puis progression de ~460 ms de média par
/// ~460 ms de temps réel, soit 1× dès la première demi-seconde). Pourtant
/// `moved` valait `false` à chaque échantillon, `landed` n'est jamais devenu
/// vrai, et le loader est resté affiché jusqu'au garde-fou — 20,2 s la première
/// fois, 30,0 s la seconde. Avec la barre de progression figée sur la cible du
/// scrub, cela se lit exactement comme « le lecteur a gelé 20 s après une
/// avance rapide ».
///
/// Cause : la référence était réécrite à **chaque** appel. `onEngineTimeChanged`
/// suit le rythme des mises à jour de libVLC (plusieurs par 100 ms), donc
/// l'écart entre deux appels consécutifs valait 0 à 30 ms — toujours sous le
/// seuil de 120 ms. Le test de progression dépendait de la fréquence d'appel :
/// plus on l'appelait, moins il pouvait réussir.
@Suite("Seek — fenêtre de stabilisation")
struct SeekSettleTrackerTests {

    private let threshold: Int32 = 120

    @Test("Des échantillons rapprochés finissent par constater la progression")
    func frequentSamplesStillDetectProgress() {
        // Le cas réel : ~40 appels dans l'intervalle où le média avance de
        // 460 ms. Chaque appel isolé est sous le seuil.
        var tracker = SeekSettleTracker()
        var position: Int32 = 1_413_175
        var sawMoved = false

        for _ in 0..<40 {
            position += 12 // ~12 ms de média entre deux rappels de libVLC
            if tracker.noteProgress(positionMs: position, thresholdMs: threshold) {
                sawMoved = true
            }
        }

        #expect(sawMoved, "40 échantillons couvrant 480 ms doivent constater la progression")
    }

    @Test("Le premier échantillon ne peut pas constater de progression")
    func firstSampleIsNeverMoved() {
        var tracker = SeekSettleTracker()
        // `#expect` ne peut pas appeler une méthode `mutating` en ligne.
        let first = tracker.noteProgress(positionMs: 1_000, thresholdMs: threshold)
        #expect(first == false)
    }

    @Test("Une position immobile ne constate jamais de progression")
    func stalledPositionNeverMoves() {
        var tracker = SeekSettleTracker()
        _ = tracker.noteProgress(positionMs: 5_000, thresholdMs: threshold)
        var everMoved = false
        for _ in 0..<50 where tracker.noteProgress(positionMs: 5_000, thresholdMs: threshold) {
            everMoved = true
        }
        #expect(everMoved == false)
    }

    @Test("Un saut franc constate la progression immédiatement")
    func largeJumpMovesAtOnce() {
        var tracker = SeekSettleTracker()
        _ = tracker.noteProgress(positionMs: 1_000, thresholdMs: threshold)
        let jumped = tracker.noteProgress(positionMs: 1_500, thresholdMs: threshold)
        #expect(jumped)
    }

    @Test("Un retour en arrière rebase au lieu de compter une progression")
    func backwardJumpRebases() {
        var tracker = SeekSettleTracker()
        _ = tracker.noteProgress(positionMs: 500_000, thresholdMs: threshold)
        // Nouveau seek vers l'arrière : ce n'est pas une progression.
        let backward = tracker.noteProgress(positionMs: 10_000, thresholdMs: threshold)
        #expect(backward == false)
        // …et la nouvelle référence est bien la position d'arrivée.
        let forwardAfter = tracker.noteProgress(positionMs: 10_200, thresholdMs: threshold)
        #expect(forwardAfter)
    }

    @Test("La remise à zéro oublie la référence")
    func resetClearsBaseline() {
        var tracker = SeekSettleTracker()
        _ = tracker.noteProgress(positionMs: 1_000, thresholdMs: threshold)
        tracker.reset()
        let afterReset = tracker.noteProgress(positionMs: 1_500, thresholdMs: threshold)
        #expect(afterReset == false)
    }
}
