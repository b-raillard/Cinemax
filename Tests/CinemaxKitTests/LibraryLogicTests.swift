import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

// MARK: - LibrarySortFilterState

@Suite("LibrarySortFilterState")
struct LibrarySortFilterStateTests {

    @Test("expandedYears expands each selected decade into its 10 years, sorted")
    func expandedYearsTwoDecades() {
        var state = LibrarySortFilterState()
        state.selectedDecades = [2000, 1980] // insertion order must not matter

        let years = state.expandedYears
        #expect(years == Array(1980...1989) + Array(2000...2009))
        #expect(years?.count == 20)
    }

    @Test("expandedYears is nil when no decade is selected")
    func expandedYearsEmpty() {
        let state = LibrarySortFilterState()
        #expect(state.selectedDecades.isEmpty)
        #expect(state.expandedYears == nil)
    }

    @Test("default state is neither filtered nor non-default")
    func defaultState() {
        let state = LibrarySortFilterState()
        #expect(!state.isFiltered)
        #expect(!state.isNonDefault)
    }

    @Test("sort-only changes flip isNonDefault but not isFiltered")
    func sortOnlyChanges() {
        var state = LibrarySortFilterState()
        state.sortBy = .sortName
        #expect(!state.isFiltered)
        #expect(state.isNonDefault)

        state = LibrarySortFilterState()
        state.sortAscending = true
        #expect(!state.isFiltered)
        #expect(state.isNonDefault)
    }

    @Test("genre / unwatched / decade filters flip both isFiltered and isNonDefault")
    func filterChanges() {
        var state = LibrarySortFilterState()
        state.selectedGenres = ["Action"]
        #expect(state.isFiltered)
        #expect(state.isNonDefault)

        state = LibrarySortFilterState()
        state.showUnwatchedOnly = true
        #expect(state.isFiltered)
        #expect(state.isNonDefault)

        state = LibrarySortFilterState()
        state.selectedDecades = [1990]
        #expect(state.isFiltered)
        #expect(state.isNonDefault)
    }
}

// MARK: - Episode navigation (free functions in PlayLink.swift)

@Suite("Episode navigation")
struct EpisodeNavigationTests {

    private func makeEpisode(id: String?, name: String) -> BaseItemDto {
        var ep = BaseItemDto()
        ep.id = id
        ep.name = name
        return ep
    }

    private var episodes: [BaseItemDto] {
        [
            makeEpisode(id: "ep-1", name: "One"),
            makeEpisode(id: "ep-2", name: "Two"),
            makeEpisode(id: "ep-3", name: "Three")
        ]
    }

    @Test("first episode has no previous, last has no next, middle has both")
    func neighbors() {
        let first = buildEpisodeNavigation(for: "ep-1", in: episodes)
        #expect(first.previous == nil)
        #expect(first.next?.id == "ep-2")
        #expect(first.navigator != nil)

        let middle = buildEpisodeNavigation(for: "ep-2", in: episodes)
        #expect(middle.previous?.id == "ep-1")
        #expect(middle.next?.id == "ep-3")
        #expect(middle.navigator != nil)

        let last = buildEpisodeNavigation(for: "ep-3", in: episodes)
        #expect(last.previous?.id == "ep-2")
        #expect(last.next == nil)
        #expect(last.navigator != nil)
    }

    @Test("unknown episode id yields nils")
    func unknownID() {
        let nav = buildEpisodeNavigation(for: "nope", in: episodes)
        #expect(nav.previous == nil)
        #expect(nav.next == nil)
        #expect(nav.navigator == nil)
    }

    @Test("single-episode season yields nil/nil even for the present episode")
    func singleEpisode() {
        let only = [makeEpisode(id: "ep-1", name: "One")]
        let nav = buildEpisodeNavigation(for: "ep-1", in: only)
        #expect(nav.previous == nil)
        #expect(nav.next == nil)
        #expect(nav.navigator == nil)
    }

