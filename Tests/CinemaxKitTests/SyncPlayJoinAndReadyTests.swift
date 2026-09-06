import Foundation
import os
import Testing
@testable import Cinemax
@testable import CinemaxKit

// MARK: - D2 — where a joiner opens

/// The position a participant opens at when a Watch Together queue names an
/// item. Measured on device 2026-09-06: the joiner opened at **its own** resume
/// (12:33) while the group carried 3:39, and nothing ever corrected the 9-minute
/// gap — the two people watched different parts of the film with no signal.
@Suite("SyncPlayJoinStart — la position du groupe fait autorité")
struct SyncPlayJoinStartTests {

    @Test("Une demande hors groupe garde la reprise locale")
    func nonGroupRequestKeepsLocalResume() {
        #expect(SyncPlayJoinStart.startSeconds(groupStartTicks: nil, localResumeSeconds: 409.2) == 409.2)
        #expect(SyncPlayJoinStart.startSeconds(groupStartTicks: nil, localResumeSeconds: nil) == nil)
    }

    @Test("La position du groupe l'emporte sur la reprise locale")
    func groupPositionWinsOverLocalResume() {
        // 3:39 en ticks Jellyfin (10 000 ticks par milliseconde).
        let groupTicks = 2_191_333_835
        let start = SyncPlayJoinStart.startSeconds(groupStartTicks: groupTicks, localResumeSeconds: 753.4)
        #expect(start != nil)
        #expect(abs(start! - 219.13) < 0.01)
    }

    /// Le cœur du défaut : un groupe qui commence au début porte la position 0,
    /// et 0 doit battre une reprise locale de 12:33. Traiter 0 comme « pas de
    /// position » est exactement ce qui laissait le joignant sur son générique
    /// de fin.
    @Test("Un groupe à 0 l'emporte AUSSI — c'est le cas qui a produit le défaut")
    func groupAtZeroStillWins() {
        #expect(SyncPlayJoinStart.startSeconds(groupStartTicks: 0, localResumeSeconds: 753.4) == nil)
    }

    @Test("Une position négative est traitée comme le début")
    func negativeTicksAreTreatedAsStart() {
        #expect(SyncPlayJoinStart.startSeconds(groupStartTicks: -5, localResumeSeconds: 753.4) == nil)
    }

    /// L'hôte qui OUVRE une séance sur un film entamé : la file du groupe part
    /// de sa reprise, pas de zéro. Partir de zéro écrasait définitivement son
    /// point de reprise côté serveur (« 4m restantes » → « 12m restantes »).
    @Test("La file créée par l'hôte part de SA reprise, pas de zéro")
    func hostQueueStartsAtOwnResume() {
        #expect(SyncPlayJoinStart.queueStartTicks(resumeTicks: 6_600_000_000) == 6_600_000_000)
        #expect(SyncPlayJoinStart.queueStartTicks(resumeTicks: nil) == 0)
        #expect(SyncPlayJoinStart.queueStartTicks(resumeTicks: -1) == 0)
    }
}

// MARK: - D3 — re-announcing readiness after a seek

/// Records what actually reached the server. `OSAllocatedUnfairLock` rather
/// than `NSLock`: the protocol method is `async`, where `NSLock.lock()` is
/// unavailable.
private final class RecordingSyncPlayAPI: SyncPlayAPI, @unchecked Sendable {
    struct Report { let ticks: Int; let isPlaying: Bool; let entry: String? }
    private let store = OSAllocatedUnfairLock<[Report]>(initialState: [])

    var ready: [Report] { store.withLock { $0 } }
    func reset() { store.withLock { $0.removeAll() } }

    func syncPlayReady(positionTicks: Int, isPlaying: Bool, playlistItemId: String?) async throws {
        store.withLock { $0.append(Report(ticks: positionTicks, isPlaying: isPlaying, entry: playlistItemId)) }
    }
}

/// `reportReady` is fire-and-forget (`Task { … }`), so give the hop a bounded
/// chance to land rather than asserting on the same turn of the run loop.
@MainActor
private func settle(until condition: @MainActor () -> Bool, tries: Int = 50) async {
    for _ in 0..<tries {
        if condition() { return }
        await Task.yield()
    }
}

/// A seek puts the whole group into `Waiting` server-side, and the server only
/// leaves it when every participant re-announces readiness. Measured on device
/// 2026-09-06: after a ±10 s seek both clients went `Playing → Waiting` in the
/// same millisecond and **neither ever sent `Ready` again** — a full-screen
/// "En attente d'un participant" veil for at least 7 min 41 s over a picture
/// playing normally, ended by tearing the players down rather than by the app.
@MainActor
@Suite("SyncPlayController — un calage de recherche réannonce la disponibilité", .serialized)
struct SyncPlaySeekSettleReadyTests {

