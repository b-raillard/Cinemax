import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

// MARK: - Fixtures

private func entry(
    _ id: String,
    type: BaseItemKind = .movie,
    tag: String? = nil,
    seriesId: String? = nil,
    seriesTag: String? = nil
) -> BaseItemDto {
    var item = BaseItemDto()
    item.id = id
    item.type = type
    if let tag { item.imageTags = ["Primary": tag] }
    item.seriesID = seriesId
    item.seriesPrimaryImageTag = seriesTag
    return item
}

private func page(_ ids: [String], total: Int) -> PlaylistPreviewPage {
    PlaylistPreviewPage(items: ids.map { entry($0) }, totalCount: total)
}

// MARK: - The pure stack

/// Verrouille la couverture « pile d'affiches » des playlists.
///
/// Jellyfin dessine une mosaïque 2×2 qui RÉPÈTE ses affiches quand la
/// playlist n'en a qu'une ou deux — un même film quatre fois. La pile en
/// éventail montre au plus trois affiches distinctes, et moins d'affiches
/// quand il y a moins d'éléments.
@Suite("Playlist — couverture pile d'affiches")
struct PlaylistCoverStackTests {

    @Test("Le nombre d'affiches suit les éléments, plafonné à trois", arguments: [
        (0, 0), (1, 1), (2, 2), (3, 3), (4, 3),
    ])
    func posterCountFollowsTheEntries(entries: Int, expected: Int) {
        let items = (0..<entries).map { entry("m\($0)") }
        let posters = PlaylistCoverStack.posters(from: items)
        #expect(posters.count == expected)
        #expect(PlaylistCoverStack.placed(posters).count == expected)
    }

    /// Le même film deux fois, ou trois épisodes d'une même série, c'est UNE
    /// affiche — jamais la même image côte à côte.
    @Test("Aucune affiche n'est jamais répétée")
    func noPosterIsEverRepeated() {
        let items = [
            entry("a"), entry("a"),
            entry("e1", type: .episode, seriesId: "s"),
            entry("e2", type: .episode, seriesId: "s"),
            entry("b"),
        ]
        let posters = PlaylistCoverStack.posters(from: items)
        #expect(posters.map(\.itemId) == ["a", "s", "b"])

        let placed = PlaylistCoverStack.placed(posters)
        #expect(Set(placed.map(\.poster.itemId)).count == placed.count)
        #expect(Set(placed.map(\.slot.posterIndex)).count == placed.count)
    }

    /// L'image primaire d'un épisode est un still 16:9, qu'une case 2:3
    /// rognerait en lamelle : on dessine l'affiche de la série, avec SON tag.
    @Test("Un épisode est représenté par l'affiche de sa série")
    func anEpisodeShowsItsSeriesPoster() {
        let episode = entry("e1", type: .episode, tag: "still", seriesId: "s1", seriesTag: "poster")
        #expect(PlaylistCoverStack.poster(for: episode) == PlaylistCoverPoster(itemId: "s1", tag: "poster"))

        let movie = entry("m1", tag: "t1")
        #expect(PlaylistCoverStack.poster(for: movie) == PlaylistCoverPoster(itemId: "m1", tag: "t1"))

        // Sans série connue, l'épisode garde sa propre image plutôt que rien.
        let orphan = entry("e2", type: .episode, tag: "still")
        #expect(PlaylistCoverStack.poster(for: orphan) == PlaylistCoverPoster(itemId: "e2", tag: "still"))
    }

    @Test("Un élément sans id ne donne pas d'affiche")
    func anIdlessEntryIsSkipped() {
        var idless = BaseItemDto()
        idless.type = .movie
        #expect(PlaylistCoverStack.poster(for: idless) == nil)
        #expect(PlaylistCoverStack.posters(from: [idless, entry("m1")]).map(\.itemId) == ["m1"])
    }

    /// Ordre de DESSIN (arrière → avant) : l'affiche de devant est dessinée
    /// en dernier. Une seule : centrée, droite. Deux : devant + gauche.
    @Test("Les emplacements de l'éventail")
    func fanSlots() {
        #expect(PlaylistCoverStack.slots(count: 0).isEmpty)

        let one = PlaylistCoverStack.slots(count: 1)
        #expect(one.map(\.posterIndex) == [0])
        #expect(one.first?.rotation == 0)
        #expect(one.first?.xOffset == 0)
        #expect(one.first?.yOffset == 0.02)

        let two = PlaylistCoverStack.slots(count: 2)
        #expect(two.map(\.posterIndex) == [1, 0])
        #expect(two.first?.rotation == -9)
        #expect(two.first?.xOffset == -0.15)
        #expect(two.first?.yOffset == 0.05)

        let three = PlaylistCoverStack.slots(count: 3)
        #expect(three.map(\.posterIndex) == [2, 1, 0])
        #expect(three.first?.rotation == 9)
        #expect(three.first?.xOffset == 0.15)
        #expect(three.last == one.first)

        #expect(PlaylistCoverStack.slots(count: 7) == three)
    }