    @Test("precomputeEpisodeRefs skips episodes without an id")
    func precomputeSkipsNilIDs() {
        let list = [
            makeEpisode(id: "ep-1", name: "One"),
            makeEpisode(id: nil, name: "Ghost"),
            makeEpisode(id: "ep-2", name: "Two")
        ]
        let (refs, indexByID) = precomputeEpisodeRefs(list)
        #expect(refs.map(\.id) == ["ep-1", "ep-2"])
        #expect(refs.map(\.title) == ["One", "Two"])
        #expect(indexByID == ["ep-1": 0, "ep-2": 1])
    }

    /// The navigator is a PURE neighbor lookup — and that is enforced by its
    /// type, not by this test: `EpisodeNavigator` is non-`async` and
    /// `buildEpisodeNavigation` takes no API client, so no negotiation can
    /// happen here even by accident. It used to negotiate `PlaybackInfo` with
    /// the default (`.native`) device profile, which can only ever be right for
    /// one engine — the VLC path discarded that result and re-negotiated,
    /// paying an extra `getItem` + PlaybackInfo round-trip on every episode
    /// transition AND orphaning the live stream that negotiation opened
    /// (`isAutoOpenLiveStream`, never referenced by any stop report). Each
    /// presenter owns its own negotiation now.
    @Test("navigator resolves a target's neighbors, nil for unknown ids")
    func navigatorResolvesTarget() {
        let nav = buildEpisodeNavigation(for: "ep-1", in: episodes).navigator

        let resolved = nav?("ep-3")
        #expect(resolved?.0?.id == "ep-2") // new previous
        #expect(resolved?.1 == nil)        // last episode → no next

        let middle = nav?("ep-2")
        #expect(middle?.0?.id == "ep-1")
        #expect(middle?.1?.id == "ep-3")

        let unknown = nav?("nope")
        #expect(unknown == nil)
    }

    // MARK: - Chaîne de la série entière (défaut du 2026-11-19)

    /// Deux saisons et un hors-série, dans l'ordre où le serveur les rend
    /// (saison 0 en tête).
    private var wholeSeries: [EpisodeReference] {
        [
            EpisodeReference(id: "sp-1", name: "Hors-série 1", season: 0),
            EpisodeReference(id: "sp-2", name: "Hors-série 2", season: 0),
            EpisodeReference(id: "s1e1", name: "S1E1", season: 1),
            EpisodeReference(id: "s1e2", name: "S1E2", season: 1),
            EpisodeReference(id: "s2e1", name: "S2E1", season: 2),
            EpisodeReference(id: "s2e2", name: "S2E2", season: 2)
        ]
    }