    private func inGroup(
        api: RecordingSyncPlayAPI,
        positionMs: @escaping @MainActor () -> Int
    ) async -> SyncPlayController {
        let c = SyncPlayController.shared
        _ = await c.createGroup(
            named: "test", api: api, loc: LocalizationManager(),
            toast: ToastCenter(), currentUserName: "moi"
        )
        c.bindPlayback(.init(
            play: {}, pause: {}, seekMs: { _ in }, positionMs: positionMs, stop: {}
        ))
        api.reset()
        return c
    }

    @Test("Un calage réannonce la disponibilité à la position atteinte")
    func settledSeekAnnouncesReadyAtLandedPosition() async {
        let api = RecordingSyncPlayAPI()
        let c = await inGroup(api: api, positionMs: { 74_655 })
        defer { c.leaveGroup() }
        c.applyState("Waiting")

        c.reportSeekSettled(isPlaying: true)

        await settle(until: { !api.ready.isEmpty })
        #expect(api.ready.count == 1)
        #expect(api.ready.first?.ticks == 746_550_000)
        #expect(api.ready.first?.isPlaying == true)
    }

    /// Le test discriminant. Une recherche INBOUND lève la fenêtre d'écho, et
    /// c'est précisément elle qui met le groupe en `Waiting` : si le calage
    /// atterrit dans la seconde qui suit, `reportReady` se tait et le groupe
    /// n'en sort jamais. Le rapport de calage doit donc traverser la fenêtre —
    /// c'est ce qui le distingue de `reportReady`.
    @Test("Le rapport traverse la fenêtre d'écho d'une commande entrante")
    func settledSeekReportsThroughTheRemoteEchoWindow() async {
        let api = RecordingSyncPlayAPI()
        let c = await inGroup(api: api, positionMs: { 74_655 })
        defer { c.leaveGroup() }

        c.applyState("Waiting")
        // Une commande Seek entrante : elle lève la fenêtre d'écho pour 1 s.
        c.applyCommand(SyncPlayCommand(
            command: .seek, positionTicks: 746_550_000,
            when: nil, emittedAt: nil, playlistItemId: nil
        ))
        #expect(c.isApplyingRemoteCommand)

        // L'ancien chemin se tait pendant la fenêtre — c'est le défaut.
        c.reportReady(isPlaying: true)
        await settle(until: { !api.ready.isEmpty }, tries: 10)
        #expect(api.ready.isEmpty)

        // Le nouveau passe.
        c.reportSeekSettled(isPlaying: true)
        await settle(until: { !api.ready.isEmpty })
        #expect(api.ready.count == 1)
    }

    /// La boucle de rétroaction, mesurée sur appareil le 2026-09-06 après un
    /// premier correctif trop large : `Ready` → le serveur répond `Unpause` à
    /// une position 0,4 s en arrière → recherche → calage → `Ready` → … toutes
    /// les 0,6 s, indéfiniment, l'image reculant à chaque tour. Un groupe déjà
    /// en lecture n'attend la disponibilité de personne : il n'y a rien à
    /// annoncer, et l'annoncer quand même est ce qui referme la boucle.
    @Test("Groupe déjà en lecture : un calage n'annonce rien (pas de boucle)")
    func settledSeekIsSilentWhileTheGroupIsAlreadyPlaying() async {
        let api = RecordingSyncPlayAPI()
        let c = await inGroup(api: api, positionMs: { 220_067 })
        defer { c.leaveGroup() }
        c.applyState("Playing")

        c.reportSeekSettled(isPlaying: true)

        await settle(until: { !api.ready.isEmpty }, tries: 10)
        #expect(api.ready.isEmpty)
    }

    @Test("Hors groupe, un calage n'envoie rien")
    func settledSeekOutsideAGroupSendsNothing() async {
        let api = RecordingSyncPlayAPI()
        let c = SyncPlayController.shared
        c.leaveGroup()
        api.reset()

        c.reportSeekSettled(isPlaying: true)

        await settle(until: { !api.ready.isEmpty }, tries: 10)
        #expect(api.ready.isEmpty)
    }
}

// MARK: - Announcing readiness at a position the engine has actually reached

