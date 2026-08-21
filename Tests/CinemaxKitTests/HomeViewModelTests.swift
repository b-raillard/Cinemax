import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Free function so it can be called from the non-isolated `@Sendable`
/// `getEpisodesHandler` closure without crossing actor boundaries.
private func makeSeasonEpisode(id: String, name: String) -> BaseItemDto {
    var ep = BaseItemDto()
    ep.id = id
    ep.name = name
    return ep
}

@MainActor
@Suite("HomeViewModel")
struct HomeViewModelTests {

    private func makeItem(name: String) -> BaseItemDto {
        var item = BaseItemDto()
        item.name = name
        return item
    }

    private func makeAppState(api: MockAPIClient, userId: String? = "user1") -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = userId
        return appState
    }

    // MARK: - Loading

    @Test("load() without userId returns early without fetching")
    func loadWithoutUserIdIsNoop() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api, userId: nil)
        let vm = HomeViewModel()

        await vm.load(using: appState)

        // isLoading stays true (no userId → early return before setting false)
        #expect(vm.resumeItems.isEmpty)
        #expect(vm.latestItems.isEmpty)
    }

    @Test("Recently Added leads with shows that got new episodes, then new titles")
    func recentlyAddedMergesBothSources() async {
        let shows = [makeItem(name: "Arrow"), makeItem(name: "Severance")]
        let titles = [makeItem(name: "Dune"), makeItem(name: "Sinners")]

        let merged = HomeViewModel.mergeRecentlyAdded(
            showsWithNewEpisodes: shows, newTitles: titles
        )

        // A long-owned show that just got a season carries its OWN (old)
        // creation date, so it can only be surfaced by leading — sorting the
        // union by date would bury it.
        #expect(merged.map(\.name) == ["Arrow", "Severance", "Dune", "Sinners"])
    }

    @Test("A show present in both sources appears once, keeping its lead position")
    func recentlyAddedDedupesAcrossSources() async {
        var arrow = makeItem(name: "Arrow")
        arrow.id = "series-arrow"
        var arrowAgain = makeItem(name: "Arrow")
        arrowAgain.id = "series-arrow"
        var dune = makeItem(name: "Dune")
        dune.id = "movie-dune"

        let merged = HomeViewModel.mergeRecentlyAdded(
            showsWithNewEpisodes: [arrow], newTitles: [arrowAgain, dune]
        )

        #expect(merged.map(\.name) == ["Arrow", "Dune"])
    }

    @Test("New-episode shows are capped so an active TV library can't fill the row")
    func recentlyAddedCapsEpisodeShows() async {
        // The crowding this split exists to fix: episodes arrive far faster
        // than new titles, so an uncapped second source would recreate it.
        let shows = (0..<20).map { idx -> BaseItemDto in
            var item = makeItem(name: "Show \(idx)")
            item.id = "show-\(idx)"
            return item
        }
        let titles = (0..<20).map { idx -> BaseItemDto in
            var item = makeItem(name: "Title \(idx)")
            item.id = "title-\(idx)"
            return item
        }

        let merged = HomeViewModel.mergeRecentlyAdded(
            showsWithNewEpisodes: shows, newTitles: titles
        )

        #expect(merged.count == HomeViewModel.recentlyAddedLimit)
        #expect(merged.prefix(HomeViewModel.newEpisodeShowsLimit).allSatisfy { $0.name?.hasPrefix("Show") == true })
        #expect(merged.dropFirst(HomeViewModel.newEpisodeShowsLimit).allSatisfy { $0.name?.hasPrefix("Title") == true })
    }

    @Test("One failing source still populates Recently Added from the other")
    func recentlyAddedSurvivesOneSourceFailing() async {
        let api = MockAPIClient()
        api.seriesWithRecentEpisodesShouldThrow = true
        api.stubbedLatestItems = [makeItem(name: "Dune")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.latestItems.count == 1)
    }

    @Test("Recently Added asks for movies and series by date added — never raw episodes")
    func recentlyAddedQueriesMoviesAndSeriesByDateAdded() async {
        let api = MockAPIClient()
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        // The row used to call `/Items/Latest`, which scans raw items — episodes
        // included — and groups them under their series. One show's back-catalogue
        // import then filled the whole scan and collapsed into a SINGLE card, so
        // the row looked empty while faithfully reporting the newest items.
        #expect(api.getLatestMediaCallCount == 0)

        let recentlyAdded = api.getItemsQueries.first {
            $0.includeItemTypes == [.movie, .series] && $0.isFavorite == nil
        }
        #expect(recentlyAdded != nil)
        #expect(recentlyAdded?.sortBy == [.dateCreated])
        #expect(recentlyAdded?.sortOrder == [.descending])
        #expect(recentlyAdded?.limit == 20)
        // Episodes must not be requestable into this row at all — excluding them
        // by type is what makes the row's contents independent of how many
        // episodes happened to land recently.
        #expect(recentlyAdded?.includeItemTypes?.contains(.episode) == false)
    }

    @Test("load() populates resumeItems and latestItems from API")
    func loadPopulatesItems() async {
        let api = MockAPIClient()
        api.stubbedResumeItems = [makeItem(name: "Inception"), makeItem(name: "Interstellar")]
        api.stubbedLatestItems = [makeItem(name: "Dune")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.resumeItems.count == 2)
        #expect(vm.latestItems.count == 1)
        #expect(!vm.isLoading)
    }

    @Test("heroItem is set to first resumeItem when available")
    func heroItemFromResumeItems() async {
        let api = MockAPIClient()
        api.stubbedResumeItems = [makeItem(name: "Featured")]
        api.stubbedLatestItems = [makeItem(name: "Latest")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.heroItem?.name == "Featured")
    }

    @Test("heroItem falls back to latestItems when resumeItems is empty")
    func heroItemFallsBackToLatest() async {
        let api = MockAPIClient()
        api.stubbedResumeItems = []
        api.stubbedLatestItems = [makeItem(name: "Latest")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.heroItem?.name == "Latest")
    }

    @Test("load() populates nextUpItems from the global Next Up endpoint")
    func loadPopulatesNextUp() async {
        let api = MockAPIClient()
        api.stubbedNextUpItems = [makeItem(name: "S01E02"), makeItem(name: "S03E01")]
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.nextUpItems.count == 2)
        #expect(!vm.isLoading)
    }

    @Test("load() builds Next Up episode navigation with prev/next refs")
    func loadBuildsNextUpNavigation() async {
        let api = MockAPIClient()
        // Next Up surfaces episode 2 of a three-episode season.
        var nextUp = BaseItemDto()
        nextUp.id = "ep-2"
        nextUp.name = "Episode 2"
        nextUp.type = .episode
        nextUp.seasonID = "season-1"
        nextUp.seriesID = "series-1"
        api.stubbedNextUpItems = [nextUp]
        api.getEpisodesHandler = { seasonId in
            guard seasonId == "season-1" else { return [] }
            return [
                makeSeasonEpisode(id: "ep-1", name: "Episode 1"),
                makeSeasonEpisode(id: "ep-2", name: "Episode 2"),
                makeSeasonEpisode(id: "ep-3", name: "Episode 3"),
            ]
        }
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        let nav = vm.nextUpNavigation["ep-2"]
        #expect(nav != nil)
        #expect(nav?.previous?.id == "ep-1")
        #expect(nav?.next?.id == "ep-3")
        #expect(nav?.navigator != nil)
    }

    // MARK: - Défaut G : une carte arrivée par un rafraîchissement de niveau 2

    /// Trouvé en recette adversariale (« Menus contextuels `M1` »), avec
    /// contrôle apparié sur appareil : le même épisode, sur la même carte de
    /// « Reprendre », donnait **3** boutons de transport lancé par appui simple
    /// et **5** lancé depuis le menu contextuel — et **5** par appui simple une
    /// fois l'Accueil rechargé en entier.
    ///
    /// `load()` construit les deux cartes de navigation en une passe ; tout ce
    /// qui entre dans un rail APRÈS, via `refreshUserDataRails`, n'en avait
    /// aucune. Or c'est le chemin ordinaire : finir un épisode poste la
    /// notification de niveau 2, les rails se refetchent, et la carte
    /// fraîchement arrivée est précisément celle que l'utilisateur touche
    /// ensuite. Un navigateur nul ne coûte pas que deux boutons — il coupe
    /// aussi l'enchaînement automatique et la carte de fin de série.
    @Test("Une carte entrée dans « Reprendre » par le niveau 2 reçoit sa navigation")
    func tierTwoRefreshFillsMissingResumeNavigation() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { seasonId in
            guard seasonId == "season-1" else { return [] }
            return [
                makeSeasonEpisode(id: "ep-1", name: "Episode 1"),
                makeSeasonEpisode(id: "ep-2", name: "Episode 2"),
                makeSeasonEpisode(id: "ep-3", name: "Episode 3"),
            ]
        }
        let vm = HomeViewModel()
        let appState = makeAppState(api: api)

        // Chargement initial : le rail est vide, donc aucune navigation.
        await vm.load(using: appState)
        #expect(vm.resumeNavigation.isEmpty)

        // L'épisode arrive dans « Reprendre » — exactement ce que produit un
        // arrêt de lecture, qui poste la notification de niveau 2.
        var ep = BaseItemDto()
        ep.id = "ep-2"
        ep.name = "Episode 2"
        ep.type = .episode
        ep.seasonID = "season-1"
        ep.seriesID = "series-1"
        api.stubbedResumeItems = [ep]

        await vm.refreshUserDataRails(using: appState)

        let nav = vm.resumeNavigation["ep-2"]
        let prev = nav?.previous?.id
        let next = nav?.next?.id
        #expect(nav != nil, "la carte fraîchement arrivée doit porter sa navigation")
        #expect(prev == "ep-1")
        #expect(next == "ep-3")
        #expect(nav?.navigator != nil, "sans navigateur, ni enchaînement ni carte de fin")
    }

    @Test("Le rail « À suivre » est couvert de la même façon")
    func tierTwoRefreshFillsMissingNextUpNavigation() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { seasonId in
            seasonId == "season-9" ? [
                makeSeasonEpisode(id: "e1", name: "E1"),
                makeSeasonEpisode(id: "e2", name: "E2"),
            ] : []
        }
        let vm = HomeViewModel()
        let appState = makeAppState(api: api)
        await vm.load(using: appState)

        var ep = BaseItemDto()
        ep.id = "e1"
        ep.type = .episode
        ep.seasonID = "season-9"
        ep.seriesID = "series-9"
        api.stubbedNextUpItems = [ep]

        await vm.refreshUserDataRails(using: appState)

        let nav = vm.nextUpNavigation["e1"]
        let next = nav?.next?.id
        #expect(nav != nil)
        #expect(next == "e2")
    }

    /// Le remplissage est volontairement borné aux entrées MANQUANTES : une
    /// entrée existante reste valable (la navigation dépend de la liste des
    /// épisodes de la saison, pas des données utilisateur de la carte), donc
    /// re-dériver toute la carte à chaque bascule « vu » de l'application
    /// re-demanderait chaque saison pour rien.
    @Test("Rien de nouveau dans les rails : aucune requête d'épisodes")
    func tierTwoRefreshIssuesNoRequestWhenNothingIsMissing() async {
        let api = MockAPIClient()
        var ep = BaseItemDto()
        ep.id = "ep-2"
        ep.type = .episode
        ep.seasonID = "season-1"
        ep.seriesID = "series-1"
        api.stubbedResumeItems = [ep]
        api.getEpisodesHandler = { _ in
            [makeSeasonEpisode(id: "ep-1", name: "E1"), makeSeasonEpisode(id: "ep-2", name: "E2")]
        }
        let vm = HomeViewModel()
        let appState = makeAppState(api: api)

        await vm.load(using: appState)
        #expect(vm.resumeNavigation["ep-2"] != nil, "pré-condition : la navigation existe déjà")
        let before = api.getEpisodesCallCount

        await vm.refreshUserDataRails(using: appState)

        #expect(api.getEpisodesCallCount == before, "aucune saison re-demandée")
    }

    @Test("Next Up fetch failure leaves nextUpItems empty without failing the load")
    func nextUpFailureIsIsolated() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.nextUpItems.isEmpty)
        #expect(!vm.isLoading)
    }

    @Test("API failures leave collections empty and set isLoading false")
    func apiFailureLeavesCollectionsEmpty() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let vm = HomeViewModel()

        await vm.load(using: makeAppState(api: api))

        #expect(vm.resumeItems.isEmpty)
        #expect(vm.latestItems.isEmpty)
        #expect(!vm.isLoading)
    }

    // MARK: - Targeted userData refresh

    @Test("refreshUserDataRails re-fetches only resume/nextUp/favorites, not genre/latest")
    func refreshUserDataRailsIsTargeted() async {
        let api = MockAPIClient()
        api.stubbedResumeItems = [makeItem(name: "Resuming")]
        api.stubbedNextUpItems = [makeItem(name: "NextUp")]
        let vm = HomeViewModel()

        await vm.refreshUserDataRails(using: makeAppState(api: api))

        // Hit exactly the three userData rails, once each.
        #expect(api.getResumeItemsCallCount == 1)
        #expect(api.getNextUpEpisodesCallCount == 1)
        #expect(api.favoriteFetchCount == 1)
        // Left the heavy catalogue fetches untouched.
        #expect(api.getLatestMediaCallCount == 0)
        #expect(api.getGenresCallCount == 0)
        // And the rails reflect server truth.
        #expect(vm.resumeItems.count == 1)
        #expect(vm.nextUpItems.count == 1)
    }

    // MARK: - Genre retry (stale-index regression)
    //
    // `retryGenre` suspends on the fetch; `genreRows` can be emptied or
    // reordered meanwhile (pull-to-refresh, a genre-selection change, another
    // retry chip). Reusing the pre-await index crashed with "Index out of
    // range" or wrote into the wrong row.

    @Test("retryGenre bails silently when its row disappears during the fetch")
    func retryGenreRowRemovedMidFlight() async {
        let api = MockAPIClient()
        let vm = HomeViewModel()
        vm.genreRows = [GenreRow(genre: "Action", state: .failed),
                        GenreRow(genre: "Comedy", state: .failed)]
        // Runs while `retryGenre` is suspended — same effect as a concurrent
        // `loadGenreRows` wiping the rows.
        api.getItemsHandler = { _ in
            await MainActor.run { vm.genreRows = [] }
            return ([], 0)
        }

        await vm.retryGenre("Action", using: makeAppState(api: api))

        #expect(vm.genreRows.isEmpty)
    }

    @Test("retryGenre re-resolves the index when rows shift during the fetch")
    func retryGenreIndexShiftsMidFlight() async {
        let api = MockAPIClient()
        let vm = HomeViewModel()
        vm.genreRows = [GenreRow(genre: "Action", state: .failed),
                        GenreRow(genre: "Comedy", state: .failed),
                        GenreRow(genre: "Drama", state: .failed)]
        // Drop the row ahead of the retried one: "Drama" moves from index 2 to 1
        // and the old index would now be out of bounds.
        api.getItemsHandler = { _ in
            await MainActor.run { vm.genreRows.removeFirst() }
            return ([makeSeasonEpisode(id: "d1", name: "Dramatic")], 1)
        }

        await vm.retryGenre("Drama", using: makeAppState(api: api))

        #expect(vm.genreRows.map(\.genre) == ["Comedy", "Drama"])
        #expect(vm.genreRows.first(where: { $0.genre == "Drama" })?.state != .failed)
        #expect(vm.genreRows.first(where: { $0.genre == "Comedy" })?.state == .failed)
    }

    @Test("retryGenre no-ops when the genre isn't in genreRows at all")
    func retryGenreUnknownGenre() async {
        let api = MockAPIClient()
        let vm = HomeViewModel()
        vm.genreRows = [GenreRow(genre: "Action", state: .failed)]

        await vm.retryGenre("Comedy", using: makeAppState(api: api))

        #expect(vm.genreRows.count == 1)
        #expect(vm.genreRows[0].state == .failed)
        #expect(api.getItemsCalls.isEmpty)
    }
}