    /// Par le chemin « plusieurs épisodes » (`SeriesEpisodeChains`), celui de
    /// l'Accueil et de la fiche.
    private func seriesNavigation(_ id: String) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
        guard let pre = SeriesEpisodeChains(wholeSeries).precomputed(for: id) else { return (nil, nil, nil) }
        return buildEpisodeNavigation(for: id, refs: pre.refs, indexByID: pre.indexByID)
    }

    @Test("Le dernier épisode d'une saison a pour suivant le premier de la saison suivante")
    func seasonBoundaryIsCrossed() {
        let chain = seriesEpisodeChain(containing: "s1e2", in: wholeSeries)
        let nav = buildEpisodeNavigation(for: "s1e2", in: chain)
        #expect(nav.previous?.id == "s1e1")
        #expect(nav.next?.id == "s2e1")

        // Et le navigateur poursuit : après le passage de saison, le premier
        // épisode de la saison 2 retrouve ses deux voisins.
        let after = nav.navigator?("s2e1")
        #expect(after?.0?.id == "s1e2")
        #expect(after?.1?.id == "s2e2")
    }

    @Test("Seul le dernier épisode disponible de la série n'a pas de suivant")
    func onlyTheLastAvailableEpisodeEndsTheSeries() {
        let withoutNext = ["s1e1", "s1e2", "s2e1", "s2e2"].filter { seriesNavigation($0).next == nil }
        #expect(withoutNext == ["s2e2"])
        #expect(seriesNavigation("s2e2").navigator != nil, "sans navigateur, pas de carte de fin de série")
    }

    @Test("Les hors-série forment leur propre chaîne")
    func specialsStayApart() {
        #expect(seriesNavigation("s1e1").previous == nil, "S1E1 n'est pas précédé d'un hors-série")
        #expect(seriesNavigation("sp-2").next == nil, "le dernier hors-série n'enchaîne pas sur S1E1")
        #expect(seriesNavigation("sp-1").next?.id == "sp-2")
        #expect(SeriesEpisodeChains(wholeSeries).precomputed(for: "inconnu") == nil)
    }

    /// « Si je regarde Arrow à nouveau, j'ai envie que mes épisodes
    /// s'enchaînent » : une série sans « à suivre » s'ouvre sur son premier
    /// épisode normal, jamais sur un hors-série listé avant lui.
    @Test("Une série revue s'ouvre sur le premier épisode de la première saison")
    func rewatchOpensOnTheFirstRegularEpisode() {
        #expect(seriesOpeningEpisode(in: wholeSeries)?.id == "s1e1")
        #expect(seriesNavigation("s1e1").next?.id == "s1e2")
        let onlySpecials = [EpisodeReference(id: "sp-1", name: "", season: 0)]
        #expect(seriesOpeningEpisode(in: onlySpecials)?.id == "sp-1")
        #expect(seriesOpeningEpisode(in: []) == nil)
    }

    @Test("Les saisons sont chaînées par numéro, l'ordre du serveur gardé dans la saison")
    func chainIsOrderedBySeasonNumber() {
        let shuffled = [
            EpisodeReference(id: "s2e1", name: "", season: 2),
            EpisodeReference(id: "s1e1", name: "", season: 1),
            EpisodeReference(id: "s2e2", name: "", season: 2),
            EpisodeReference(id: "s1e2", name: "", season: 1)
        ]
        #expect(seriesEpisodeChain(containing: "s2e2", in: shuffled).map(\.id) == ["s1e1", "s1e2", "s2e1", "s2e2"])
        #expect(seriesEpisodeChain(containing: "inconnu", in: shuffled).isEmpty)
    }
}

// MARK: - MediaLibraryViewModel load resilience
//
// Regression coverage for the tab-switch bug: cancelling a library load (by
// switching tabs mid-skeleton) must NOT paint the blocking error screen, real
// failures still must, and `hasLoaded` must latch only on success so Retry /
// the next visit actually re-fetch.

@MainActor
@Suite("MediaLibraryViewModel load resilience")
struct MediaLibraryViewModelTests {

