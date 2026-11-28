import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

private func film(_ id: String, entry: String, played: Bool = false) -> BaseItemDto {
    var item = BaseItemDto()
    item.id = id
    item.playlistItemID = entry
    item.type = .movie
    item.name = id
    if played {
        var data = UserItemDataDto(key: id)
        data.isPlayed = true
        item.userData = data
    }
    return item
}

private func episode(_ id: String, entry: String, series: String, season: Int = 1, number: Int = 1) -> BaseItemDto {
    var item = BaseItemDto()
    item.id = id
    item.playlistItemID = entry
    item.type = .episode
    item.seriesID = series
    item.seriesName = "Série \(series)"
    item.parentIndexNumber = season
    item.indexNumber = number
    return item
}

@Suite("Playlist — séries repliées")
struct PlaylistGroupingTests {

    @Test("Trois épisodes consécutifs d'une série tiennent sur une ligne")
    func threeEpisodesFold() {
        let items = [
            film("m1", entry: "e1"),
            episode("a1", entry: "e2", series: "s1"),
            episode("a2", entry: "e3", series: "s1"),
            episode("a3", entry: "e4", series: "s1"),
            film("m2", entry: "e5")
        ]
        let rows = PlaylistGrouping.rows(from: items)

        #expect(rows.count == 3)
        guard case .run(let run) = rows[1] else {
            Issue.record("La deuxième ligne devrait être une série repliée")
            return
        }
        #expect(run.seriesId == "s1")
        #expect(run.entryIds == ["e2", "e3", "e4"])
    }

    /// Deux épisodes côte à côte restent deux lignes : les replier cacherait
    /// leurs titres pour n'économiser qu'une ligne.
    @Test("Deux épisodes restent deux lignes")
    func twoEpisodesStayApart() {
        let items = [
            episode("a1", entry: "e1", series: "s1"),
            episode("a2", entry: "e2", series: "s1")
        ]
        #expect(PlaylistGrouping.rows(from: items).map(\.id) == ["e1", "e2"])
    }

    @Test("Un film entre deux épisodes coupe la série")
    func aFilmBreaksTheRun() {
        let items = [
            episode("a1", entry: "e1", series: "s1"),
            episode("a2", entry: "e2", series: "s1"),
            film("m1", entry: "e3"),
            episode("a3", entry: "e4", series: "s1"),
            episode("a4", entry: "e5", series: "s1")
        ]
        #expect(PlaylistGrouping.rows(from: items).count == 5)
    }

    @Test("Deux séries qui se suivent font deux lignes repliées")
    func twoSeriesMakeTwoRuns() {
        let items = (1...3).map { episode("a\($0)", entry: "ea\($0)", series: "s1") }
            + (1...4).map { episode("b\($0)", entry: "eb\($0)", series: "s2") }
        let rows = PlaylistGrouping.rows(from: items)

        #expect(rows.count == 2)
        #expect(rows.map(\.id) == ["run-ea1", "run-eb1"])
    }

    @Test("L'ordre de la playlist est conservé")
    func orderIsKept() {
        let items = [film("m1", entry: "e1"), film("m2", entry: "e2"), film("m3", entry: "e3")]
        #expect(PlaylistGrouping.rows(from: items).map(\.id) == ["e1", "e2", "e3"])
    }
}

@Suite("Playlist — ce qu'elle contient déjà")
struct PlaylistMembershipTests {

    /// Le même film deux fois = deux entrées : retirer « ce titre » les vise
    /// toutes les deux, par leur id d'ENTRÉE.
    @Test("Un film présent deux fois donne ses deux entrées")
    func aFilmTwiceGivesBothEntries() {
        let items = [film("m1", entry: "e1"), film("m2", entry: "e2"), film("m1", entry: "e3")]
        #expect(PlaylistMembership.entryIds(matching: "m1", in: items) == ["e1", "e3"])
    }

    @Test("Une série désigne chacun de ses épisodes")
    func aSeriesMeansItsEpisodes() {
        let items = [
            episode("a1", entry: "e1", series: "s1"),
            film("m1", entry: "e2"),
            episode("a2", entry: "e3", series: "s1"),
            episode("b1", entry: "e4", series: "s2")
        ]
        #expect(PlaylistMembership.entryIds(matching: "s1", in: items) == ["e1", "e3"])
        #expect(PlaylistMembership.episodeCount(ofSeries: "s1", in: items) == 2)
        #expect(PlaylistMembership.episodeCount(ofSeries: "s9", in: items) == 0)
    }

    @Test("Seuls les titres vus sont retirés par « Retirer les titres vus »")
    func onlyWatchedEntries() {
        let items = [film("m1", entry: "e1", played: true), film("m2", entry: "e2"), film("m3", entry: "e3", played: true)]
        #expect(PlaylistMembership.watchedEntryIds(in: items) == ["e1", "e3"])
    }

    @Test("Le code d'un épisode est « S01:E02 »")
    func episodeCode() {
        #expect(episode("a", entry: "e", series: "s", season: 1, number: 2).playlistEpisodeCode == "S01:E02")
        #expect(film("m", entry: "e").playlistEpisodeCode == nil)
    }
}

@Suite("Playlist — sélection numérotée")
struct PlaylistPickerSelectionTests {

    @Test("Chaque titre prend le numéro de son appui")
    func numbersFollowTheTaps() {
        var selection = PlaylistPickerSelection()
        selection.toggle("b")
        selection.toggle("a")
        selection.toggle("c")

        #expect(selection.ids == ["b", "a", "c"])
        #expect(selection.number(of: "b") == 1)
        #expect(selection.number(of: "a") == 2)
        #expect(selection.number(of: "c") == 3)
        #expect(selection.number(of: "z") == nil)
    }

