import Testing
import Foundation
@preconcurrency import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Verrouille la cause racine du bug A7 (« la carte *Vous avez terminé …*
/// manque en fin de série »).
///
/// Trace relevée sur appareil le 2026-08-12, en fin naturelle d'épisode :
///
///     end-gate .stopped … currentMs=1438478 lengthMs=1438656
///     end-branch autoPlayNext=true nextUpCancelled=false hasNext=false hasNavigator=false
///
/// Le portillon de fin passe (178 ms d'écart) : la cause est en aval, dans
/// `handlePlaybackEnded`, qui exige `episodeNavigator != nil` pour afficher la
/// carte et se contente sinon de fermer le lecteur — sans carte, sans erreur.
/// Le navigateur était nil parce que le héros de la bibliothèque lançait
/// `PlayLink(itemId:title:)` sans rien d'autre, là où l'Accueil, la fiche et
/// les menus de vignettes passent tous une navigation d'épisodes. Contrôle
/// inverse mesuré depuis le rail « Reprendre » de l'Accueil : `hasNavigator=true`.
///
/// Conséquence secondaire du même manque : pas de boutons épisode précédent /
/// suivant dans le lecteur sur ce chemin.
/// Free (non-isolated) helpers so the `@Sendable` `MockAPIClient` handler
/// closures can call them without an `await` — same reason as
/// `FavoritesViewModelTests`.
private func makeHeroEpisode(
    id: String,
    index: Int,
    seasonId: String,
    positionTicks: Int = 0,
    isPlayed: Bool = false
) -> BaseItemDto {
    var ep = BaseItemDto()
    ep.id = id
    ep.name = "Épisode \(index)"
    ep.indexNumber = index
    ep.seasonID = seasonId
    ep.seriesID = "series1"
    var data = UserItemDataDto()
    data.playbackPositionTicks = positionTicks
    data.isPlayed = isPlayed
    ep.userData = data
    return ep
}

private func makeHeroSeason() -> [BaseItemDto] {
    [makeHeroEpisode(id: "ep1", index: 1, seasonId: "s1"),
     makeHeroEpisode(id: "ep2", index: 2, seasonId: "s1"),
     makeHeroEpisode(id: "ep3", index: 3, seasonId: "s1")]
}

private func makeSeriesHeroItem() -> BaseItemDto {
    var series = BaseItemDto()
    series.id = "series1"
    series.name = "Une série"
    series.type = .series
    return series
}

@MainActor
@Suite("Héros de bibliothèque — navigation d'épisodes")
struct LibraryHeroNavigationTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    @Test("Un héros série expose l'épisode à lire et sa navigation")
    func seriesHeroResolvesNavigation() async {
        let api = MockAPIClient()
        api.stubbedNextUp = makeHeroEpisode(id: "ep2", index: 2, seasonId: "s1")
        api.getEpisodesHandler = { _ in makeHeroSeason() }

        let vm = MediaLibraryViewModel(itemType: .series)
        vm.heroItem = makeSeriesHeroItem()
        await vm.loadHeroNavigation(using: makeAppState(api: api))

        let play = vm.heroPlay
        #expect(play?.itemId == "ep2", "le héros doit lancer l'épisode next-up, pas la série")
        #expect(play?.navigator != nil, "sans navigateur, pas de carte de fin de série")
        #expect(play?.previous?.id == "ep1")
        #expect(play?.next?.id == "ep3")
    }

    @Test("Dernier épisode : navigateur présent, pas d'épisode suivant")
    func lastEpisodeStillHasNavigator() async {
        // C'est exactement la configuration du bug : `hasNext=false` mais le
        // navigateur DOIT exister, sinon `handlePlaybackEnded` ferme le lecteur
        // au lieu d'afficher la carte.
        let api = MockAPIClient()
        api.stubbedNextUp = makeHeroEpisode(id: "ep3", index: 3, seasonId: "s1")
        api.getEpisodesHandler = { _ in makeHeroSeason() }

        let vm = MediaLibraryViewModel(itemType: .series)
        vm.heroItem = makeSeriesHeroItem()
        await vm.loadHeroNavigation(using: makeAppState(api: api))

        let play = vm.heroPlay
        #expect(play?.itemId == "ep3")
        #expect(play?.next == nil)
        #expect(play?.navigator != nil)
    }

    @Test("Série entièrement vue : repli sur le premier épisode, navigateur présent")
    func fullyWatchedSeriesFallsBackToFirstEpisode() async {
        // Relevé sur appareil : après avoir regardé toute la série, `getNextUp`
        // renvoie nil (`hero-nav no next-up … gotEpisode=false`). Le serveur,
        // lui, sait quoi lire — `resolvePlayableEpisode` = next-up d'abord,
        // **sinon le premier épisode de la première saison**. Sans ce repli, le
        // héros relançait la série sans navigateur : le bug A7 restait entier
        // pour toute série terminée, soit exactement le cas où l'on atteint une
        // fin de série.
        let api = MockAPIClient()
        api.stubbedNextUp = nil
        api.getSeasonsHandler = { _ in
            var season = BaseItemDto()
            season.id = "s1"
            season.indexNumber = 1
            return [season]
        }
        api.getEpisodesHandler = { _ in makeHeroSeason() }

        let vm = MediaLibraryViewModel(itemType: .series)
        vm.heroItem = makeSeriesHeroItem()
        await vm.loadHeroNavigation(using: makeAppState(api: api))

        let play = vm.heroPlay
        #expect(play?.itemId == "ep1", "le repli doit viser le premier épisode, comme le serveur")
        #expect(play?.navigator != nil)
        #expect(play?.previous == nil)
        #expect(play?.next?.id == "ep2")
    }

    @Test("Un héros film ne déclenche aucune requête d'épisodes")
    func movieHeroDoesNotProbe() async {
        let api = MockAPIClient()
        var movie = BaseItemDto()
        movie.id = "m1"
        movie.name = "Un film"
        movie.type = .movie

        let vm = MediaLibraryViewModel(itemType: .movie)
        vm.heroItem = movie
        await vm.loadHeroNavigation(using: makeAppState(api: api))

        let nextUpCalls = api.getNextUpCallCount
        let episodeCalls = api.getEpisodesCallCount
        #expect(nextUpCalls == 0)
        #expect(episodeCalls == 0)
        #expect(vm.heroPlay == nil, "un film n'a pas de navigation d'épisodes")
    }

    @Test("Une sonde en échec dégrade sans casser le héros")
    func failedProbeDegradesSilently() async {
        // Même discipline que `loadRemoteTargets` : ne pas avoir de navigation
        // est le cas ordinaire (série sans next-up), donc l'échec retire le
        // bonus, il ne remonte pas d'erreur.
        let api = MockAPIClient()
        api.nextUpShouldThrow = true
        api.stubbedError = URLError(.timedOut)

        let vm = MediaLibraryViewModel(itemType: .series)
        vm.heroItem = makeSeriesHeroItem()
        await vm.loadHeroNavigation(using: makeAppState(api: api))

        let play = vm.heroPlay
        let error = vm.errorMessage
        #expect(play == nil)
        #expect(error == nil, "une sonde ratée ne doit pas remplacer le héros par une erreur")
    }

    // MARK: - Re-dérivation après lecture (recette adversariale du 2026-08-14)

    /// `heroPlay` n'avait qu'un seul écrivain — la tâche annexe de
    /// `performLoad` — et rien ne le revisitait : la fermeture du lecteur ne
    /// poste aucune des deux notifications de rafraîchissement, et `.task` est
    /// verrouillée par `hasLoaded`. Mesuré sur appareil : après avoir regardé
    /// l'épisode 2 jusqu'à 2:02 puis fermé le lecteur, « Lecture » sur le même
    /// héros rouvrait l'épisode 1 à 0:01 / -23:57.

    @Test("Retour sur l'écran : la cible du héros suit le next-up qui a bougé")
    func heroTargetFollowsMovedNextUp() async {
        let api = MockAPIClient()
        api.stubbedNextUp = makeHeroEpisode(id: "ep2", index: 2, seasonId: "s1")
        api.getEpisodesHandler = { _ in makeHeroSeason() }

        let vm = MediaLibraryViewModel(itemType: .series)
        vm.heroItem = makeSeriesHeroItem()
        let appState = makeAppState(api: api)
        await vm.loadHeroNavigation(using: appState)
        #expect(vm.heroPlay?.itemId == "ep2", "état de départ")

        // L'utilisateur regarde l'épisode 2 en entier : le serveur avance son
        // next-up sur l'épisode 3.
        api.stubbedNextUp = makeHeroEpisode(id: "ep3", index: 3, seasonId: "s1")
        await vm.refreshHeroNavigation(using: appState)

        let play = vm.heroPlay
        #expect(play?.itemId == "ep3", "la cible du héros doit suivre le next-up, pas rester figée au chargement de la page")
        #expect(play?.previous?.id == "ep2")
        #expect(play?.next == nil)
    }

    @Test("Retour sur l'écran : la position de reprise du héros est réactualisée")
    func heroResumeOffsetIsRefreshed() async {
        let api = MockAPIClient()
        api.stubbedNextUp = makeHeroEpisode(id: "ep2", index: 2, seasonId: "s1")
        api.getEpisodesHandler = { _ in makeHeroSeason() }

        let vm = MediaLibraryViewModel(itemType: .series)
        vm.heroItem = makeSeriesHeroItem()
        let appState = makeAppState(api: api)
        await vm.loadHeroNavigation(using: appState)
        #expect(vm.heroPlay?.startSeconds == nil, "épisode vierge : aucune reprise")

        // 2 min 02 de visionnage sur ce même épisode.
        api.getEpisodesHandler = { _ in
            [makeHeroEpisode(id: "ep1", index: 1, seasonId: "s1"),
             makeHeroEpisode(id: "ep2", index: 2, seasonId: "s1", positionTicks: 1_220_000_000),
             makeHeroEpisode(id: "ep3", index: 3, seasonId: "s1")]
        }
        await vm.refreshHeroNavigation(using: appState)

        #expect(vm.heroPlay?.itemId == "ep2")
        #expect(vm.heroPlay?.startSeconds == 122, "la relance doit reprendre où l'on s'est arrêté, pas repartir à 0:00")
    }

    @Test("Sans héros chargé, la re-dérivation ne sonde rien")
    func refreshWithoutHeroDoesNotProbe() async {
        // Appelée depuis `.onAppear`, elle peut partir pendant que le premier
        // chargement est encore en vol : elle doit alors être un pur no-op.
        let api = MockAPIClient()
        let vm = MediaLibraryViewModel(itemType: .series)

        await vm.refreshHeroNavigation(using: makeAppState(api: api))

        let nextUpCalls = api.getNextUpCallCount
        #expect(nextUpCalls == 0)
        #expect(vm.heroPlay == nil)
    }

    @Test("Héros film : la re-dérivation ne sonde rien")
    func refreshOnMovieHeroDoesNotProbe() async {
        // L'onglet Films appelle le même point d'entrée à chaque retour sur
        // l'écran : il ne doit rien coûter.
        let api = MockAPIClient()
        var movie = BaseItemDto()
        movie.id = "m1"
        movie.type = .movie

        let vm = MediaLibraryViewModel(itemType: .movie)
        vm.heroItem = movie
        await vm.refreshHeroNavigation(using: makeAppState(api: api))

        let nextUpCalls = api.getNextUpCallCount
        let episodeCalls = api.getEpisodesCallCount
        #expect(nextUpCalls == 0)
        #expect(episodeCalls == 0)
    }
}