    private func makeAppState(api: MockAPIClient, userId: String? = "user1") -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = userId
        return appState
    }

    private func makeItem(id: String) -> BaseItemDto {
        var item = BaseItemDto()
        item.id = id
        item.name = "Item \(id)"
        return item
    }

    @Test("URLError.cancelled (tab switch) never surfaces a blocking error")
    func urlCancellationDoesNotSurface() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        api.stubbedError = URLError(.cancelled)
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.reload(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(vm.errorMessage == nil)
    }

    @Test("Swift CancellationError likewise never surfaces an error")
    func swiftCancellationDoesNotSurface() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        api.stubbedError = CancellationError()
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.reload(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(vm.errorMessage == nil)
    }

    @Test("A genuine error surfaces the blocking error message")
    func realErrorSurfaces() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        api.stubbedError = MockError.genericFailure
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.reload(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(vm.errorMessage != nil)
        #expect(!vm.isLoading)
    }

    @Test("A clean load populates content and clears the loading flag")
    func successLoads() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Action", "Drama"]
        api.stubbedItems = [makeItem(id: "m1"), makeItem(id: "m2")]
        api.stubbedTotalCount = 42
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.reload(using: makeAppState(api: api), loc: LocalizationManager())

        #expect(vm.errorMessage == nil)
        #expect(!vm.isLoading)
        #expect(vm.totalCount == 42)
        #expect(vm.genres == ["Action", "Drama"])
        #expect(vm.heroItem != nil)
    }

    @Test("A failed first load doesn't latch — the next visit re-fetches")
    func failedLoadDoesNotLatch() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let appState = makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)

        // First attempt fails. If `loadInitial` wrongly latched `hasLoaded` at
        // load *start* (the old bug), the recovery below would be a silent no-op.
        await vm.loadInitial(using: appState, loc: LocalizationManager())
        #expect(vm.errorMessage != nil)

        // Server recovers — a second loadInitial must actually re-fetch.
        api.shouldThrow = false
        api.stubbedGenres = ["Action"]
        api.stubbedItems = [makeItem(id: "m1")]
        api.stubbedTotalCount = 7
        await vm.loadInitial(using: appState, loc: LocalizationManager())

        #expect(vm.errorMessage == nil)
        #expect(vm.totalCount == 7)
    }

    @Test("A successful load latches — a second loadInitial is a no-op")
    func successfulLoadLatches() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Action"]
        api.stubbedItems = [makeItem(id: "m1")]
        api.stubbedTotalCount = 7
        let appState = makeAppState(api: api)
        let vm = MediaLibraryViewModel(itemType: .movie)

        await vm.loadInitial(using: appState, loc: LocalizationManager())
        #expect(vm.totalCount == 7)

        // Change the stubbed data; a latched loadInitial must NOT re-fetch it
        // (prevents the hero re-randomizing on every tab switch).
        api.stubbedTotalCount = 999
        await vm.loadInitial(using: appState, loc: LocalizationManager())

        #expect(vm.totalCount == 7)
    }
}

// MARK: - « À suivre » : l'épisode après le dernier regardé

