import Testing
import Foundation
// `@preconcurrency` for the same reason as `MediaLibraryRefreshSpanTests`: the
// SDK ships `BaseItemDto` without a Sendable conformance.
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Verrouille le défaut **N** de la recette adversariale : un trou dans la
/// grille de bibliothèque, une carte manquante au milieu d'une rangée, absente
/// jusque de l'arbre d'accessibilité — alors que le compteur en tête la
/// comptait toujours.
///
/// Cause : Jellyfin pagine par décalage (`startIndex`), donc tout mouvement de
/// la liste entre deux pages décale la fenêtre et la page suivante redonne la
/// queue de la précédente. `ForEach(items, id: \.id)` sur des identifiants
/// dupliqués est **indéfini** en SwiftUI : une seule vue est rendue pour
/// l'identité dupliquée, et la carte disparaît en silence.
///
/// Ces tests exercent le décalage réel — un ajout en tête, ce qui est
/// précisément ce qui s'est produit pendant la campagne (« Nuremberg » ajouté
/// au catalogue sous un tri date-d'ajout descendant).
@MainActor
@Suite("Pagination — identité et dédoublonnage")
struct LibraryPaginationIdentityTests {

    /// Sert des pages à partir d'un catalogue qui a GLISSÉ de `shiftAfterFirstPage`
    /// éléments une fois la première page servie : l'élément d'indice *i* de la
    /// seconde requête est donc l'élément *i − décalage* de la première.
    private func shiftingFetch(
        total: Int,
        shiftAfterFirstPage: Int
    ) -> (Int) async -> (items: [String], total: Int) {
        var served = 0
        return { startIndex in
            let shift = served == 0 ? 0 : shiftAfterFirstPage
            served += 1
            let span = min(40, max(0, total - startIndex))
            let items = (startIndex..<(startIndex + span)).map { "m\($0 - shift)" }
            return (items: items, total: total)
        }
    }

    @Test("Une fenêtre décalée n'introduit aucun identifiant dupliqué")
    func shiftedWindowProducesNoDuplicateIdentity() async {
        let loader = PaginatedLoader<String>(pageSize: 40, identity: { $0 })
        let fetch = shiftingFetch(total: 200, shiftAfterFirstPage: 1)

        await loader.loadMore(fetch: fetch)
        await loader.loadMore(fetch: fetch)

        let ids = loader.items
        #expect(ids.count == Set(ids).count, "aucun identifiant ne doit apparaître deux fois")
        // La page 2 a redonné « m39 » (dernier de la page 1) : 40 + 39 retenus.
        #expect(ids.count == 79)
    }

    @Test("Sans identité déclarée, le comportement historique est intact")
    func withoutIdentityDuplicatesStillAppend() async {
        let loader = PaginatedLoader<String>(pageSize: 40)
        let fetch = shiftingFetch(total: 200, shiftAfterFirstPage: 1)

        await loader.loadMore(fetch: fetch)
        await loader.loadMore(fetch: fetch)

        #expect(loader.items.count == 80, "aucune dédup demandée ⇒ aucun élément écarté")
    }

    /// Le piège du correctif : dédoublonner en paginant sur `items.count` fait
    /// redemander les mêmes éléments à chaque page et `hasLoadedAll` — dérivé
    /// d'un compte qui ne peut plus atteindre le total — ne devient jamais vrai,
    /// donc le `.onAppear` de la dernière carte tire indéfiniment.
    @Test("La pagination se termine malgré les doublons écartés")
    func paginationStillTerminatesDespiteDroppedDuplicates() async {
        let loader = PaginatedLoader<String>(pageSize: 40, identity: { $0 })
        let fetch = shiftingFetch(total: 80, shiftAfterFirstPage: 1)

        await loader.loadMore(fetch: fetch)
        #expect(loader.hasLoadedAll == false, "pré-condition : une page sur deux")

        await loader.loadMore(fetch: fetch)
        #expect(loader.hasLoadedAll, "le décalage écarte un doublon, la fin reste atteinte")
    }