/// Tri-state sentinel: a missing/empty `home.selectedGenres` string means
/// "never configured" (→ deterministic default prefix) while an explicit `[]`
/// means "configured, zero rows". Locks that empty-string ≠ empty-array.
@Suite("HomeGenrePreferences", .serialized)
struct HomeGenrePreferencesTests {

    private let key = SettingsKey.homeSelectedGenres

    private func clear() { UserDefaults.standard.removeObject(forKey: key) }

    @Test("missing key → not configured, renders the default prefix")
    func unconfiguredMissing() {
        clear(); defer { clear() }
        #expect(HomeGenrePreferences.isConfigured() == false)
        let available = ["Action", "Comedy", "Drama", "Fantasy", "Horror", "Mystery", "Romance"]
        #expect(HomeGenrePreferences.effectiveGenres(available: available)
                == Array(available.prefix(HomeGenrePreferences.defaultRowCount)))
    }

    @Test("empty-string value is still treated as unconfigured")
    func emptyStringUnconfigured() {
        clear(); defer { clear() }
        UserDefaults.standard.set("", forKey: key)
        #expect(HomeGenrePreferences.isConfigured() == false)
        #expect(HomeGenrePreferences.effectiveGenres(available: ["Action", "Comedy"]) == ["Action", "Comedy"])
    }

    @Test("explicit empty array is configured and yields zero rows")
    func explicitEmptyArray() {
        clear(); defer { clear() }
        HomeGenrePreferences.setSelectedGenres([])
        #expect(HomeGenrePreferences.isConfigured() == true)
        #expect(HomeGenrePreferences.effectiveGenres(available: ["Action", "Comedy"]).isEmpty)
    }

    @Test("explicit picks intersect availability and follow canonical order")
    func explicitPicks() {
        clear(); defer { clear() }
        HomeGenrePreferences.setSelectedGenres(["Horror", "Action", "Unavailable"])
        #expect(HomeGenrePreferences.isConfigured() == true)
        let available = ["Action", "Comedy", "Drama", "Horror"]
        #expect(HomeGenrePreferences.effectiveGenres(available: available) == ["Action", "Horror"])
    }
}
