import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Verrouille le réordonnancement d'une playlist.
@Suite("Playlist — index de destination")
struct PlaylistReorderIndexTests {

    /// Vers le HAUT, les deux conventions coïncident : SwiftUI donne un point
    /// d'insertion et Jellyfin veut un index final, qui sont le même nombre.
    @Test("Un déplacement vers le haut garde l'index")
    func movingUpKeepsTheIndex() {
        #expect(PlaylistReorder.destinationIndex(from: 3, to: 1) == 1)
        #expect(PlaylistReorder.destinationIndex(from: 1, to: 0) == 0)
    }

    /// Vers le BAS elles diffèrent d'un cran : le point d'insertion de SwiftUI
    /// est calculé sur la liste AVANT que la ligne n'en soit retirée. Sans la
    /// correction, la ligne atterrit une place trop haut — décalage silencieux,
    /// et le serveur enregistre docilement la mauvaise position.
    @Test("Un déplacement vers le bas retire le cran d'insertion")
    func movingDownDropsTheInsertionSlot() {
        #expect(PlaylistReorder.destinationIndex(from: 0, to: 2) == 1)
        #expect(PlaylistReorder.destinationIndex(from: 1, to: 4) == 3)
    }

    @Test("Une destination identique ne bouge pas")
    func sameSlotIsANoOp() {
        #expect(PlaylistReorder.destinationIndex(from: 2, to: 2) == 2)
    }
}

@MainActor
@Suite("Playlist — déplacement d'une entrée")
struct PlaylistMoveTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    /// Le même film peut figurer DEUX FOIS dans une playlist : chaque
    /// occurrence porte son propre `playlistItemID` et se déplace seule. Les
    /// deux entrées ci-dessous partagent volontairement leur `id` d'item.
    private func makeAPI() -> MockAPIClient {
        let api = MockAPIClient()
        api.stubbedPlaylistItems = [
            entry(itemId: "m1", entryId: "e1", name: "Pilote"),
            entry(itemId: "m2", entryId: "e2", name: "Épisode 2"),
            entry(itemId: "m1", entryId: "e3", name: "Pilote")
        ]
        return api
    }

    private func entry(itemId: String, entryId: String, name: String) -> BaseItemDto {
        var item = BaseItemDto()
        item.id = itemId
        item.playlistItemID = entryId
        item.name = name
        return item
    }

    @Test("La liste se charge dans l'ordre de la playlist")
    func loadsInPlaylistOrder() async {
        let api = makeAPI()
        let vm = PlaylistDetailViewModel()

        await vm.load(playlistId: "p1", using: makeAppState(api: api))

        #expect(vm.items.map(\.playlistItemID) == ["e1", "e2", "e3"])
    }

    @Test("Un déplacement réussi envoie l'ID D'ENTRÉE, pas celui de l'élément")
    func moveSendsTheEntryId() async {
        let api = makeAPI()
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()
        await vm.load(playlistId: "p1", using: appState)

        let failure = await vm.move(from: 2, to: 0, playlistId: "p1", using: appState)

        #expect(failure == nil)
        #expect(api.moveCalls.count == 1)
        // « e3 », pas « m1 » — les deux entrées partagent l'ID d'élément.
        #expect(api.moveCalls.first?.entryId == "e3")
        #expect(api.moveCalls.first?.newIndex == 0)
        #expect(vm.items.map(\.playlistItemID) == ["e3", "e1", "e2"])
    }

    /// Le geste est optimiste : si le serveur refuse, la ligne ne doit pas
    /// rester là où le doigt l'a lâchée — l'écran mentirait sur l'état réel.
    @Test("Un refus du serveur remet la liste en place")
    func aRefusedMoveIsRolledBack() async {
        let api = makeAPI()
        api.shouldFailPlaylistMove = true
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()
        await vm.load(playlistId: "p1", using: appState)

        let failure = await vm.move(from: 0, to: 2, playlistId: "p1", using: appState)

        #expect(failure != nil)
        #expect(vm.items.map(\.playlistItemID) == ["e1", "e2", "e3"])
    }

    /// Le même film figurant deux fois, retirer la troisième ligne doit
    /// retirer « e3 » — pas la première occurrence du même élément.
    @Test("Une suppression envoie l'ID D'ENTRÉE, pas celui de l'élément")
    func removeSendsTheEntryId() async {
        let api = makeAPI()
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()
        await vm.load(playlistId: "p1", using: appState)

        let outcome = await vm.remove(entryId: "e3", playlistId: "p1", using: appState)

        if case .removed = outcome {} else { Issue.record("suppression attendue") }
        #expect(api.removeCalls == [["e3"]])
        #expect(vm.items.map(\.playlistItemID) == ["e1", "e2"])
    }

    /// Optimiste comme le déplacement : un refus du serveur doit remettre la
    /// ligne, sans quoi l'écran affirme une suppression que la playlist n'a
    /// pas enregistrée.
    @Test("Un refus du serveur remet la ligne supprimée")
    func aRefusedRemoveIsRolledBack() async {
        let api = makeAPI()
        api.shouldFailPlaylistRemove = true
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()
        await vm.load(playlistId: "p1", using: appState)

        let outcome = await vm.remove(entryId: "e1", playlistId: "p1", using: appState)

        if case .failed = outcome {} else { Issue.record("échec attendu") }
        #expect(vm.items.map(\.playlistItemID) == ["e1", "e2", "e3"])
    }

    /// Retirer la dernière entrée doit faire basculer l'écran sur son état
    /// vide, pas le laisser sur une liste chargée sans contenu.
    @Test("Retirer la dernière entrée vide la playlist")
    func removingTheLastEntryEmptiesTheList() async {
        let api = makeAPI()
        api.stubbedPlaylistItems = [entry(itemId: "m1", entryId: "e1", name: "Seul")]
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()
        await vm.load(playlistId: "p1", using: appState)

        _ = await vm.remove(entryId: "e1", playlistId: "p1", using: appState)

        #expect(vm.items.isEmpty)
        if case .empty = vm.state {} else { Issue.record("état attendu : vide") }
    }

    /// La liste peut avoir bougé sous un menu déjà ouvert. Rien n'est envoyé,
    /// et surtout rien n'est annoncé : un toast dirait une suppression qui n'a
    /// pas eu lieu.
    @Test("Un identifiant d'entrée inconnu ne déclenche aucun appel et ne dit rien")
    func removingAnUnknownEntryIsSilent() async {
        let api = makeAPI()
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()
        await vm.load(playlistId: "p1", using: appState)

        let outcome = await vm.remove(entryId: "disparue", playlistId: "p1", using: appState)

        if case .notFound = outcome {} else { Issue.record("« introuvable » attendu") }
        #expect(api.removeCalls.isEmpty)
        #expect(vm.items.map(\.playlistItemID) == ["e1", "e2", "e3"])
    }

    @Test("Un index hors bornes ne déclenche aucun appel")
    func outOfRangeIsIgnored() async {
        let api = makeAPI()
        let appState = makeAppState(api: api)
        let vm = PlaylistDetailViewModel()
        await vm.load(playlistId: "p1", using: appState)

        _ = await vm.move(from: 0, to: 9, playlistId: "p1", using: appState)

        #expect(api.moveCalls.isEmpty)
        #expect(vm.items.map(\.playlistItemID) == ["e1", "e2", "e3"])
    }
}
