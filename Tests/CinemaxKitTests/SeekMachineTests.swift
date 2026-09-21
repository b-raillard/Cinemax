import Testing
import Foundation
@testable import Cinemax

/// Verrouille `SeekMachine`, l'état de recherche extrait de
/// `VLCStreamViewController` (#193) : cible en attente, validation groupée des
/// sauts ±N, fenêtre de stabilisation et entonnoir `engineSeek`.
///
/// Rien de tout cela n'était testable tant que l'état vivait dans le
/// contrôleur — seules les deux briques pures (`SeekCoalescer`,
/// `SeekSettleTracker`) l'étaient. Ici le moteur est simulé par trois
/// variables, l'horloge est injectée et les minuteries sont capturées au lieu
/// d'être posées sur la file principale : chaque test les déclenche à la main.
@MainActor
@Suite("Seek — machine d'état du lecteur")
struct SeekMachineTests {

    /// Le moteur, l'horloge et les minuteries d'un banc d'essai.
    @MainActor
    final class Bench {
        var position: Int32 = 0
        var length: Int32 = 3_600_000
        var state: SeekMachine.EngineState = .playing
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []

        var engineSeeks: [Int32] = []
        var userSeeks: [Int32] = []
        var paints: [Int32] = []
        var spinnerShown = 0
        var settledReports: [Bool] = []

        lazy var machine: SeekMachine = {
            let machine = SeekMachine(
                currentMs: { [unowned self] in position },
                lengthMs: { [unowned self] in length },
                engineState: { [unowned self] in state },
                now: { [unowned self] in clock },
                schedule: { [unowned self] delay, work in scheduled.append((delay, work)) }
            )
            machine.performSeek = { [unowned self] in engineSeeks.append($0) }
            machine.commitUserSeek = { [unowned self] in userSeeks.append($0) }
            machine.paint = { [unowned self] ms, _ in paints.append(ms) }
            machine.showSpinner = { [unowned self] in spinnerShown += 1 }
            machine.onSettled = { [unowned self] in settledReports.append($0) }
            return machine
        }()

        /// Runs every timer that is due within `delay` and still armed —
        /// what the main queue would do.
        func fire(upTo delay: TimeInterval) {
            let due = scheduled.filter { $0.delay <= delay }
            scheduled.removeAll { $0.delay <= delay }
            for item in due where !item.work.isCancelled { item.work.perform() }
        }

        var armedTimers: Int { scheduled.filter { !$0.work.isCancelled }.count }
    }

    // MARK: - Sauts groupés

    @Test("Trois sauts rapprochés font UNE recherche, à la somme exacte")
    func burstCommitsOnce() {
        let bench = Bench()
        bench.position = 5_000
        bench.machine.skip(bySeconds: 10)
        bench.machine.skip(bySeconds: 10)
        bench.machine.skip(bySeconds: 10)

        // Le HUD suit chaque appui, la cible s'accumule depuis la précédente.
        #expect(bench.paints == [15_000, 25_000, 35_000])
        #expect(bench.machine.pendingTargetMs == 35_000)
        #expect(bench.userSeeks.isEmpty)
        // Chaque appui réarme le délai : seule la dernière minuterie vit.
        #expect(bench.armedTimers == 1)

        bench.fire(upTo: SeekMachine.commitDelay)
        #expect(bench.userSeeks == [35_000])
        // La cible reste tenue jusqu'à ce que le moteur l'atteigne.
        #expect(bench.machine.pendingTargetMs == 35_000)
    }

    @Test("Un saut ne dépasse jamais la marge de fin")
    func skipClampsBeforeTheEnd() {
        let bench = Bench()
        bench.length = 60_000
        bench.position = 55_000
        bench.machine.skip(bySeconds: 10)
        #expect(bench.machine.pendingTargetMs == 60_000 - SeekCoalescer.endGuardMs)
    }

    @Test("Annuler supprime la cible, la validation et la fenêtre en cours")
    func cancelDropsEverything() {
        let bench = Bench()
        bench.machine.skip(bySeconds: 10)
        bench.machine.engineSeek(1_000)
        #expect(bench.machine.isSettling)

        bench.machine.cancelPending()
        #expect(bench.machine.pendingTargetMs == nil)
        #expect(!bench.machine.isSettling)
        bench.fire(upTo: 60)
        #expect(bench.userSeeks.isEmpty)
        #expect(bench.spinnerShown == 0)
    }