/// Relevé sur le serveur du propriétaire le 2026-11-19 (12.4) : Arrow, saisons
/// 4 à 8 vues, S02E19–22 regardés dans la semaine, S02E23 non vu. Le serveur ne
/// proposait rien (il lit « après le PLUS AVANCÉ jamais vu »), et son option
/// `enableRewatching` proposait S03E13, le prochain épisode DÉJÀ vu.
@Suite("À suivre — correction par la dernière lecture")
struct NextUpCorrectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func play(_ series: String, _ episode: String, daysAgo: Double) -> RecentPlay {
        RecentPlay(seriesId: series, episodeId: episode, playedAt: now.addingTimeInterval(-daysAgo * 86_400))
    }
    private let arrow = [
        EpisodeReference(id: "s2e22", name: "", season: 2),
        EpisodeReference(id: "s2e23", name: "", season: 2),
        EpisodeReference(id: "s3e1", name: "", season: 3),
        EpisodeReference(id: "sp1", name: "", season: 0)
    ]

    @Test("L'épisode qui suit, à travers les saisons ; rien après le dernier ni après un hors-série")
    func successorFollowsTheChain() {
        #expect(SeriesEpisodeOrder.successor(of: "s2e22", in: arrow)?.id == "s2e23")
        #expect(SeriesEpisodeOrder.successor(of: "s2e23", in: arrow)?.id == "s3e1")
        #expect(SeriesEpisodeOrder.successor(of: "s3e1", in: arrow) == nil)
        #expect(SeriesEpisodeOrder.successor(of: "sp1", in: arrow) == nil)
        #expect(SeriesEpisodeOrder.successor(of: "inconnu", in: arrow) == nil)
    }

    @Test("Une lecture par série, la plus récente, dans les 30 jours")
    func lastPlaysKeepsTheMostRecentPerSeriesInsideTheWindow() {
        let plays = [
            play("arrow", "s2e22", daysAgo: 1), play("arrow", "s2e21", daysAgo: 1.1),
            play("silo", "e7", daysAgo: 29), play("vieux", "e1", daysAgo: 31)
        ]
        let last = NextUpCorrection.lastPlays(plays, now: now)
        #expect(last.map(\.episodeId) == ["s2e22", "e7"])
    }

    @Test("Au plus douze séries corrigées par chargement")
    func lastPlaysIsBounded() {
        let plays = (0..<30).map { play("serie-\($0)", "e", daysAgo: Double($0) / 10) }
        #expect(NextUpCorrection.lastPlays(plays, now: now).count == NextUpCorrection.maxSeries)
    }

    @Test("Arrow revient avec S02E23 ; une série suivie dans l'ordre n'est pas touchée")
    func planCorrectsOnlyWhatDiffers() {
        let last = [play("arrow", "s2e22", daysAgo: 1), play("gabby", "s7e2", daysAgo: 0.2), play("fini", "e10", daysAgo: 2)]
        let plan = NextUpCorrection.plan(
            lastPlays: last,
            // « fini » : sa dernière lecture était le dernier épisode, pas de suivant.
            successors: ["arrow": "s2e23", "gabby": "s7e3"],
            serverNextUp: ["gabby": "s7e3", "autre": "x"]
        )
        #expect(plan.corrected == [.init(seriesId: "arrow", episodeId: "s2e23")])
    }

    @Test("Le serveur nomme un autre épisode : la dernière lecture l'emporte")
    func planOverridesADifferentServerAnswer() {
        let plan = NextUpCorrection.plan(
            lastPlays: [play("s", "s1e5", daysAgo: 1)], successors: ["s": "s1e6"], serverNextUp: ["s": "s4e1"]
        )
        #expect(plan.corrected.map(\.episodeId) == ["s1e6"])
    }
}

@Suite("À suivre — séries retirées")
struct NextUpHiddenListTests {
    @Test("Une série retirée revient dès que son épisode à suivre change")
    func hiddenUntilTheNextUpEpisodeChanges() {
        var list = NextUpHiddenList()
        list.hide(seriesId: "arrow", episodeId: "s2e23")
        #expect(list.hides(seriesId: "arrow", episodeId: "s2e23"))
        #expect(!list.hides(seriesId: "arrow", episodeId: "s3e1"), "un épisode regardé depuis : la série revient")
        #expect(!list.hides(seriesId: "silo", episodeId: "s2e23"))
        #expect(!list.hides(seriesId: nil, episodeId: "s2e23"))
    }

    @Test("La liste survit à l'aller-retour dans les préférences du compte")
    func roundTripsThroughDisplayPreferences() {
        var list = NextUpHiddenList()
        list.hide(seriesId: "arrow", episodeId: "s2e23")
        list.hide(seriesId: "silo", episodeId: "s1e8")
        var dto = DisplayPreferencesDto()
        dto.customPrefs = ["autre": "gardé"]
        let written = list.merged(into: dto)
        #expect(written.customPrefs?["autre"] == "gardé")
        #expect(NextUpHiddenList(written) == list)
        #expect(NextUpHiddenList(storedValue: "pas du json").entries.isEmpty)
        #expect(NextUpHiddenList(nil).entries.isEmpty)
    }

    @Test("Liste bornée : les plus anciens retraits sortent les premiers")
    func capacityDropsTheOldest() {
        var list = NextUpHiddenList()
        for index in 0...NextUpHiddenList.capacity { list.hide(seriesId: "s\(index)", episodeId: "e") }
        #expect(list.entries.count == NextUpHiddenList.capacity)
        #expect(!list.hides(seriesId: "s0", episodeId: "e"))
        #expect(list.hides(seriesId: "s\(NextUpHiddenList.capacity)", episodeId: "e"))
    }
}
