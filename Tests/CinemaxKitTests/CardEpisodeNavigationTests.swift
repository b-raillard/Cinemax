import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Verrouille le défaut « Lecteur `L12` », trouvé en recette adversariale le
/// 2026-08-21 et confirmé par un contrôle apparié sur appareil : le **même**
/// épisode (« Épisode 2 » de *Le Flambeau*, saison de 6) affichait **3**
/// boutons de transport lancé depuis la Recherche et **5** lancé depuis la
/// fiche de la série.
///
/// La cause était unique et lisible dans le code : seuls les deux rails de
/// l'Accueil passent `navigation:` à `.mediaCardContextMenu`. `SearchScreen`
/// et `WatchedHistoryScreen` — les deux autres surfaces qui affichent des
/// cartes d'ÉPISODE — ne le passaient pas, donc `previousEpisode`,
/// `nextEpisode` **et** `episodeNavigator` arrivaient nuls au lecteur. Ce
/// n'est pas qu'une affaire de boutons : `handlePlaybackEnded` conditionne
/// l'enchaînement à `nextEpisode != nil && episodeNavigator != nil`, et la
/// carte « Vous avez terminé… » au seul navigateur — un épisode lancé depuis
/// la Recherche se terminait donc dans le silence complet.
@Suite("Navigation d'épisodes depuis une carte")
struct CardEpisodeNavigationTests {

    private func makeEpisode(id: String, name: String) -> BaseItemDto {
        var ep = BaseItemDto()
        ep.id = id
        ep.name = name
        return ep
    }

    private func season(of count: Int) -> [BaseItemDto] {
        (1...count).map { makeEpisode(id: "e\($0)", name: "Épisode \($0)") }
    }

    // MARK: - Le cas du défaut

