import Testing
import Foundation
// `@preconcurrency`, as in `FavoritesViewModelTests`: the SDK ships
// `BaseItemDto` without a Sendable conformance, so a plain import turns every
// read of the `@MainActor` loader's items into a hard error.
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Verrouille D4, trouvé en recette adversariale.
///
/// Marquer un item « vu » depuis le menu contextuel d'une vignette poste
/// `.cinemaxItemUserDataChanged`. `MovieLibraryScreen` y répondait par un
/// rechargement complet : `applyFilter` appelle `filteredLoader.reset()`, qui
/// vide la liste et ne redemande que la page 0. Une grille filtrée parcourue
/// sur plusieurs pages était donc ramenée à 40 items, en haut, **sous le doigt
/// de l'utilisateur** — alors que le remède documenté (`refreshLoadedSpan`)
/// existait déjà et n'était câblé que sur Favoris et Historique.
// `@MainActor` must precede `@Suite`: applied after, the macro expansion does
// not carry the isolation, the test bodies become nonisolated, and every read
// of the `@MainActor` loader turns into a cross-actor access of a
// non-`Sendable` `BaseItemDto`. Same order as `FavoritesViewModelTests`.
@MainActor
@Suite("Bibliothèque — rafraîchissement ciblé")
struct MediaLibraryRefreshSpanTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    /// Sert 40 items par page sur un catalogue de 200, en numérotant les ids
    /// d'après `startIndex` — ce qui rend l'identité des items observable.
    private func makePagingAPI(total: Int = 200) -> MockAPIClient {
        let api = MockAPIClient()
        api.getItemsHandler = { [weak api] startIndex in
            let start = startIndex ?? 0
            // The handler is only handed `startIndex`, but the mock records the
            // call (limit included) *before* invoking it — so honour the real
            // limit. Serving a fixed 40 would make the whole-span refresh look
            // like it collapsed even once it is fixed.
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

    @Test("Une bascule « vu » ne renvoie pas la grille filtrée à la page 0")
    func userDataRefreshPreservesLoadedSpan() async {
        let api = makePagingAPI()
        let appState = makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)
        vm.sortFilter.showUnwatchedOnly = true // → grille filtrée

        await vm.applyFilter(using: appState)
        await vm.loadMoreFiltered(using: appState)
        // `BaseItemDto` n'est pas Sendable : on extrait des valeurs simples
        // avant `#expect`, dont la macro capture les sous-expressions.
        let loadedBefore = vm.filteredLoader.items.count
        #expect(loadedBefore == 80, "pré-condition : deux pages chargées")

        await vm.refreshUserData(using: appState)

        let loadedAfter = vm.filteredLoader.items.count
        let firstID = vm.filteredLoader.items.first?.id
        let lastID = vm.filteredLoader.items.last?.id
        #expect(loadedAfter == 80)
        #expect(firstID == "m0")
        #expect(lastID == "m79")
    }

    @Test("Le rafraîchissement ciblé tient en une seule requête")
    func refreshIssuesOneRequestForTheWholeSpan() async {
        let api = makePagingAPI()
        let appState = makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)
        vm.sortFilter.showUnwatchedOnly = true

        await vm.applyFilter(using: appState)
        await vm.loadMoreFiltered(using: appState)
        let before = api.getItemsCalls.count

        await vm.refreshUserData(using: appState)

        let issued = api.getItemsCalls.suffix(from: before)
        #expect(issued.count == 1)
        #expect(issued.first?.startIndex == 0)
        #expect(issued.first?.limit == 80, "la requête couvre toute la portée déjà paginée")
    }

    @Test("Un ensemble qui rétrécit cesse de demander la suite")
    func shrunkSetStopsPaginating() async {
        let api = makePagingAPI()
        let appState = makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)
        vm.sortFilter.showUnwatchedOnly = true

        await vm.applyFilter(using: appState)
        await vm.loadMoreFiltered(using: appState)

        // L'item vient d'être marqué vu : sous « Non vus uniquement » il quitte
        // l'ensemble, dont le total passe sous la portée déjà chargée.
        api.getItemsHandler = { _ in
            var item = BaseItemDto()
            item.id = "m0"
            return (items: [item], totalCount: 1)
        }
        await vm.refreshUserData(using: appState)

        let remaining = vm.filteredLoader.items.count
        let doneP = vm.filteredLoader.hasLoadedAll
        #expect(remaining == 1)
        #expect(doneP == true)
    }

    @Test("Sans rien de paginé, le rafraîchissement ciblé ne fait rien")
    func noOpWhenNothingPagedIn() async {
        let api = makePagingAPI()
        let appState = makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)
        vm.sortFilter.showUnwatchedOnly = true

        let before = api.getItemsCalls.count
        await vm.refreshUserData(using: appState)

        let after = api.getItemsCalls.count
        let isEmpty = vm.filteredLoader.items.isEmpty
        #expect(after == before)
        #expect(isEmpty)
    }
}