    /// Le fond neutre ne doit jamais faire flasher « vide » sur une playlist
    /// qui a du contenu : l'icône vide n'apparaît que quand c'est SU.
    @Test("Neutre, vide ou affiches")
    func coverContent() {
        #expect(PlaylistCoverStack.content(preview: nil, fallbackCount: nil) == .neutral)
        #expect(PlaylistCoverStack.content(preview: nil, fallbackCount: 4) == .neutral)
        #expect(PlaylistCoverStack.content(preview: nil, fallbackCount: 0) == .empty)

        let none = PlaylistPreview(posters: [], totalCount: 0)
        #expect(PlaylistCoverStack.content(preview: none, fallbackCount: 4) == .empty)

        // Des éléments, mais aucun dessinable (tous masqués par la limite
        // d'âge) : pas d'icône « vide » à côté de « 5 éléments ».
        let hidden = PlaylistPreview(posters: [], totalCount: 5)
        #expect(PlaylistCoverStack.content(preview: hidden, fallbackCount: 5) == .neutral)

        let poster = PlaylistCoverPoster(itemId: "m1", tag: nil)
        let some = PlaylistPreview(posters: [poster], totalCount: 1)
        #expect(PlaylistCoverStack.content(preview: some, fallbackCount: 0) == .posters([poster]))
    }
}

// MARK: - The preview store

/// Verrouille le store des aperçus de playlists (couverture + compte).
@MainActor
@Suite("Playlist — store d'aperçus")
struct PlaylistPreviewStoreTests {

    /// Un centre de notifications PRIVÉ : les autres suites tournent en
    /// parallèle et postent sur `.default`.
    private func makeStore() -> (PlaylistPreviewStore, NotificationCenter) {
        let center = NotificationCenter()
        return (PlaylistPreviewStore(notificationCenter: center), center)
    }

    @Test("Deux demandes pendant une requête en vol n'en font qu'une")
    func noDoubleFetch() async {
        let api = MockAPIClient()
        let gate = TestLatch()
        api.playlistPreviewGate = gate
        api.stubbedPlaylistPreviews["p1"] = page(["m1", "m2"], total: 5)
        let (store, _) = makeStore()

        let first = store.load(playlistId: "p1", userId: "u1", api: api)
        let second = store.load(playlistId: "p1", userId: "u1", api: api)
        #expect(first != nil)
        #expect(second == first, "la deuxième demande rejoint la première")

        gate.open()
        await first?.value

        #expect(api.playlistPreviewRequests == ["p1"])
        #expect(store.preview(for: "p1")?.totalCount == 5)
        #expect(store.preview(for: "p1")?.posters.map(\.itemId) == ["m1", "m2"])

        // Un aperçu courant ne redemande rien.
        #expect(store.load(playlistId: "p1", userId: "u1", api: api) == nil)
        #expect(api.playlistPreviewRequests.count == 1)
    }

    /// La notification marque périmé SANS effacer : la carte garde sa
    /// couverture jusqu'à l'arrivée de la nouvelle, pas de flash.
    @Test("Une modification invalide et garde l'aperçu affiché pendant le rechargement")
    func invalidationKeepsThePreviewWhileReloading() async {
        let api = MockAPIClient()
        api.stubbedPlaylistPreviews["p1"] = page(["m1"], total: 2)
        let (store, center) = makeStore()
        await store.load(playlistId: "p1", userId: "u1", api: api)?.value
        #expect(store.preview(for: "p1")?.totalCount == 2)

        api.stubbedPlaylistPreviews["p1"] = page(["m1", "m2"], total: 3)
        let gate = TestLatch()
        api.playlistPreviewGate = gate
        center.post(name: .cinemaxPlaylistsChanged, object: nil)
        #expect(await eventually { store.generation == 1 })

        let refetch = store.load(playlistId: "p1", userId: "u1", api: api)
        #expect(refetch != nil, "un aperçu périmé est redemandé")
        #expect(store.preview(for: "p1")?.totalCount == 2, "l'ancien reste affiché pendant la requête")

        gate.open()
        await refetch?.value
        #expect(store.preview(for: "p1")?.totalCount == 3)
        #expect(api.playlistPreviewRequests.count == 2)
    }