    @Test("Décocher un titre fait remonter les suivants d'un numéro")
    func deselectingRenumbers() {
        var selection = PlaylistPickerSelection()
        ["a", "b", "c"].forEach { selection.toggle($0) }
        selection.toggle("a")

        #expect(selection.ids == ["b", "c"])
        #expect(selection.number(of: "b") == 1)
        #expect(selection.number(of: "c") == 2)
    }
}

@MainActor
@Suite("Playlist — ajouter des titres")
struct PlaylistAddTitlesTests {

    @Test("La sélection part en une requête, dans l'ordre des numéros")
    func commitSendsOneRequestInOrder() async throws {
        let api = MockAPIClient()
        let model = PlaylistAddTitlesModel()
        ["m3", "m1", "m2"].forEach { model.toggle($0) }

        let count = try await model.commit(playlistId: "p1", userId: "user1", api: api)

        #expect(count == 3)
        #expect(api.addToPlaylistCalls.count == 1)
        #expect(api.addToPlaylistCalls.first?.playlistId == "p1")
        #expect(api.addToPlaylistCalls.first?.itemIds == ["m3", "m1", "m2"])
        #expect(model.selection.isEmpty)
    }

    @Test("Un refus du serveur garde la sélection")
    func aRefusalKeepsTheSelection() async {
        let api = MockAPIClient()
        api.shouldFailPlaylistAdd = true
        let model = PlaylistAddTitlesModel()
        model.toggle("m1")

        await #expect(throws: (any Error).self) {
            _ = try await model.commit(playlistId: "p1", userId: "user1", api: api)
        }
        #expect(model.selection.ids == ["m1"])
        #expect(!model.isCommitting)
    }

    @Test("Une sélection vide n'envoie rien")
    func nothingSelectedSendsNothing() async throws {
        let api = MockAPIClient()
        let model = PlaylistAddTitlesModel()

        let count = try await model.commit(playlistId: "p1", userId: "user1", api: api)

        #expect(count == 0)
        #expect(api.addToPlaylistCalls.isEmpty)
    }

    @Test("La grille se charge depuis la bibliothèque")
    func gridLoads() async {
        let api = MockAPIClient()
        var item = BaseItemDto()
        item.id = "m1"
        // Le mock sert une requête « films + séries par date d'ajout » depuis
        // `stubbedLatestItems` (la forme de la rangée « Ajouts récents »).
        api.stubbedLatestItems = [item]
        let model = PlaylistAddTitlesModel()

        model.reload(userId: "user1", api: api)
        await model.loadTask?.value

        #expect(model.items.map(\.id) == ["m1"])
        #expect(!model.isLoading)
        // Une page, sans comptage côté serveur, champs de carte seulement.
        let query = api.getItemsQueries.last
        #expect(query?.includeItemTypes == [.movie, .series])
        #expect(query?.limit == PlaylistAddTitlesModel.pageSize)
        #expect(query?.enableTotalRecordCount == false)
        #expect(query?.fieldSet == .card)
    }
}

@MainActor
@Suite("Playlist — retraits groupés et annulation")
struct PlaylistBulkRemovalTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    @Test("Une série repliée part en une seule requête")
    func aRunIsRemovedInOneRequest() async {
        let api = MockAPIClient()
        api.stubbedPlaylistItems = [
            film("m1", entry: "e1"),
            episode("a1", entry: "e2", series: "s1"),
            episode("a2", entry: "e3", series: "s1")
        ]
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()
        await vm.load(playlistId: "p1", using: appState)

        let failure = await vm.remove(entryIds: ["e2", "e3"], playlistId: "p1", using: appState)

        #expect(failure == nil)
        #expect(api.removeCalls.count == 1)
        #expect(api.removeCalls.first == ["e2", "e3"])
        #expect(vm.items.map(\.playlistItemID) == ["e1"])
    }

    @Test("Un refus remet les lignes en place")
    func aRefusalPutsTheRowsBack() async {
        let api = MockAPIClient()
        api.stubbedPlaylistItems = [film("m1", entry: "e1"), film("m2", entry: "e2")]
        api.shouldFailPlaylistRemove = true
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()
        await vm.load(playlistId: "p1", using: appState)

        let failure = await vm.remove(entryIds: ["e1", "e2"], playlistId: "p1", using: appState)

        #expect(failure != nil)
        #expect(vm.items.map(\.playlistItemID) == ["e1", "e2"])
    }

    /// « Annuler » : le titre est ré-ajouté (le serveur l'ajoute en fin de
    /// liste) puis ramené à la place d'où il venait.
    @Test("Annuler un retrait remet le titre à sa place")
    func undoPutsTheTitleBack() async {
        let api = MockAPIClient()
        let removed = film("m1", entry: "e1")
        // Ce que le serveur renvoie après le ré-ajout : le titre en dernier,
        // sous un NOUVEL id d'entrée.
        api.stubbedPlaylistItems = [film("m2", entry: "e2"), film("m3", entry: "e3"), film("m1", entry: "e9")]
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()

        let failure = await vm.restore(removed, at: 0, playlistId: "p1", using: appState)

        #expect(failure == nil)
        #expect(api.addToPlaylistCalls.first?.itemIds == ["m1"])
        #expect(api.moveCalls.count == 1)
        #expect(api.moveCalls.first?.entryId == "e9")
        #expect(api.moveCalls.first?.newIndex == 0)
        #expect(vm.items.map(\.playlistItemID) == ["e9", "e2", "e3"])
    }
}