    @Test("La position affichée tient la cible jusqu'à ce que le moteur l'atteigne")
    func displayHoldsTheTarget() {
        let bench = Bench()
        bench.position = 10_000
        bench.machine.hold(at: 70_000)

        #expect(bench.machine.displayPosition() == 70_000)
        bench.position = 68_000 // encore à 2 s : la cible tient
        #expect(bench.machine.displayPosition() == 70_000)
        bench.position = 69_000 // à 1 s : atteinte, on relâche
        #expect(bench.machine.displayPosition() == 69_000)
        #expect(bench.machine.pendingTargetMs == nil)
    }

    // MARK: - Entonnoir

    @Test("L'entonnoir borne une recherche sur la fin exacte (défaut H)")
    func funnelClampsTheExactEnd() {
        // Mesuré le 2026-08-21 : `target=2503936` pour `lengthMs=2503936`.
        // libVLC refuse cette cible et l'entrée ne s'en remet jamais.
        let bench = Bench()
        bench.length = 2_503_936
        bench.machine.engineSeek(2_503_936)
        #expect(bench.engineSeeks == [2_503_936 - SeekCoalescer.endGuardMs])
    }

    @Test("L'entonnoir ouvre la fenêtre de stabilisation")
    func funnelArmsTheSettleWindow() {
        let bench = Bench()
        bench.machine.engineSeek(90_000)
        #expect(bench.machine.isSettling)
        #expect(bench.scheduled.contains { $0.delay == SeekMachine.spinnerDelay })
    }

    // MARK: - Fenêtre de stabilisation

    @Test("Une recherche qui repart tout de suite n'affiche jamais le loader")
    func instantLandingNeverFlashesTheSpinner() {
        let bench = Bench()
        bench.position = 90_000
        bench.machine.engineSeek(90_000)
        #expect(bench.machine.sampleSettle()) // première mesure : la référence
        bench.position = 90_200
        #expect(!bench.machine.sampleSettle()) // 200 ms de progression : posé
        #expect(bench.settledReports == [true])

        bench.fire(upTo: SeekMachine.spinnerDelay)
        #expect(bench.spinnerShown == 0)
    }

    @Test("Une recherche qui fait attendre affiche le loader passé le délai")
    func slowLandingShowsTheSpinner() {
        let bench = Bench()
        bench.position = 90_000
        bench.machine.engineSeek(90_000)
        bench.fire(upTo: SeekMachine.spinnerDelay)
        #expect(bench.spinnerShown == 1)
        #expect(bench.machine.isSettling)
    }

    @Test("En chargement, deux progressions d'affilée sont exigées")
    func bufferingDemandsSustainedProgress() {
        let bench = Bench()
        bench.state = .buffering
        bench.position = 90_000
        bench.machine.engineSeek(90_000)
        bench.machine.sampleSettle() // référence
        bench.position = 90_150
        #expect(bench.machine.sampleSettle()) // un saut seul ne suffit pas
        bench.position = 90_300
        #expect(!bench.machine.sampleSettle())
        #expect(bench.settledReports == [false])
    }

    @Test("En pause, la recherche est posée d'emblée")
    func pausedLandsAtOnce() {
        let bench = Bench()
        bench.state = .paused
        bench.machine.engineSeek(90_000)
        #expect(!bench.machine.sampleSettle())
        #expect(!bench.machine.isSettling)
        #expect(bench.settledReports == [false])
    }

    @Test("Le garde-fou referme la fenêtre après 30 s sans progression")
    func backstopReleasesTheWindow() {
        let bench = Bench()
        bench.position = 90_000
        bench.machine.engineSeek(90_000)
        bench.machine.sampleSettle()
        bench.clock += SeekMachine.maxHold - 1
        #expect(bench.machine.sampleSettle())
        bench.clock += 2
        #expect(!bench.machine.sampleSettle())
        // Un groupe bloqué en `Waiting` vaut moins qu'un rapport tardif.
        #expect(bench.settledReports == [true])
    }

    @Test("Hors fenêtre, un échantillon ne fait rien")
    func samplingWithoutAWindowIsInert() {
        let bench = Bench()
        #expect(!bench.machine.sampleSettle())
        #expect(bench.settledReports.isEmpty)
    }
}
