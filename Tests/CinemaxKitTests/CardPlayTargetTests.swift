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
}
