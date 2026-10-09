import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

@Suite("CardPlayTarget")
struct CardPlayTargetTests {

    private func makeEpisode(id: String, name: String, positionTicks: Int, isPlayed: Bool) -> BaseItemDto {
        var ep = BaseItemDto()
        ep.id = id
        ep.name = name
        var data = UserItemDataDto(key: "test")
        data.playbackPositionTicks = positionTicks
        data.isPlayed = isPlayed
        ep.userData = data
        return ep
    }

    // MARK: - Film / épisode : tout est local, aucun appel réseau

    @Test("Film à demi vu : reprise appliquée, sans appel réseau")
    func movieWithResume() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "m1", type: .movie, title: "Film",
            positionTicks: 6_000_000_000,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "m1")
        #expect(target.title == "Film")
        #expect(target.startSeconds == 600)
        #expect(api.getNextUpCallCount == 0)
    }

    /// Jellyfin remet la position à zéro dès qu'il marque un titre vu (fin de
    /// lecture, `/UserPlayedItems`) : une position sur un titre vu est un
    /// revisionnage interrompu, et elle reprend.
    @Test("Film déjà vu revu en partie : la reprise s'applique")
    func moviePlayedWithPositionResumes() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "m1", type: .movie, title: "Film",
            positionTicks: 6_000_000_000,
            api: api, userId: "u1"
        )
        #expect(target.startSeconds == 600)
    }

    /// Le cas mesuré le 2026-10-05 : Arrow S02E11, vu en entier, relancé puis
    /// arrêté à 36:33 — Jellyfin le range dans « Reprendre » avec sa barre, et
    /// la carte repartait de 0:00.
    @Test("Épisode vu, relancé et arrêté à 36:33 : la carte reprend à 36:33")
    func measuredRewatchResumes() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "b69daaa0670d6930140f183376a7a943", type: .episode, title: "Le masque tombe",
            positionTicks: 21_936_880_000,
            api: api, userId: "u1"
        )
        #expect(target.startSeconds == 2193.688)
        #expect(CardPlayTargetResolver.resumeSeconds(positionTicks: 21_936_880_000) == 2193.688)
    }

    @Test("Film jamais lancé : aucune reprise, aucun appel réseau")
    func movieWithoutResume() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "m1", type: .movie, title: "Film",
            positionTicks: 0,
            api: api, userId: "u1"
        )
        #expect(target.startSeconds == nil)
        #expect(api.getNextUpCallCount == 0)
    }

    @Test("Épisode à demi vu : reprise locale, aucun appel réseau")
    func episodeWithResume() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "e1", type: .episode, title: "S01E03",
            positionTicks: 3_000_000_000,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "e1")
        #expect(target.startSeconds == 300)
        #expect(api.getNextUpCallCount == 0)
    }

    // MARK: - Série : un getNextUp, et seulement pour l'offset

    @Test("Série : cible l'épisode next-up et hérite de sa position")
    func seriesResolvesNextUp() async {
        let api = MockAPIClient()
        api.stubbedNextUp = makeEpisode(id: "e7", name: "Épisode 7", positionTicks: 1_200_000_000, isPlayed: false)
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "e7")
        #expect(target.title == "Épisode 7")
        #expect(target.startSeconds == 120)
        #expect(api.getNextUpCallCount == 1)
    }

    @Test("Série dont le next-up est vu mais entamé : on cible l'épisode, avec reprise")
    func seriesNextUpPlayed() async {
        let api = MockAPIClient()
        api.stubbedNextUp = makeEpisode(id: "e7", name: "Épisode 7", positionTicks: 1_200_000_000, isPlayed: true)
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "e7")
        #expect(target.startSeconds == 120)
    }

    @Test("Série sans next-up : on retombe sur l'id de série, getPlaybackInfo tranchera")
    func seriesWithoutNextUp() async {
        let api = MockAPIClient()
        api.stubbedNextUp = nil
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "s1")
        #expect(target.title == "Ma série")
        #expect(target.startSeconds == nil)
    }

    @Test("Série dont le sondage next-up échoue : dégrade sans jeter")
    func seriesNextUpThrows() async {
        let api = MockAPIClient()
        api.nextUpShouldThrow = true
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "s1")
        #expect(target.startSeconds == nil)
    }

    // MARK: - Série : sondage lent (course contre le délai)

    @Test("Série dont le sondage next-up est trop lent : dégrade au délai, sans attendre la réponse")
    func seriesNextUpTimesOut() async {
        let api = MockAPIClient()
        // Slower than the (short, test-only) probe deadline below, but the
        // mock still eventually resolves — proving the resolver returns on
        // the deadline rather than waiting for this to complete.
        api.nextUpDelay = .milliseconds(300)
        api.stubbedNextUp = makeEpisode(id: "e7", name: "Épisode 7", positionTicks: 1_200_000_000, isPlayed: false)
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0,
            api: api, userId: "u1",
            probeDeadline: .milliseconds(50)
        )
        #expect(target.itemId == "s1")
        #expect(target.title == "Ma série")
        #expect(target.startSeconds == nil)
    }

    /// The assertion the test above was missing, and without which it could not
    /// fail: it only ever checked the *result*, which is identical whether the
    /// resolver returns on the deadline or waits out the probe. It waited.
    ///
    /// `withTaskGroup` awaits every remaining child after its body returns, so
    /// `group.next()` + `cancelAll()` produced the deadline's *decision*
    /// immediately but only *returned* once the probe had finished — and
    /// `MockAPIClient.getNextUp` sleeps with `try? await Task.sleep`, which
    /// swallows `CancellationError`, so it slept its full 300 ms regardless of
    /// the cancel. The documented "raced against a 1.5 s deadline" was therefore
    /// advisory. Real-world exposure was limited only because URLSession
    /// cancellation is prompt; one non-cancellable await under `getNextUp` would
    /// have restored the 30 s client timeout to a path with, by its own comment,
    /// no loading affordance.
    @Test("Le délai est réellement appliqué : la résolution rend la main sans attendre le sondage")
    func seriesNextUpDeadlineIsEnforced() async {
        let api = MockAPIClient()
        api.nextUpDelay = .seconds(3)
        api.stubbedNextUp = makeEpisode(id: "e7", name: "Épisode 7", positionTicks: 1_200_000_000, isPlayed: false)

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            let target = await CardPlayTargetResolver.resolve(
                itemId: "s1", type: .series, title: "Ma série",
                positionTicks: 0,
                api: api, userId: "u1",
                probeDeadline: .milliseconds(50)
            )
            #expect(target.itemId == "s1")
            #expect(target.startSeconds == nil)
        }

        // Generous against CI scheduling noise while still an order of magnitude
        // below the 3 s probe: this fails outright if the probe is awaited.
        #expect(elapsed < .milliseconds(1000))
    }

    /// The probe must NOT be cancelled when the deadline wins. `getNextUp`
    /// populates the 10 s `nextup-` cache only after its response lands, so
    /// cancelling it discarded exactly what would make the next tap on the same
    /// card fast — turning a one-off timeout into a repeated one, in the
    /// situation where the resume offset is most wanted.
    @Test("Le sondage perdant continue en fond pour réchauffer le cache next-up")
    func losingProbeStillCompletes() async {
        let api = MockAPIClient()
        api.nextUpDelay = .milliseconds(100)
        api.stubbedNextUp = makeEpisode(id: "e7", name: "Épisode 7", positionTicks: 1_200_000_000, isPlayed: false)

        _ = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0,
            api: api, userId: "u1",
            probeDeadline: .milliseconds(10)
        )
        // Wait (bounded) for the detached probe to finish past its 100 ms delay.
        // Asserting the call count straight away would be a flake: with a 10 ms
        // deadline the resolver can return before the probe task has even been
        // scheduled.
        await eventually { api.getNextUpCompletedCount >= 1 }
        #expect(api.getNextUpCallCount == 1)
        // The point of the test: cancelled, this would still be 0.
        #expect(api.getNextUpCompletedCount == 1)
    }
}