    @Test("Un épisode du milieu de saison reçoit ses deux voisins")
    func middleEpisodeGetsBothNeighbours() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in self.season(of: 6) }

        let nav = await CardEpisodeNavigationResolver.resolve(
            episodeId: "e2", seriesId: "s1", seasonId: "sea1",
            api: api, userId: "u1"
        )

        // `BaseItemDto` n'est pas Sendable : on extrait avant `#expect`, dont
        // la macro capture les sous-expressions.
        let prev = nav?.previous?.id
        let next = nav?.next?.id
        #expect(prev == "e1")
        #expect(next == "e3")
        #expect(nav?.navigator != nil)
        // La saison est déjà connue de la carte : une seule requête, et aucun
        // `getItem` préalable.
        #expect(api.getEpisodesCallCount == 1)
        #expect(api.getItemCallCount == 0)
    }

    @Test("Le navigateur décrit les voisins de N'IMPORTE quel épisode de la saison")
    func navigatorCoversTheWholeSeason() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in self.season(of: 4) }

        let nav = await CardEpisodeNavigationResolver.resolve(
            episodeId: "e2", seriesId: "s1", seasonId: "sea1",
            api: api, userId: "u1"
        )

        // C'est ce que `refreshEpisodeButtons()` consomme à chaque transition :
        // sans navigateur, les boutons ne peuvent pas suivre.
        guard let navigator = nav?.navigator else {
            Issue.record("navigateur absent")
            return
        }
        let atLast = navigator("e4")
        let atFirst = navigator("e1")
        #expect(atLast?.0?.id == "e3")
        #expect(atLast?.1 == nil, "le dernier épisode n'a pas de suivant")
        #expect(atFirst?.0 == nil, "le premier épisode n'a pas de précédent")
        #expect(atFirst?.1?.id == "e2")
    }

    @Test("Premier et dernier épisode : un seul voisin chacun")
    func edgesGetOneNeighbour() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in self.season(of: 3) }

        let first = await CardEpisodeNavigationResolver.resolve(
            episodeId: "e1", seriesId: "s1", seasonId: "sea1", api: api, userId: "u1")
        let last = await CardEpisodeNavigationResolver.resolve(
            episodeId: "e3", seriesId: "s1", seasonId: "sea1", api: api, userId: "u1")

        let firstPrev = first?.previous
        let firstNext = first?.next?.id
        let lastPrev = last?.previous?.id
        let lastNext = last?.next
        #expect(firstPrev == nil)
        #expect(firstNext == "e2")
        #expect(lastPrev == "e2")
        #expect(lastNext == nil)
    }

    // MARK: - La saison inconnue de la carte

    @Test("Saison absente de la carte : un getItem la retrouve")
    func missingSeasonIsLookedUp() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in
            var ep = BaseItemDto()
            ep.id = id
            ep.seriesID = "s1"
            ep.seasonID = "sea1"
            return ep
        }
        api.getEpisodesHandler = { seasonId in
            seasonId == "sea1" ? self.season(of: 5) : []
        }

        let nav = await CardEpisodeNavigationResolver.resolve(
            episodeId: "e3", seriesId: nil, seasonId: nil,
            api: api, userId: "u1"
        )

        let prev = nav?.previous?.id
        let next = nav?.next?.id
        #expect(prev == "e2")
        #expect(next == "e4")
        #expect(api.getItemCallCount == 1)
    }

    /// Le cas d'une carte de SÉRIE dont le sondage next-up a expiré : la cible
    /// reste l'id de la série, `getItem` ne rend aucune saison, et la
    /// résolution doit s'arrêter là — proprement, sans demander d'épisodes.
    @Test("Cible sans saison : nil, et aucune requête d'épisodes")
    func noSeasonYieldsNil() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in
            var item = BaseItemDto()
            item.id = id
            return item // ni seriesID ni seasonID
        }

        let nav = await CardEpisodeNavigationResolver.resolve(
            episodeId: "s1", seriesId: nil, seasonId: nil,
            api: api, userId: "u1"
        )

        #expect(nav == nil)
        #expect(api.getEpisodesCallCount == 0)
    }

    // MARK: - Dégradations : toutes rendent l'ancien comportement, jamais une erreur

    @Test("Saison à un seul épisode : pas de navigation à annoncer")
    func singleEpisodeSeasonYieldsNil() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in self.season(of: 1) }

        let nav = await CardEpisodeNavigationResolver.resolve(
            episodeId: "e1", seriesId: "s1", seasonId: "sea1",
            api: api, userId: "u1"
        )
        #expect(nav == nil)
    }

    @Test("Épisode absent de la saison rendue : nil plutôt qu'une navigation fausse")
    func unknownEpisodeYieldsNil() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in self.season(of: 4) }

        let nav = await CardEpisodeNavigationResolver.resolve(
            episodeId: "e99", seriesId: "s1", seasonId: "sea1",
            api: api, userId: "u1"
        )
        #expect(nav == nil)
    }

    @Test("Requête d'épisodes en échec : nil, la lecture démarre quand même")
    func failedFetchYieldsNil() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in throw URLError(.notConnectedToInternet) }

        let nav = await CardEpisodeNavigationResolver.resolve(
            episodeId: "e2", seriesId: "s1", seasonId: "sea1",
            api: api, userId: "u1"
        )
        #expect(nav == nil)
    }

    // MARK: - Le délai est un vrai délai

    /// Même exigence que `CardPlayTargetTests.seriesNextUpDeadlineIsEnforced`,
    /// et pour la même raison : « Lecture » n'offre aucun retour de chargement,
    /// et avant ce résolveur l'appui ouvrait le lecteur immédiatement. Un
    /// serveur lent doit coûter les boutons d'épisode, jamais transformer le
    /// bouton en bouton mort. Une assertion sur le seul résultat ne
    /// discriminerait pas : `nil` est aussi ce que rend une attente complète.
    @Test("Le délai rend la main sans attendre la saison")
    func deadlineIsEnforced() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in
            try? await Task.sleep(for: .seconds(3))
            return self.season(of: 6)
        }

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            let nav = await CardEpisodeNavigationResolver.resolve(
                episodeId: "e2", seriesId: "s1", seasonId: "sea1",
                api: api, userId: "u1",
                probeDeadline: .milliseconds(50)
            )
            #expect(nav == nil)
        }

        // Large face au bruit d'ordonnancement de la CI, tout en restant un
        // ordre de grandeur sous les 3 s : échoue net si la saison est attendue.
        #expect(elapsed < .milliseconds(1000))
    }

    /// Le perdant n'est pas annulé, exactement comme le sondage next-up :
    /// `getEpisodes` ne remplit son cache de 10 s (`episodes-`) qu'une fois la
    /// réponse arrivée, donc l'annuler transformerait une expiration isolée en
    /// expiration répétée — sur la saison que l'utilisateur est justement en
    /// train de regarder.
    @Test("La requête perdante va au bout et réchauffe le cache")
    func losingProbeStillCompletes() async {
        let api = MockAPIClient()
        let completions = Completions()
        api.getEpisodesHandler = { _ in
            try? await Task.sleep(for: .milliseconds(100))
            await completions.record()
            return self.season(of: 6)
        }

        _ = await CardEpisodeNavigationResolver.resolve(
            episodeId: "e2", seriesId: "s1", seasonId: "sea1",
            api: api, userId: "u1",
            probeDeadline: .milliseconds(10)
        )

        // Laisser à la tâche détachée le temps de dépasser son sommeil de
        // 100 ms. Compter avant serait instable : avec un délai de 10 ms, la
        // résolution peut rendre la main avant même que la tâche soit planifiée.
        try? await Task.sleep(for: .milliseconds(600))
        let count = await completions.count
        #expect(count == 1, "annulée, la requête n'aurait jamais abouti")
    }

    /// Compteur d'achèvements, isolé par un acteur — le corps du handler
    /// s'exécute hors de l'acteur principal.
    private actor Completions {
        private(set) var count = 0
        func record() { count += 1 }
    }
}
