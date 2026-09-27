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
        var strandedTargets: [Int32] = []
        var landedTargets: [Int32] = []
        /// Ce que répond le contrôleur : une reconstruction a-t-elle pris le relais ?
        var recoveryTakesOver = true

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
            machine.onStranded = { [unowned self] in
                strandedTargets.append($0)
                return recoveryTakesOver
            }
            machine.onLanded = { [unowned self] in landedTargets.append($0) }
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

    // MARK: - Recherche bloquée (filet)

    /// Une recherche de l'utilisateur tirée à 90 s, puis 31 s sans que la tête
    /// de lecture bouge — la forme du refus mesuré le 21/08.
    private func strand(_ bench: Bench, byUser: Bool, state: SeekMachine.EngineState = .playing) -> Bool {
        bench.state = state
        bench.position = 90_000
        bench.machine.engineSeek(90_000, byUser: byUser)
        bench.machine.sampleSettle() // référence
        bench.clock += SeekMachine.maxHold + 1
        return bench.machine.sampleSettle()
    }

    @Test("Une recherche de l'utilisateur jamais posée est signalée une fois, avec sa cible")
    func strandedUserSeekIsReported() {
        let bench = Bench()
        let spinnerStays = strand(bench, byUser: true)
        #expect(bench.strandedTargets == [90_000])
        // La reconstruction a pris le relais : le loader reste, la fenêtre est close.
        #expect(spinnerStays)
        #expect(!bench.machine.isSettling)
        // Le groupe est prévenu comme avant, et une seule fois.
        #expect(bench.settledReports == [true])
        #expect(!bench.machine.sampleSettle())
        #expect(bench.strandedTargets == [90_000])
    }

    @Test("Le moteur resté en chargement est signalé aussi — le cas que rien ne rattrapait")
    func strandedWhileBufferingIsReported() {
        let bench = Bench()
        _ = strand(bench, byUser: true, state: .buffering)
        #expect(bench.strandedTargets == [90_000])
    }

    @Test("Sans reconstruction possible, le loader s'éteint comme avant")
    func declinedRecoveryReleasesTheSpinner() {
        let bench = Bench()
        bench.recoveryTakesOver = false
        #expect(!strand(bench, byUser: true))
        #expect(bench.strandedTargets == [90_000])
    }

    @Test("Une recherche de l'app (reprise, recalage, piste, écho) ne déclenche jamais le filet")
    func appSeekIsNeverReported() {
        let bench = Bench()
        #expect(!strand(bench, byUser: false))
        #expect(bench.strandedTargets.isEmpty)
        #expect(bench.settledReports == [true])
    }

    @Test("Une recherche de l'utilisateur qui se pose n'est pas signalée")
    func landedUserSeekIsNotReported() {
        let bench = Bench()
        bench.position = 90_000
        bench.machine.engineSeek(90_000, byUser: true)
        bench.machine.sampleSettle()
        bench.position = 90_200
        #expect(!bench.machine.sampleSettle())
        bench.clock += SeekMachine.maxHold + 1
        #expect(!bench.machine.sampleSettle())
        #expect(bench.strandedTargets.isEmpty)
    }

    @Test("En pause, une recherche de l'utilisateur est posée, jamais bloquée")
    func pausedUserSeekIsNotReported() {
        let bench = Bench()
        bench.state = .paused
        bench.machine.engineSeek(90_000, byUser: true)
        #expect(!bench.machine.sampleSettle())
        bench.clock += SeekMachine.maxHold + 1
        #expect(!bench.machine.sampleSettle())
        #expect(bench.strandedTargets.isEmpty)
    }

    @Test("Une recherche de l'utilisateur remplacée ne laisse pas son drapeau à la suivante")
    func userFlagDoesNotLeakToTheNextSeek() {
        let bench = Bench()
        bench.machine.engineSeek(90_000, byUser: true)
        bench.machine.cancelPending()
        // La reprise de l'app qui suit se bloque : ce n'est pas au filet d'agir.
        #expect(!strand(bench, byUser: false))
        #expect(bench.strandedTargets.isEmpty)
    }

    @Test("La cible signalée est la cible bornée, pas la fin exacte")
    func strandedTargetIsTheClampedOne() {
        let bench = Bench()
        bench.length = 2_503_936
        bench.position = 1_000_000
        bench.machine.engineSeek(2_503_936, byUser: true)
        bench.machine.sampleSettle()
        bench.clock += SeekMachine.maxHold + 1
        bench.machine.sampleSettle()
        #expect(bench.strandedTargets == [2_503_936 - SeekCoalescer.endGuardMs])
    }

    // MARK: - Recherche posée : la position réelle suit

    @Test("Une recherche posée donne sa cible, là où le moteur est désormais")
    func landedSeekReportsItsTarget() {
        let bench = Bench()
        bench.position = 90_000
        bench.machine.engineSeek(90_000)
        bench.machine.sampleSettle()
        bench.position = 90_200
        #expect(!bench.machine.sampleSettle())
        #expect(bench.landedTargets == [90_000])
    }

    @Test("En pause — aucun tick à venir — la recherche posée donne aussi sa cible")
    func pausedLandingReportsItsTarget() {
        // Le trou relevé par la relecture : un retour en arrière en pause depuis
        // les 2 dernières secondes laissait l'ancienne position près de la fin,
        // et un arrêt avant le tick suivant se lisait comme la fin.
        let bench = Bench()
        bench.state = .paused
        bench.length = 2_503_936
        bench.machine.engineSeek(600_000, byUser: true)
        #expect(!bench.machine.sampleSettle())
        #expect(bench.landedTargets == [600_000])
    }

    @Test("Le garde-fou n'est pas un atterrissage")
    func backstopIsNotALanding() {
        let bench = Bench()
        _ = strand(bench, byUser: true)
        _ = strand(bench, byUser: false)
        #expect(bench.landedTargets.isEmpty)
    }

    @Test("Une recherche remplacée ne se pose jamais")
    func supersededSeekNeverLands() {
        let bench = Bench()
        bench.machine.engineSeek(90_000)
        bench.machine.cancelPending()
        bench.position = 95_000
        #expect(!bench.machine.sampleSettle())
        #expect(bench.landedTargets.isEmpty)
    }

    @Test("Une pause pendant le calage est un atterrissage, sans rapport de calage")
    func pauseDuringSettleLands() {
        let bench = Bench()
        bench.machine.engineSeek(90_000, byUser: true)
        bench.machine.endSettleInPause()
        #expect(bench.landedTargets == [90_000])
        #expect(bench.settledReports.isEmpty)
        #expect(bench.machine.settlingTargetMs == nil)
    }

    @Test("Une pause hors fenêtre n'annonce aucun atterrissage")
    func pauseWithoutAWindowLandsNothing() {
        let bench = Bench()
        bench.machine.endSettleInPause()
        #expect(bench.landedTargets.isEmpty)
    }

    @Test("Hors fenêtre, un échantillon ne fait rien")
    func samplingWithoutAWindowIsInert() {
        let bench = Bench()
        #expect(!bench.machine.sampleSettle())
        #expect(bench.settledReports.isEmpty)
    }
}