/// `Ready` is not a courtesy: Jellyfin reads its `PositionTicks` as "this is
/// where that participant is", and uses the difference against the group's own
/// position to decide whether the client is *lagging*. A report sent from a
/// position the engine has not reached yet therefore does not merely arrive
/// early — it makes the server believe the group must wait for a straggler.
///
/// Measured on the iPhone simulator against the real server on 2026-09-06,
/// with the group's queue seeded at 1:36 (`position=964460000`):
///
/// ```
/// 18:50:18.801  engine-state opening
/// 18:50:18.876  état du groupe : Paused → Waiting
/// 18:50:18.934  engine-state playing          ← 133 ms after `opening`
/// 18:50:18.935  Ready envoyé position=0       ← the lie
/// 18:50:20.774  seek-settle now=96446 landed=true   ← the truth, 1.8 s later
/// ```
///
/// libVLC reports `.playing` as soon as the input starts, **before the demuxer
/// has reached the position the group asked for** — the same fact the
/// `clearLoadingIfOpen` / `noteMediaOpened` RULE already documents for the
/// spinner. The server read `0` against its own `964460000`, concluded this
/// session was 96 s behind, and took `WaitingGroupState`'s "client is
/// recovering" branch, which sets `LastActivity = now + 96.4 s`. From then on
/// every command it issued carried a `When` up to 96 s in the future, and
/// `SyncPlayController.schedule` slept on each one (capped at 30 s) before
/// applying it — so pause, ±10 s and unpause all read as dead buttons, and a
/// later command cancelled the one still waiting. The group's `PositionTicks`
/// stopped advancing too (`Math.Max(elapsed, 0)` clamps a negative elapsed to
/// zero), so the `Pause` that eventually landed dragged the picture from 2:45
/// back to 1:36.
@Suite("SyncPlayReadyPolicy — n'annoncer qu'une position réellement atteinte")
struct SyncPlayReadyPolicyTests {

    @Test("Un « playing » qui précède l'ouverture du média n'annonce rien")
    func silentBeforeTheMediaIsOpen() {
        #expect(SyncPlayReadyPolicy.shouldAnnounceReady(
            mediaConfirmedOpen: false, startSeekPending: false, isSeekSettling: false) == false)
    }

    /// Le cas décisif, et celui qu'un premier correctif a manqué : le média est
    /// OUVERT et aucune recherche n'est en cours — parce que la recherche de
    /// reprise n'a pas encore été *émise*. Mesuré le 2026-09-06 après ce premier
    /// correctif, groupe à 7:04 :
    ///
    /// ```
    /// 19:06:30.748  Ready envoyé position=0     ← média ouvert, rien en calage
    /// 19:06:30.809  engine-state playing
    /// 19:06:30.810  Ready envoyé position=0
    /// 19:06:30.826  seek-fire target=424172 from=0   ← la reprise part APRÈS
    /// ```
    ///
    /// `VLCStreamPresenter` n'émet la recherche de reprise que depuis
    /// `onEngineTimeChanged`, une fois `lengthMs` connu — donc « ouvert » précède
    /// « au bon endroit », et la fenêtre entre les deux est exactement celle où
    /// la tête de lecture vaut 0.
    @Test("Une reprise encore à émettre n'annonce rien, même média ouvert")
    func silentWhileTheStartSeekIsStillPending() {
        #expect(SyncPlayReadyPolicy.shouldAnnounceReady(
            mediaConfirmedOpen: true, startSeekPending: true, isSeekSettling: false) == false)
    }

    /// Et une fois émise, elle doit encore atterrir : la position reste celle
    /// d'avant le saut. Le rapport appartient alors au calage
    /// (`SyncPlayController.reportSeekSettled`), qui connaît la position
    /// d'arrivée.
    @Test("Une recherche en cours de calage n'annonce rien — le calage a son propre rapport")
    func silentWhileASeekIsStillSettling() {
        #expect(SyncPlayReadyPolicy.shouldAnnounceReady(
            mediaConfirmedOpen: true, startSeekPending: false, isSeekSettling: true) == false)
    }

    /// Et il faut bien que quelqu'un parle : un groupe qui démarre à zéro n'a
    /// aucune reprise à émettre et n'arme aucune fenêtre de calage, donc si ce
    /// cas se taisait aussi, plus personne ne sortirait jamais le groupe de
    /// `Waiting`.
    @Test("Média ouvert, aucune reprise en attente, aucun calage : on annonce")
    func announcesOnceOpenAndSettled() {
        #expect(SyncPlayReadyPolicy.shouldAnnounceReady(
            mediaConfirmedOpen: true, startSeekPending: false, isSeekSettling: false) == true)
    }
}