    @Test("Une page vide termine la pagination même si le total sur-déclare")
    func emptyPageEndsPagination() async {
        let loader = PaginatedLoader<String>(pageSize: 40, identity: { $0 })

        await loader.loadMore { _ in (items: ["a", "b"], total: 999) }
        #expect(loader.hasLoadedAll == false)

        await loader.loadMore { _ in (items: [], total: 999) }
        #expect(loader.hasLoadedAll, "plus rien à servir ⇒ fin, quoi qu'annonce le total")
    }

    @Test("Le rafraîchissement de la travée dédoublonne aussi")
    func spanRefreshDeduplicates() async {
        let loader = PaginatedLoader<String>(pageSize: 40, identity: { $0 })
        await loader.loadMore { _ in (items: ["a", "b", "c"], total: 3) }

        await loader.refreshLoadedSpan { _, _ in (items: ["a", "a", "b"], total: 3) }

        #expect(loader.items == ["a", "b"])
    }

    /// La travée redemandée doit couvrir ce que le SERVEUR a servi, pas ce que
    /// l'écran a retenu — sinon chaque doublon écarté rétrécit définitivement
    /// la fenêtre rafraîchie.
    @Test("La travée redemandée couvre le décalage serveur, pas la liste affichée")
    func spanRefreshAsksForTheServerSpan() async {
        let loader = PaginatedLoader<String>(pageSize: 40, identity: { $0 })
        await loader.loadMore { _ in (items: ["a", "a", "b"], total: 10) }
        #expect(loader.items.count == 2, "pré-condition : un doublon écarté")

        var requestedLimit: Int?
        await loader.refreshLoadedSpan { _, limit in
            requestedLimit = limit
            return (items: ["a", "b"], total: 10)
        }

        #expect(requestedLimit == 3, "3 éléments reçus du serveur, pas 2 affichés")
    }
}

/// Verrouille le défaut **L** : dans un menu « Personnalisé / Par bibliothèque »,
/// une bibliothèque cadrée par `parentId` recevait la liste de genres du
/// SERVEUR ENTIER. Le symptôme visible n'était pas les pastilles mortes mais la
/// disparition des rangées de genres : `fetchGenreItems` ne charge que les
/// `genreLoadLimit` premiers genres de cette liste, donc une bibliothèque dont
/// les genres propres sortaient du top-8 du serveur se réduisait à son héros.
@MainActor
@Suite("Bibliothèque cadrée — genres")
struct ScopedLibraryGenresTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    @Test("Une bibliothèque cadrée demande SES genres")
    func scopedLibraryScopesItsGenreQuery() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: nil, parentId: "lib-1")

        await vm.loadInitial(using: appState, loc: LocalizationManager())

        #expect(api.lastGenresParentId == "lib-1")
    }

    @Test("Un onglet non cadré interroge tout le serveur")
    func unscopedLibraryKeepsServerWideGenres() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.loadInitial(using: appState, loc: LocalizationManager())

        #expect(api.lastGenresParentId == nil)
    }
}

