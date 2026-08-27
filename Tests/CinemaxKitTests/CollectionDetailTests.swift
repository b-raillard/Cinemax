import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Verrouille la fiche de collection.
///
/// Un BoxSet empruntait la chrome d'une œuvre : titre, Lecture, favori / vu /
/// playlist, « Titres similaires » — sans année, durée, genre ni résumé (un
/// BoxSet n'en porte aucun) et, surtout, sans la liste de ce qu'il contient,
/// qui est la seule chose qu'on vient y chercher. Appuyer sur Lecture ouvrait
/// le lecteur puis accusait le SERVEUR pour un flux qui n'a jamais existé.
@MainActor
@Suite("Fiche de collection")
struct CollectionDetailTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    /// Sert un BoxSet sur `getItem`, et ses membres sur `getItems`.
    private func makeAPI(children: [(id: String, name: String, year: Int)]) -> MockAPIClient {
        let api = MockAPIClient()
        api.getItemHandler = { id in
            var item = BaseItemDto()
            item.id = id
            item.name = "Wonder Woman - Saga"
            item.type = .boxSet
            return item
        }
        let payload: [BaseItemDto] = children.map { spec in
            var item = BaseItemDto()
            item.id = spec.id
            item.name = spec.name
            item.type = .movie
            item.productionYear = spec.year
            return item
        }
        api.getItemsHandler = { _ in (items: payload, totalCount: payload.count) }
        return api
    }

    /// `loadCollectionChildren` est une tâche latérale : on lui laisse le temps
    /// d'atterrir sans se reposer sur un délai fixe.
    private func waitForChildren(_ vm: MediaDetailViewModel) async {
        for _ in 0..<200 {
            if !vm.collectionChildren.isEmpty { return }
            await Task.yield()
        }
    }

    @Test("Une collection charge ce qu'elle contient")
    func boxSetLoadsItsMembers() async {
        let api = makeAPI(children: [
            (id: "c1", name: "Wonder Woman", year: 2017),
            (id: "c2", name: "Wonder Woman 1984", year: 2020)
        ])
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "box1", itemType: .boxSet)

        await vm.load(using: appState, loc: LocalizationManager())
        await waitForChildren(vm)

        #expect(vm.resolvedType == .boxSet)
        #expect(vm.collectionChildren.count == 2)
    }

    /// Une collection n'a rien à quoi être « semblable » : la requête coûtait
    /// un aller-retour pour remplir une rangée que la fiche ne dessine plus.
    @Test("Une collection ne demande pas de titres similaires")
    func boxSetSkipsSimilarItems() async {
        let api = makeAPI(children: [(id: "c1", name: "Wonder Woman", year: 2017)])
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "box1", itemType: .boxSet)

        await vm.load(using: appState, loc: LocalizationManager())

        #expect(api.getSimilarItemsCallCount == 0)
        #expect(vm.similarItems.isEmpty)
    }

    /// Contrôle apparié : un film, lui, garde son comportement d'origine.
    @Test("Un film garde ses titres similaires")
    func movieStillAsksForSimilarItems() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in
            var item = BaseItemDto()
            item.id = id
            item.name = "Matrix Resurrections"
            item.type = .movie
            return item
        }
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "m1", itemType: .movie)

        await vm.load(using: appState, loc: LocalizationManager())

        #expect(api.getSimilarItemsCallCount == 1)
        #expect(vm.collectionChildren.isEmpty)
    }
}

/// Verrouille la règle de « Tout lire ».
@Suite("Collection — point de départ de « Tout lire »")
struct CollectionPlayTargetTests {

    @Test("Une collection vide n'a rien à lire")
    func emptyCollectionHasNoTarget() {
        #expect(CollectionPlayTarget.startIndex(playedFlags: []) == nil)
    }

    @Test("Rien de vu : on commence au début")
    func nothingWatchedStartsAtTheBeginning() {
        #expect(CollectionPlayTarget.startIndex(playedFlags: [false, false, false]) == 0)
    }

    @Test("On reprend au premier titre non terminé")
    func resumesAtTheFirstUnfinished() {
        #expect(CollectionPlayTarget.startIndex(playedFlags: [true, true, false]) == 2)
    }

    /// Un trou au milieu compte : le premier non vu est le bon point de reprise,
    /// pas le premier après le dernier vu.
    @Test("Un titre sauté est repris avant la suite")
    func aSkippedTitleComesFirst() {
        #expect(CollectionPlayTarget.startIndex(playedFlags: [true, false, true]) == 1)
    }

    /// Le repli qui compte : `getNextUp` ne renvoie rien précisément sur la
    /// série qu'on vient de terminer. Sans ce repli, une saga vue en entier
    /// refuserait de se lire.
    @Test("Une saga vue en entier se rejoue depuis le début")
    func fullyWatchedReplaysFromTheStart() {
        #expect(CollectionPlayTarget.startIndex(playedFlags: [true, true, true]) == 0)
    }
}
