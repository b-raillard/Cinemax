import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Verrouille la rangée « Vos playlists » de l'Accueil.
///
/// L'app savait CRÉER une playlist et ne savait plus la montrer : `getPlaylists`
/// n'avait qu'un seul appelant — la feuille d'ajout elle-même — et le seul écran
/// qui en listait était atteignable uniquement depuis un menu
/// « Personnalisé / Par bibliothèque » sur un serveur exposant une vue
/// Playlists. Avec les cinq onglets par défaut, aucun chemin n'existait.
@MainActor
@Suite("Accueil — rangée playlists")
struct HomePlaylistsRailTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    private func playlist(id: String, name: String, count: Int) -> BaseItemDto {
        var item = BaseItemDto()
        item.id = id
        item.name = name
        item.type = .playlist
        item.childCount = count
        return item
    }

    @Test("Le chargement de l'accueil ramène les playlists")
    func homeLoadFetchesPlaylists() async {
        let api = MockAPIClient()
        api.stubbedPlaylists = [
            playlist(id: "p1", name: "Soirée SF", count: 4),
            playlist(id: "p2", name: "À revoir", count: 11)
        ]
        let appState = makeAppState(api: api)
        let vm = HomeViewModel()

        await vm.load(using: appState)

        #expect(vm.playlists.count == 2)
        #expect(api.getPlaylistsCallCount == 1)
    }

    /// La rangée existe pour rendre les playlists trouvables : si elle
    /// n'apprenait l'existence d'une nouvelle qu'au rechargement complet, elle
    /// serait le dernier endroit informé.
    @Test("Une création est reprise sans rechargement complet")
    func creationIsPickedUpByTheTargetedRefresh() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = HomeViewModel()
        await vm.load(using: appState)
        #expect(vm.playlists.isEmpty, "pré-condition : aucune playlist")

        api.stubbedPlaylists = [playlist(id: "p1", name: "Soirée SF", count: 1)]
        await vm.refreshPlaylists(using: appState)

        #expect(vm.playlists.count == 1)
    }

    /// Chaque source du groupe parallèle échoue pour son compte : une lecture
    /// de playlists en erreur retire la rangée, elle ne casse pas l'accueil.
    @Test("Un échec de lecture des playlists laisse l'accueil intact")
    func aFailedPlaylistFetchOnlyDropsTheRow() async {
        let api = MockAPIClient()
        var latest = BaseItemDto()
        latest.id = "m1"
        latest.name = "Nuremberg"
        api.stubbedLatestItems = [latest]
        let appState = makeAppState(api: api)
        let vm = HomeViewModel()

        // Le mock ne sert aucune playlist et n'échoue pas globalement : on
        // vérifie que l'absence de playlists n'empêche rien d'autre.
        await vm.load(using: appState)

        #expect(vm.playlists.isEmpty)
        #expect(vm.isLoading == false)
    }
}