/// Verrouille le défaut **M** : la barre A–Z ne cherchait que dans les pages
/// déjà paginées et le consommateur n'avait pas de branche de repli. Sur un
/// catalogue de 503 films dont la première page s'arrêtait aux « B », C à Z
/// étaient mortes dès l'ouverture — c'est-à-dire que la barre était inerte
/// exactement là où la pagination la rendait nécessaire.
///
/// Jellyfin ne dit jamais à quel rang se trouve un titre : « sauter à M » n'est
/// pas exprimable en décalage. Le ré-ancrage demande « tout à partir de M »,
/// une requête quelle que soit la taille du catalogue.
@MainActor
@Suite("Bibliothèque — ancrage A–Z")
struct LibraryLetterAnchorTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    private func makeAPI(total: Int = 503) -> MockAPIClient {
        let api = MockAPIClient()
        api.getItemsHandler = { [weak api] startIndex in
            let start = startIndex ?? 0
            let limit = api?.getItemsCalls.last?.limit ?? 40
            let span = min(limit, max(0, total - start))
            let items: [BaseItemDto] = (start..<(start + span)).map { i in
                var item = BaseItemDto()
                item.id = "m\(i)"
                item.name = "Film \(i)"
                return item
            }
            return (items: items, totalCount: total)
        }
        return api
    }

    /// Grille filtrée chargée sur une page, prête à recevoir un appui.
    private func loadedGrid(_ api: MockAPIClient) async -> (MediaLibraryViewModel, AppState) {
        let appState = makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)
        vm.sortFilter.showUnwatchedOnly = true
        await vm.applyFilter(using: appState)
        return (vm, appState)
    }

    @Test("Une lettre hors des pages chargées ré-ancre la requête")
    func unloadedLetterReanchorsTheQuery() async {
        let api = makeAPI()
        let (vm, appState) = await loadedGrid(api)
        #expect(api.lastNameAnchor == nil, "pré-condition : première page non ancrée")

        let moved = await vm.anchorGrid(atLetter: "M", using: appState)

        #expect(moved)
        #expect(api.lastNameAnchor == "M")
        #expect(vm.letterAnchor == "M")
        #expect(api.getItemsCalls.last?.startIndex == 0, "l'ancre repart de la page 0")
    }

    @Test("La pagination suivante reste ancrée")
    func paginationKeepsTheAnchor() async {
        let api = makeAPI()
        let (vm, appState) = await loadedGrid(api)
        await vm.anchorGrid(atLetter: "M", using: appState)

        await vm.loadMoreFiltered(using: appState)

        #expect(api.lastNameAnchor == "M", "la page 2 doit rester dans la même tranche")
        #expect(api.getItemsCalls.last?.startIndex == 40)
    }

    @Test("« # » ramène au début de la liste")
    func hashClearsTheAnchor() async {
        let api = makeAPI()
        let (vm, appState) = await loadedGrid(api)
        await vm.anchorGrid(atLetter: "M", using: appState)

        let moved = await vm.anchorGrid(atLetter: "#", using: appState)

        #expect(moved)
        #expect(vm.letterAnchor == nil)
        #expect(api.lastNameAnchor == nil)
    }

    /// Le compteur en tête décrit la BIBLIOTHÈQUE, pas la tranche affichée : une
    /// requête ancrée ne compte que les titres à partir de l'ancre, et le
    /// bandeau serait tombé de « 503 films » à « 210 films » sur un simple appui.
    @Test("Le compteur garde le total de la bibliothèque une fois ancré")
    func headerKeepsTheRealTotal() async {
        let api = makeAPI(total: 503)
        let (vm, appState) = await loadedGrid(api)
        #expect(vm.displayedTotalCount == 503)

        api.getItemsHandler = { _ in
            var item = BaseItemDto()
            item.id = "anchored"
            item.name = "Matrix Resurrections"
            return (items: [item], totalCount: 210) // ce que le serveur compte à partir de M
        }
        await vm.anchorGrid(atLetter: "M", using: appState)

        #expect(vm.filteredLoader.totalCount == 210, "la requête ancrée compte bien sa tranche")
        #expect(vm.displayedTotalCount == 503, "mais le bandeau parle de la bibliothèque")
    }

    /// Un filtre différent décrit une autre liste : l'ancre prise sur la
    /// précédente n'a plus de sens.
    @Test("Un changement de filtre efface l'ancre")
    func changingTheFilterClearsTheAnchor() async {
        let api = makeAPI()
        let (vm, appState) = await loadedGrid(api)
        await vm.anchorGrid(atLetter: "M", using: appState)
        #expect(vm.letterAnchor == "M")

        vm.sortFilter.selectedDecades = [1990]
        await vm.applyFilter(using: appState)

        #expect(vm.letterAnchor == nil)
        #expect(api.lastNameAnchor == nil)
    }

    /// Le va-et-vient d'onglet re-déclenche `.task(id:)` ⇒ `applyFilter` avec un
    /// filtre inchangé, qui doit rester sans effet — sinon l'ancre serait perdue
    /// à chaque aller-retour.
    @Test("Un aller-retour d'onglet préserve l'ancre")
    func tabRoundTripPreservesTheAnchor() async {
        let api = makeAPI()
        let (vm, appState) = await loadedGrid(api)
        await vm.anchorGrid(atLetter: "M", using: appState)

        await vm.applyFilter(using: appState) // ré-attache, filtre identique

        #expect(vm.letterAnchor == "M")
    }
}
