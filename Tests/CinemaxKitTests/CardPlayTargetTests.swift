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
        var data = UserItemDataDto()
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
            positionTicks: 6_000_000_000, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "m1")
        #expect(target.title == "Film")
        #expect(target.startSeconds == 600)
        #expect(api.getNextUpCallCount == 0)
    }

    @Test("Film marqué vu : la position résiduelle ne déclenche pas de reprise")
    func moviePlayedIgnoresPosition() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "m1", type: .movie, title: "Film",
            positionTicks: 6_000_000_000, isPlayed: true,
            api: api, userId: "u1"
        )
        #expect(target.startSeconds == nil)
    }

    @Test("Film jamais lancé : aucune reprise, aucun appel réseau")
    func movieWithoutResume() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "m1", type: .movie, title: "Film",
            positionTicks: 0, isPlayed: false,
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
            positionTicks: 3_000_000_000, isPlayed: false,
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
            positionTicks: 0, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "e7")
        #expect(target.title == "Épisode 7")
        #expect(target.startSeconds == 120)
        #expect(api.getNextUpCallCount == 1)
    }

    @Test("Série dont le next-up est vu : on cible l'épisode, sans reprise")
    func seriesNextUpPlayed() async {
        let api = MockAPIClient()
        api.stubbedNextUp = makeEpisode(id: "e7", name: "Épisode 7", positionTicks: 1_200_000_000, isPlayed: true)
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "e7")
        #expect(target.startSeconds == nil)
    }

    @Test("Série sans next-up : on retombe sur l'id de série, getPlaybackInfo tranchera")
    func seriesWithoutNextUp() async {
        let api = MockAPIClient()
        api.stubbedNextUp = nil
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0, isPlayed: false,
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
            positionTicks: 0, isPlayed: false,
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
            positionTicks: 0, isPlayed: false,
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
                positionTicks: 0, isPlayed: false,
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
            positionTicks: 0, isPlayed: false,
            api: api, userId: "u1",
            probeDeadline: .milliseconds(10)
        )
        #expect(api.getNextUpCallCount == 1)

        // Give the detached probe room to finish past its 100 ms sleep. If it
        // were cancelled, `getNextUpCompletedCount` would stay 0.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(api.getNextUpCompletedCount == 1)
    }
}