/// Recette 2026-10-08, M2-15 : un titre à deux versions repris depuis une carte
/// ouvrait la 4K classée première à la position du 1080p, y rapportait sa
/// progression, et Sintel sortait de « Reprendre » après une relance.
@Suite("Source ouverte par une reprise")
struct ResumeSourceTests {
    @Test("Une reprise sans version choisie ouvre la source de l'élément")
    func resumeOpensTheItemsOwnSource() {
        #expect(CardPlayTargetResolver.sourceToOpen(itemId: "sintel", explicitSourceId: nil, startTime: 487) == "sintel")
    }

    @Test("Une version choisie l'emporte toujours")
    func explicitVersionWins() {
        #expect(CardPlayTargetResolver.sourceToOpen(itemId: "sintel", explicitSourceId: "4k", startTime: 487) == "4k")
        #expect(CardPlayTargetResolver.sourceToOpen(itemId: "sintel", explicitSourceId: "4k", startTime: nil) == "4k")
    }

    @Test("Un départ à 0 laisse le choix au classement")
    func startFromZeroLeavesTheRankedPick() {
        #expect(CardPlayTargetResolver.sourceToOpen(itemId: "sintel", explicitSourceId: nil, startTime: nil) == nil)
        #expect(CardPlayTargetResolver.sourceToOpen(itemId: "sintel", explicitSourceId: nil, startTime: 0) == nil)
    }
}