    @Test("Le rafraîchissement du catalogue invalide aussi")
    func catalogueRefreshInvalidates() async {
        let (store, center) = makeStore()
        center.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
        #expect(await eventually { store.generation == 1 })
    }

    /// Une couverture est décorative : un échec ne la vide pas, et la
    /// prochaine apparition de la carte retente.
    @Test("Un échec garde l'aperçu affiché et retente plus tard")
    func aFailedRefetchKeepsWhatIsShown() async {
        let api = MockAPIClient()
        api.stubbedPlaylistPreviews["p1"] = page(["m1"], total: 2)
        let (store, _) = makeStore()
        await store.load(playlistId: "p1", userId: "u1", api: api)?.value

        store.invalidate()
        api.shouldFailPlaylistPreview = true
        await store.load(playlistId: "p1", userId: "u1", api: api)?.value
        #expect(store.preview(for: "p1")?.totalCount == 2)

        api.shouldFailPlaylistPreview = false
        api.stubbedPlaylistPreviews["p1"] = page(["m1"], total: 4)
        await store.load(playlistId: "p1", userId: "u1", api: api)?.value
        #expect(store.preview(for: "p1")?.totalCount == 4)
        #expect(api.playlistPreviewRequests.count == 3)
    }

    /// Deux requêtes se chevauchent à travers une invalidation : la plus
    /// ancienne, arrivée en dernier, ne doit pas remettre l'ancien compte.
    @Test("Une réponse ancienne n'écrase pas une plus récente")
    func anOlderAnswerNeverOverwritesANewerOne() async {
        let api = MockAPIClient()
        api.stubbedPlaylistPreviews["p1"] = page(["m1"], total: 2)
        let gate = TestLatch()
        api.playlistPreviewGate = gate
        let (store, _) = makeStore()
        let older = store.load(playlistId: "p1", userId: "u1", api: api)
        #expect(await eventually { api.playlistPreviewRequestCount == 1 })

        api.playlistPreviewGate = nil
        api.stubbedPlaylistPreviews["p1"] = page(["m1", "m2"], total: 3)
        store.invalidate()
        await store.load(playlistId: "p1", userId: "u1", api: api)?.value
        #expect(store.preview(for: "p1")?.totalCount == 3)

        gate.open()
        await older?.value
        #expect(store.preview(for: "p1")?.totalCount == 3)
    }

    /// Ce qu'une playlist montre dépend du compte (limite parentale) : un
    /// autre compte repart de zéro, et une réponse pour l'ancien est ignorée.
    @Test("Un changement de compte repart de zéro")
    func anotherAccountStartsAfresh() async {
        let api = MockAPIClient()
        api.stubbedPlaylistPreviews["p1"] = page(["m1"], total: 2)
        let (store, _) = makeStore()
        await store.load(playlistId: "p1", userId: "u1", api: api)?.value
        #expect(store.preview(for: "p1") != nil)

        api.stubbedPlaylistPreviews["p1"] = page(["m9"], total: 1)
        let other = store.load(playlistId: "p1", userId: "u2", api: api)
        #expect(store.preview(for: "p1") == nil)
        await other?.value
        #expect(store.preview(for: "p1")?.posters.map(\.itemId) == ["m9"])
    }

    /// Une affiche que la nouvelle limite masque ne doit pas rester affichée
    /// « en attendant » — encore moins si le rechargement échoue.
    @Test("Une nouvelle limite d'âge repart de zéro")
    func aNewAgeCapStartsAfresh() async {
        let api = MockAPIClient()
        api.stubbedPlaylistPreviews["p1"] = page(["m1"], total: 2)
        let (store, _) = makeStore()
        await store.load(playlistId: "p1", userId: "u1", contentAgeCap: 0, api: api)?.value
        #expect(store.preview(for: "p1") != nil)

        api.shouldFailPlaylistPreview = true
        await store.load(playlistId: "p1", userId: "u1", contentAgeCap: 12, api: api)?.value
        #expect(store.preview(for: "p1") == nil)
        #expect(api.playlistPreviewRequests.count == 2)
    }

    @Test("Une playlist sans nom affiche « Playlist sans nom »")
    func blankNamesFallBack() {
        #expect(PlaylistCardButton.displayName(nil, untitled: "Sans nom") == "Sans nom")
        #expect(PlaylistCardButton.displayName("   ", untitled: "Sans nom") == "Sans nom")
        #expect(PlaylistCardButton.displayName("Soirée SF", untitled: "Sans nom") == "Soirée SF")
    }
}
