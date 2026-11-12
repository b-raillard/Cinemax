import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

/// Free function so it can be called from non-isolated `@Sendable` handler closures
/// without crossing actor boundaries. BaseItemDto is a struct; the returned value
/// is fully owned by the caller.
private func makeEpisode(id: String, name: String) -> BaseItemDto {
    var ep = BaseItemDto()
    ep.id = id
    ep.name = name
    return ep
}

/// Episode carrying a `userData` payload so played-state mutations have
/// something to flip (episodes are fetched with `enableUserData: true`).
private func makeWatchableEpisode(id: String, name: String, played: Bool) -> BaseItemDto {
    var ep = makeEpisode(id: id, name: name)
    var userData = UserItemDataDto(key: "test")
    userData.isPlayed = played
    ep.userData = userData
    return ep
}

/// Episode tagged with its parent season id, so cross-season next-up
/// resolution (`nextUpEpisode?.seasonID != selectedSeasonId`) has something
/// to compare against.
private func makeEpisodeInSeason(id: String, name: String, seasonId: String) -> BaseItemDto {
    var ep = makeEpisode(id: id, name: name)
    ep.seasonID = seasonId
    return ep
}

private func makeMovie(id: String, played: Bool) -> BaseItemDto {
    var item = BaseItemDto()
    item.id = id
    item.type = .movie
    var userData = UserItemDataDto(key: "test")
    userData.isPlayed = played
    item.userData = userData
    return item
}

private func makeSeries(id: String, played: Bool) -> BaseItemDto {
    var item = BaseItemDto()
    item.id = id
    item.type = .series
    var userData = UserItemDataDto(key: "test")
    userData.isPlayed = played
    item.userData = userData
    return item
}

/// Thread-safe monotonic counter so a `@Sendable` handler can tell which call it
/// is (the load-race test needs the first call to be slow, the second fast, but
/// both target the same `itemId`).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

@MainActor
@Suite("MediaDetailViewModel")
struct MediaDetailViewModelTests {

    private func makeAppState(api: MockAPIClient) -> AppState {
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        return appState
    }

    /// When the user rapidly taps two seasons, the first season's episode fetch can
    /// resolve after the second one due to network ordering. The generation counter
    /// inside `selectSeason` must discard the stale result and keep the latest
    /// season's episodes.
    @Test("selectSeason discards stale results when a newer selection completes first")
    func selectSeasonRaceKeepsLatest() async {
        let api = MockAPIClient()
        let seasonAFetching = TestLatch()
        let releaseSeasonA = TestLatch()
        api.getEpisodesHandler = { seasonId in
            // Season A is held until Season B has fully resolved, so it lands
            // *after* it — the race described in the audit, held open by a
            // latch instead of guessed with two sleeps.
            if seasonId == "season-A" {
                seasonAFetching.open()
                await releaseSeasonA.wait()
                return [makeEpisode(id: "ep-a1", name: "A1"), makeEpisode(id: "ep-a2", name: "A2")]
            } else {
                return [makeEpisode(id: "ep-b1", name: "B1")]
            }
        }

        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        let appState = makeAppState(api: api)

        async let firstCall: Void = vm.selectSeason("season-A", seriesId: "series-1", using: appState)
        // Season A's fetch is in flight, so its generation is already captured
        // before B increments it.
        await seasonAFetching.wait()
        await vm.selectSeason("season-B", seriesId: "series-1", using: appState)
        releaseSeasonA.open()
        await firstCall

        #expect(vm.selectedSeasonId == "season-B")
        #expect(vm.episodes.map(\.id) == ["ep-b1"])
    }

    @Test("selectSeason applies episodes when no race occurs")
    func selectSeasonAppliesEpisodes() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in
            [makeEpisode(id: "ep-1", name: "Pilot")]
        }

        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        let appState = makeAppState(api: api)

        await vm.selectSeason("season-A", seriesId: "series-1", using: appState)

        #expect(vm.selectedSeasonId == "season-A")
        #expect(vm.episodes.map(\.id) == ["ep-1"])
    }

    @Test("togglePlayed flips state and marks the movie played, then unplayed")
    func togglePlayedRoundTrip() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        vm.item = makeMovie(id: "movie-1", played: false)
        vm.isPlayed = false

        await vm.togglePlayed(using: appState)
        #expect(vm.isPlayed == true)
        #expect(api.markPlayedCalls == ["movie-1"])

        await vm.togglePlayed(using: appState)
        #expect(vm.isPlayed == false)
        #expect(api.markUnplayedCalls == ["movie-1"])
    }

    /// Audit 2026-09-22 (B6) : « Marquer comme vu » ne basculait que `isPlayed`,
    /// alors que « Reprendre » et la barre de progression lisent `item.userData`
    /// via `resolvedPlayTarget` — le bouton restait et rouvrait le film au milieu.
    @Test("togglePlayed clears the resume position the Play button reads")
    func togglePlayedClearsResumeOnItem() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        var movie = makeMovie(id: "movie-1", played: false)
        movie.userData?.playbackPositionTicks = 30_000_000_000
        vm.item = movie
        vm.isPlayed = false

        await vm.togglePlayed(using: appState)
        #expect(vm.item?.userData?.isPlayed == true)
        #expect(vm.item?.userData?.playbackPositionTicks == 0)
    }

    /// Une position suffit désormais à faire une reprise (`isResumable`) :
    /// marquer non vu doit donc aussi remettre la position à zéro, comme le
    /// fait Jellyfin (`MarkUnplayed`), sinon « Reprendre » survivrait.
    @Test("togglePlayed to unwatched also clears the resume position")
    func togglePlayedUnwatchedClearsResume() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        var movie = makeMovie(id: "movie-1", played: true)
        movie.userData?.playbackPositionTicks = 30_000_000_000   // un revisionnage entamé
        vm.item = movie
        vm.isPlayed = true

        await vm.togglePlayed(using: appState)
        #expect(vm.item?.userData?.isPlayed == false)
        #expect(vm.item?.userData?.playbackPositionTicks == 0)
        #expect(api.markUnplayedCalls == ["movie-1"])
    }

    // MARK: - « Titres similaires » hors du chemin critique (audit 2026-09-22, P1)

    @Test("A failing /Similar never replaces the fiche with the error screen")
    func similarFailureIsNotFatal() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in makeMovie(id: id, played: false) }
        api.similarItemsShouldThrow = true
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)

        await vm.load(using: appState, loc: LocalizationManager())
        await vm.similarTask?.value

        #expect(vm.errorMessage == nil)
        #expect(vm.item?.id == "movie-1")
        #expect(vm.similarItems.isEmpty)
    }

    @Test("Similar titles fill in from the side task")
    func similarFillsInAfterLoad() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in makeMovie(id: id, played: false) }
        api.stubbedSimilarItems = [makeMovie(id: "other", played: false)]
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)

        await vm.load(using: appState, loc: LocalizationManager())
        await vm.similarTask?.value

        #expect(vm.similarItems.map(\.id) == ["other"])
    }

    // MARK: - Épisode demandé hors des saisons chargées (étape 0, 2026-09-25)

    /// Une demande par id (« Lire sur… », file Regarder ensemble, Siri) pour un
    /// épisode de la saison 3 cherchait l'épisode dans `episodes` (saison 1
    /// seulement), ne le trouvait pas et lançait le « À suivre » de la série.
    /// L'épisode tel que récupéré reste porté par `requestedEpisode`, même si sa
    /// saison n'est pas celle qu'affiche la fiche.
    @Test("A fiche opened for an episode keeps that episode as fetched")
    func requestedEpisodeOutsideLoadedSeasons() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in
            if id == "ep-s3e4" {
                var ep = makeEpisodeInSeason(id: id, name: "S3E4", seasonId: "season-3")
                ep.type = .episode
                ep.seriesID = "series-1"
                return ep
            }
            return makeSeries(id: id, played: false)
        }
        api.getSeasonsHandler = { _ in
            var s1 = BaseItemDto(); s1.id = "season-1"
            var s3 = BaseItemDto(); s3.id = "season-3"
            return [s1, s3]
        }
        api.getEpisodesHandler = { seasonId in
            [makeEpisodeInSeason(id: "ep-s1e1", name: "S1E1", seasonId: seasonId)]
        }
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "ep-s3e4", itemType: .episode)

        await vm.load(using: appState, loc: LocalizationManager())

        #expect(vm.item?.id == "series-1", "the fiche shows the series")
        #expect(vm.requestedEpisode?.id == "ep-s3e4")
    }

    // MARK: - Saison initiale d'une fiche ouverte par un épisode (recette 2026-10-20)

    /// `cinemax://item/<épisode S03>` (widget, Top Shelf) — et toute carte qui
    /// pousse l'id d'un épisode (recherche, favoris, historique) — ouvrait la
    /// fiche de la série sur la SAISON 1 : `loadSeriesDetail` prenait
    /// `seasons.first` sans regarder l'élément demandé.
    private func makeThreeSeasonAPI() -> MockAPIClient {
        let api = MockAPIClient()
        api.getItemHandler = { id in
            switch id {
            case "ep-s3e4":
                var ep = makeEpisodeInSeason(id: id, name: "S3E4", seasonId: "season-3")
                ep.type = .episode
                ep.seriesID = "series-1"
                return ep
            case "season-2":
                var season = BaseItemDto()
                season.id = id
                season.type = .season
                season.seriesID = "series-1"
                return season
            default:
                return makeSeries(id: id, played: false)
            }
        }
        api.getSeasonsHandler = { _ in
            ["season-1", "season-2", "season-3"].map { id in
                var season = BaseItemDto(); season.id = id; return season
            }
        }
        api.getEpisodesHandler = { seasonId in
            switch seasonId {
            case "season-3":
                return (1...6).map { makeEpisodeInSeason(id: "ep-s3e\($0)", name: "S3E\($0)", seasonId: seasonId) }
            case "season-2":
                return [makeEpisodeInSeason(id: "ep-s2e1", name: "S2E1", seasonId: seasonId)]
            default:
                return [makeEpisodeInSeason(id: "ep-s1e1", name: "S1E1", seasonId: seasonId)]
            }
        }
        return api
    }

    @Test("A fiche opened for an episode lands on that episode's season")
    func episodeFicheOpensOnEpisodeSeason() async {
        let api = makeThreeSeasonAPI()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "ep-s3e4", itemType: .episode)

        await vm.load(using: appState, loc: LocalizationManager())

        #expect(vm.item?.id == "series-1")
        #expect(vm.selectedSeasonId == "season-3")
        #expect(vm.episodes.contains { $0.id == "ep-s3e4" })
        let nav = vm.episodeNavigationMap["ep-s3e4"]
        #expect(nav?.previous?.id == "ep-s3e3", "prev/next viennent de la saison de l'épisode")
        #expect(nav?.next?.id == "ep-s3e5")
    }

    @Test("A fiche opened for a season lands on that season")
    func seasonFicheOpensOnThatSeason() async {
        let api = makeThreeSeasonAPI()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "season-2", itemType: .season)

        await vm.load(using: appState, loc: LocalizationManager())

        #expect(vm.item?.id == "series-1")
        #expect(vm.selectedSeasonId == "season-2")
        #expect(vm.episodes.map(\.id) == ["ep-s2e1"])
    }

    @Test("A fiche opened for the series itself still lands on the first season")
    func seriesFicheOpensOnFirstSeason() async {
        let api = makeThreeSeasonAPI()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)

        await vm.load(using: appState, loc: LocalizationManager())

        #expect(vm.selectedSeasonId == "season-1")
        #expect(vm.episodes.map(\.id) == ["ep-s1e1"])
    }

    @Test("Initial season: the preferred one when listed, else the first")
    func initialSeasonChoice() {
        let seasons = ["season-1", "season-2", "season-3"].map { id in
            var season = BaseItemDto(); season.id = id; return season
        }
        #expect(MediaDetailViewModel.initialSeasonId(in: seasons, preferring: "season-3") == "season-3")
        #expect(MediaDetailViewModel.initialSeasonId(in: seasons, preferring: "season-9") == "season-1",
                "une saison absente de la liste (spéciaux masqués…) retombe sur la première")
        #expect(MediaDetailViewModel.initialSeasonId(in: seasons, preferring: nil) == "season-1")
        #expect(MediaDetailViewModel.initialSeasonId(in: [], preferring: "season-3") == nil)
    }

    @Test("A fiche opened for the series itself names no requested episode")
    func noRequestedEpisodeForSeries() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in makeSeries(id: id, played: false) }
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)

        await vm.load(using: appState, loc: LocalizationManager())

        #expect(vm.requestedEpisode == nil)
    }

    @Test("A successful retry clears the error screen")
    func retryClearsError() async {
        let api = MockAPIClient()
        api.shouldThrow = true
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        await vm.load(using: appState, loc: LocalizationManager())
        #expect(vm.errorMessage != nil, "pré-condition")

        api.shouldThrow = false
        api.getItemHandler = { id in makeMovie(id: id, played: false) }
        await vm.load(using: appState, loc: LocalizationManager())

        #expect(vm.errorMessage == nil)
    }

    @Test("toggleEpisodeWatched flips the local episode payload and clears resume")
    func toggleEpisodeWatchedUpdatesLocalState() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        var episode = makeWatchableEpisode(id: "ep-1", name: "Pilot", played: false)
        episode.userData?.playbackPositionTicks = 500
        vm.episodes = [episode]

        await vm.toggleEpisodeWatched(episode, using: appState)
        #expect(vm.episodes.first?.userData?.isPlayed == true)
        #expect(vm.episodes.first?.userData?.playbackPositionTicks == 0)
        #expect(api.markPlayedCalls == ["ep-1"])
    }

    @Test("toggleEpisodeWatched to unwatched also clears resume")
    func toggleEpisodeUnwatchedClearsResume() async {
        let api = MockAPIClient()
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        var episode = makeWatchableEpisode(id: "ep-1", name: "Pilot", played: true)
        episode.userData?.playbackPositionTicks = 500
        vm.episodes = [episode]

        await vm.toggleEpisodeWatched(episode, using: appState)
        #expect(vm.episodes.first?.userData?.isPlayed == false)
        #expect(vm.episodes.first?.userData?.playbackPositionTicks == 0)
        #expect(api.markUnplayedCalls == ["ep-1"])
    }

    // MARK: - refreshAfterPlayback (targeted post-playback refresh)

    /// A movie's post-playback refresh re-fetches ONLY the item (for fresh
    /// userData) — never the similar/seasons/next-up fan-out a full `load()`
    /// would run.
    ///
    /// This is the **fallback** path: the mock inherits `LibraryAPI`'s default
    /// `getItemUserData` (nil = server too old), so `fetchUserData` falls
    /// through to a full `getItem`. The lightweight path is covered below.
    @Test("refreshAfterPlayback for a movie fetches item once, skips similar/seasons/nextUp")
    func refreshAfterPlaybackMovieTargeted() async {
        let api = MockAPIClient()
        api.getItemHandler = { _ in makeMovie(id: "movie-1", played: true) }
        let appState = makeAppState(api: api)

        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        vm.item = makeMovie(id: "movie-1", played: false)
        vm.resolvedType = .movie
        vm.isPlayed = false
        vm.isLoading = false // post-load state — a refresh must not flash the spinner back

        await vm.refreshAfterPlayback(using: appState)

        #expect(api.getItemCallCount == 1)
        #expect(api.getSimilarItemsCallCount == 0)
        #expect(api.getSeasonsCallCount == 0)
        #expect(api.getNextUpCallCount == 0)
        // Fresh userData is reflected without an isLoading spinner flash.
        #expect(vm.isPlayed == true)
        #expect(vm.isLoading == false)
    }

    /// On a server exposing `GET /UserItems/{id}/UserData`, the movie refresh
    /// must take the lightweight read and NOT pull the whole `BaseItemDto`
    /// (overview, people, chapters, media sources) just to learn a resume
    /// position. The item already on screen keeps its other fields.
    @Test("refreshAfterPlayback for a movie uses the lightweight userData read when the server supports it")
    func refreshAfterPlaybackMovieUsesLightweightUserData() async {
        let api = MockAPIClient()
        var fresh = UserItemDataDto(key: "test")
        fresh.isPlayed = true
        fresh.isFavorite = true
        fresh.playbackPositionTicks = 42
        api.stubbedItemUserData = fresh
        api.getItemHandler = { _ in makeMovie(id: "movie-1", played: true) }
        let appState = makeAppState(api: api)

        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        var existing = makeMovie(id: "movie-1", played: false)
        existing.overview = "kept"
        vm.item = existing
        vm.resolvedType = .movie
        vm.isPlayed = false
        vm.isFavorite = false
        vm.isLoading = false

        await vm.refreshAfterPlayback(using: appState)

        #expect(api.getItemUserDataCallCount == 1)
        #expect(api.getItemCallCount == 0)
        #expect(vm.isPlayed == true)
        #expect(vm.isFavorite == true)
        #expect(vm.item?.userData?.playbackPositionTicks == 42)
        // Spliced onto the held item rather than replacing it — the lightweight
        // response carries no other field to restore.
        #expect(vm.item?.overview == "kept")
    }

    /// A series' post-playback refresh re-fetches the item (userData), next-up,
    /// and the visible season's episodes concurrently — but NOT seasons or
    /// similar (those don't change from watching).
    @Test("refreshAfterPlayback for a series refreshes episodes + nextUp, skips seasons/similar")
    func refreshAfterPlaybackSeriesTargeted() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in makeSeries(id: id, played: false) }
        api.stubbedNextUp = makeEpisode(id: "next-ep", name: "Next")
        api.getEpisodesHandler = { _ in
            [makeEpisode(id: "ep-1", name: "One"), makeEpisode(id: "ep-2", name: "Two")]
        }
        let appState = makeAppState(api: api)

        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        vm.item = makeSeries(id: "series-1", played: false)
        vm.resolvedType = .series
        vm.selectedSeasonId = "season-1"
        vm.isLoading = false // post-load state — a refresh must not flash the spinner back

        await vm.refreshAfterPlayback(using: appState)

        #expect(api.getItemCallCount == 1)
        #expect(api.getNextUpCallCount == 1)
        #expect(api.getEpisodesCallCount == 1)
        #expect(api.getSeasonsCallCount == 0)
        #expect(api.getSimilarItemsCallCount == 0)
        #expect(vm.nextUpEpisode?.id == "next-ep")
        #expect(vm.episodes.map(\.id) == ["ep-1", "ep-2"])
        #expect(vm.isLoading == false)
    }

    /// When the refreshed next-up episode lands in a DIFFERENT season than the
    /// one currently displayed, `refreshAfterPlayback` must re-fetch that
    /// season's episodes into `nextUpEpisodes` so `nextUpNavigationMap` can
    /// resolve prev/next for it -- mirroring `loadSeriesDetail`'s cross-season
    /// branch. Regression test: the targeted refresh used to never touch
    /// `nextUpEpisodes`, silently dropping the in-player Next Up prev/next
    /// buttons whenever the next episode crossed a season boundary.
    @Test("refreshAfterPlayback fetches cross-season next-up episodes when next-up differs from the visible season")
    func refreshAfterPlaybackCrossSeasonNextUp() async {
        let api = MockAPIClient()
        api.getItemHandler = { id in makeSeries(id: id, played: false) }
        api.stubbedNextUp = makeEpisodeInSeason(id: "next-ep", name: "Next", seasonId: "season-2")
        api.getEpisodesHandler = { seasonId in
            switch seasonId {
            case "season-1":
                return [makeEpisode(id: "ep-1", name: "One"), makeEpisode(id: "ep-2", name: "Two")]
            case "season-2":
                return [makeEpisode(id: "next-ep", name: "Next")]
            default:
                return []
            }
        }
        let appState = makeAppState(api: api)

        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        vm.item = makeSeries(id: "series-1", played: false)
        vm.resolvedType = .series
        vm.selectedSeasonId = "season-1"
        vm.isLoading = false // post-load state -- a refresh must not flash the spinner back

        await vm.refreshAfterPlayback(using: appState)

        #expect(api.getEpisodesCallCount == 2) // visible season + cross-season next-up
        #expect(vm.nextUpEpisode?.id == "next-ep")
        #expect(vm.episodes.map(\.id) == ["ep-1", "ep-2"])
        #expect(vm.nextUpEpisodes.map(\.id) == ["next-ep"])
        #expect(vm.nextUpNavigationMap["next-ep"] != nil)
        #expect(vm.isLoading == false)
    }

    /// A slow first `load()` must not clobber the state a fast second `load()`
    /// already produced — the generation guard discards the stale pass (mirrors
    /// the `selectSeason` race test).
    @Test("load discards stale results when a newer load completes first")
    func loadRaceKeepsLatest() async {
        let api = MockAPIClient()
        let counter = CallCounter()
        let firstFetching = TestLatch()
        let releaseFirst = TestLatch()
        api.getItemHandler = { _ in
            // The first-started load resolves LAST (held until the second has
            // finished); the second resolves first — last-writer-wins would
            // leave "old" without a guard.
            if counter.next() == 1 {
                firstFetching.open()
                await releaseFirst.wait()
                return makeMovie(id: "old", played: false)
            } else {
                return makeMovie(id: "new", played: true)
            }
        }
        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        let loc = LocalizationManager()

        async let firstCall: Void = vm.load(using: appState, loc: loc)
        // The first load's fetch is in flight, so it has bumped + snapshotted
        // its generation before the second starts.
        await firstFetching.wait()
        await vm.load(using: appState, loc: loc)
        releaseFirst.open()
        await firstCall

        #expect(vm.item?.id == "new")
        #expect(vm.isPlayed == true)
    }

    @Test("selectSeason without userId short-circuits")
    func selectSeasonWithoutUserIdNoop() async {
        let api = MockAPIClient()
        api.getEpisodesHandler = { _ in
            [makeEpisode(id: "ep-1", name: "Pilot")]
        }

        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = nil

        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        await vm.selectSeason("season-A", seriesId: "series-1", using: appState)

        #expect(vm.episodes.isEmpty)
    }

    // MARK: - Remote play targets ("Play on…")

    @Test("loadRemoteTargets keeps only the sessions the user can drive")
    func loadRemoteTargetsPopulates() async {
        let api = MockAPIClient()
        var mine = SessionInfoDto()
        mine.id = "s1"
        mine.userID = "user1"
        mine.deviceID = "apple-tv"
        mine.deviceName = "Salon"
        mine.isSupportsRemoteControl = true
        // Same server response, another account: must never be offered as a
        // target (see the defense-in-depth RULE on `RemotePlayTarget.resolve`).
        var other = SessionInfoDto()
        other.id = "s2"
        other.userID = "user2"
        other.deviceID = "someone-else"
        other.isSupportsRemoteControl = true
        api.stubbedControllableSessions = [mine, other]

        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)

        await vm.loadRemoteTargets(using: appState)

        #expect(api.controllableSessionsCallCount == 1)
        #expect(vm.remoteTargets.map(\.id) == ["s1"])
        #expect(vm.remoteTargets.first?.name == "Salon")
    }

    /// 2026-09-26 : le sélecteur appelait `getControllableSessions(userId:)` sur
    /// un `any RemoteControlAPI` ; l'argument par défaut n'existant que sur la
    /// méthode d'extension no-op, l'appel s'y liait statiquement et rendait `[]`
    /// sans jamais interroger le client — « Aucun appareil disponible » alors
    /// que la fiche affichait le bouton. Le test passe par l'existentiel exprès.
    @Test("The « Lire sur… » picker really asks the client, through the protocol")
    func remotePickerReachesTheClient() async {
        let api = MockAPIClient()
        var tv = SessionInfoDto()
        tv.id = "s1"
        tv.userID = "user1"
        tv.deviceID = "apple-tv"
        tv.deviceName = "Salon"
        tv.isSupportsRemoteControl = true
        api.stubbedControllableSessions = [tv]
        let slice: any RemoteControlAPI = api
        let model = RemotePlayModel()

        await model.load(userId: "user1", api: slice, loc: LocalizationManager())

        #expect(api.controllableSessionsCallCount == 1, "the no-op default must not answer")
        #expect(model.targets.map(\.id) == ["s1"])
    }

    @Test("loadRemoteTargets swallows a failure — no targets, no error on screen")
    func loadRemoteTargetsSwallowsFailure() async {
        let api = MockAPIClient()
        api.controllableSessionsError = MockError.genericFailure

        let appState = makeAppState(api: api)
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)

        await vm.loadRemoteTargets(using: appState)

        #expect(vm.remoteTargets.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test("loadRemoteTargets without a signed-in user short-circuits")
    func loadRemoteTargetsWithoutUserNoop() async {
        let api = MockAPIClient()
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = nil

        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)
        await vm.loadRemoteTargets(using: appState)

        #expect(api.controllableSessionsCallCount == 0)
        #expect(vm.remoteTargets.isEmpty)
    }
}

// MARK: - MetadataEditorViewModel full-item gate

#if os(iOS)
/// Lives in this file (not its own) because a new file under Tests/ needs an
/// xcodegen regen; the suite reuses this file's MockAPIClient idioms.
///
/// The editor is seeded with a narrowed `getItems` list DTO. `save()` POSTs the
/// whole DTO, so opening the form before the full `getItem` DTO lands would let
/// a Save silently wipe `people`/`studios`/`tags` server-side. These tests lock
/// the gate's failure behavior: a failed fetch must not latch (the re-fired
/// `.task` / retry button retries), and only a success un-gates the form.
@MainActor
@Suite("MetadataEditorViewModel full-item gate")
struct MetadataEditorViewModelGateTests {

    private func makeNarrowSeed() -> BaseItemDto {
        var item = BaseItemDto()
        item.id = "item-1"
        item.name = "Narrow"
        return item
    }

    @Test("fetch failure does not latch — a re-fired load retries and recovers")
    func failureRetriesOnNextFire() async {
        let api = MockAPIClient()
        api.getItemHandler = { @Sendable _ in throw MockError.genericFailure }
        let vm = MetadataEditorViewModel(item: makeNarrowSeed())

        await vm.loadFullItemIfNeeded(using: api, userId: "user1")

        // Still gated: not loading anymore, but flagged failed — the screen
        // renders the retry state, never the form.
        #expect(vm.isLoadingFullItem == false)
        #expect(vm.fullItemLoadFailed == true)
        #expect(vm.item.name == "Narrow")

        api.getItemHandler = { @Sendable _ in
            var full = BaseItemDto()
            full.id = "item-1"
            full.name = "Full"
            return full
        }
        await vm.loadFullItemIfNeeded(using: api, userId: "user1")

        #expect(api.getItemCallCount == 2)
        #expect(vm.item.name == "Full")
        #expect(vm.isLoadingFullItem == false)
        #expect(vm.fullItemLoadFailed == false)
    }

    @Test("successful load latches — a re-fired load does not refetch")
    func successLatches() async {
        let api = MockAPIClient()
        api.getItemHandler = { @Sendable _ in
            var full = BaseItemDto()
            full.id = "item-1"
            full.name = "Full"
            return full
        }
        let vm = MetadataEditorViewModel(item: makeNarrowSeed())

        await vm.loadFullItemIfNeeded(using: api, userId: "user1")
        await vm.loadFullItemIfNeeded(using: api, userId: "user1")

        #expect(api.getItemCallCount == 1)
        #expect(vm.item.name == "Full")
        #expect(vm.isLoadingFullItem == false)
    }
}
#endif

// MARK: - Seerr — missing seasons (« Pas encore dans ta bibliothèque »)

/// `/tv/{id}` as Seerr answers it: the TMDb seasons, in Seerr's order.
private func seerrTVBody(_ tmdbId: Int, seasons: [Int]) -> String {
    let list = seasons.map { #"{"seasonNumber":\#($0),"episodeCount":8}"# }.joined(separator: ",")
    return #"{"id":\#(tmdbId),"name":"Série du banc","seasons":[\#(list)]}"#
}

/// Answers Seerr for a series fiche: the session's reload (`/settings/public`,
/// `/auth/me`), then `/tv/{id}` from `series` — held by that id's gate when
/// one is given — and `/request`.
private final class DetailSeerrTransport: SeerrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private let series: [Int: String]
    private let gates: [Int: TestLatch]
    private let specials: Bool
    private let collections: [Int: String]
    /// Opens when the first `/tv/{id}` request reaches the transport.
    let tvArrived = TestLatch()
    /// `/tv/{id}/season/{n}` bodies by that path; none ⇒ the call fails.
    private var seasonBodies: [String: String] = [:]
    /// The bodies of the `POST /issue` calls received.
    private var issueBodies: [String] = []
    /// `GET /issue` (the open reports); none ⇒ the call fails.
    private var openIssuesBody: String?
    /// The Seerr user's permissions (`/auth/me`): 32 = request only.
    private let permissions: Int

    func setSeason(_ path: String, _ body: String) { lock.withLock { seasonBodies[path] = body } }
    func setOpenIssues(_ body: String) { lock.withLock { openIssuesBody = body } }
    var issues: [String] { lock.withLock { issueBodies } }
    var seasonRequestCount: Int {
        lock.withLock { sent }.filter { $0.url?.path.contains("/season/") == true }.count
    }

    init(
        series: [Int: String], gates: [Int: TestLatch] = [:], specials: Bool = false,
        collections: [Int: String] = [:], permissions: Int = 32
    ) {
        self.permissions = permissions
        self.series = series
        self.gates = gates
        self.specials = specials
        self.collections = collections
    }

    var tvRequestCount: Int {
        lock.withLock { sent }.filter { $0.url?.path.contains("/tv/") == true }.count
    }

    var collectionRequestCount: Int {
        lock.withLock { sent }.filter { $0.url?.path.contains("/collection/") == true }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        let path = request.url?.path.replacingOccurrences(of: "/api/v1", with: "") ?? ""
        let status: Int
        let body: String
        switch path {
        case "/settings/public":
            status = 200
            body = #"{"mediaServerType":2,"partialRequestsEnabled":true,"enableSpecialEpisodes":\#(specials)}"#
        case "/auth/me":
            status = 200
            body = #"{"id":7,"permissions":\#(permissions),"jellyfinUserId":"A","displayName":"Alice"}"#
        case "/request":
            status = 201
            body = """
            {"id":1,"status":1,"type":"tv","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z",
            "requestedBy":{"id":7,"permissions":32},"media":{"tmdbId":1399,"status":2}}
            """
        case let saga where saga.hasPrefix("/collection/"):
            guard let id = Int(saga.dropFirst("/collection/".count)), let reply = collections[id] else {
                throw StubSeerrTransport.Exhausted()
            }
            status = 200
            body = reply
        case "/issue" where request.httpMethod == "GET":
            guard let reply = lock.withLock({ openIssuesBody }) else { throw StubSeerrTransport.Exhausted() }
            status = 200
            body = reply
        case "/issue":
            lock.withLock { issueBodies.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "") }
            status = 200
            body = #"{"id":5}"#
        case let season where season.contains("/season/"):
            guard let reply = lock.withLock({ seasonBodies[season] }) else { throw StubSeerrTransport.Exhausted() }
            status = 200
            body = reply
        case let tv where tv.hasPrefix("/tv/"):
            guard let id = Int(tv.dropFirst("/tv/".count)), let reply = series[id] else {
                throw StubSeerrTransport.Exhausted()
            }
            tvArrived.open()
            if let gate = gates[id] { await gate.wait() }
            status = 200
            body = reply
        default:
            throw StubSeerrTransport.Exhausted()
        }
        let url = request.url ?? URL(string: "http://192.168.1.20:5055")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (Data(body.utf8), response)
    }
}

/// A series the library holds `owned` seasons of, matched to TMDb `tmdb`
/// (`nil` ⇒ no TMDb id at all). `tmdbForCall` overrides it per `getItem`
/// call (1-based) — an identify between two loads.
private func ownedSeriesAPI(
    tmdb: String? = "1399", owned: [Int] = [1, 2, 3], tmdbForCall: (@Sendable (Int) -> String?)? = nil
) -> MockAPIClient {
    let api = MockAPIClient()
    let calls = CallCounter()
    api.getItemHandler = { id in
        var series = makeSeries(id: id, played: false)
        series.name = "Série du banc"
        series.productionYear = 2011
        let call = calls.next()
        if let value = tmdbForCall?(call) ?? tmdb { series.providerIDs = ["Tmdb": value] }
        return series
    }
    api.getSeasonsHandler = { _ in
        owned.map { number in
            var season = BaseItemDto()
            season.id = "season-\(number)"
            season.indexNumber = number
            return season
        }
    }
    api.getEpisodesHandler = { seasonId in
        [makeEpisodeInSeason(id: "ep-\(seasonId)-1", name: "Épisode 1", seasonId: seasonId)]
    }
    return api
}

private func missingSeasons(_ tmdbId: Int, _ numbers: [Int], _ badge: SeerrBadge = .request) -> [SeerrMissingSeason] {
    numbers.map { SeerrMissingSeason(seriesTmdbId: tmdbId, seasonNumber: $0, badge: badge) }
}

/// A series with one owned season whose library episodes are `numbers`.
private func partialSeasonAPI(_ numbers: [Int]) -> MockAPIClient {
    let api = ownedSeriesAPI(owned: [1])
    api.getEpisodesHandler = { seasonId in
        numbers.map { number in
            var episode = makeEpisodeInSeason(id: "ep-\(number)", name: "Épisode \(number)", seasonId: seasonId)
            episode.indexNumber = number
            return episode
        }
    }
    return api
}

private let seasonOneBody = """
{"episodes":[
{"episodeNumber":1,"name":"Un","airDate":"2021-01-01"},
{"episodeNumber":2,"name":"Deux","airDate":"2021-01-08"},
{"episodeNumber":3,"name":"Trois","airDate":"2021-01-15"},
{"episodeNumber":4,"name":"Quatre","airDate":"2021-01-22"},
{"episodeNumber":5,"name":"Pas encore diffusé","airDate":"2099-01-01"},
{"episodeNumber":6,"name":"Sans date","airDate":null}]}
"""

@MainActor
@Suite("Detail — missing episodes")
struct MediaDetailMissingEpisodesTests {
    private let loc = LocalizationManager()

    private func makeViewModel(_ session: SeerrSession, allowed: Bool = true) -> MediaDetailViewModel {
        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        vm.seerr = session
        vm.allowsSeerr = { allowed }
        vm.seerrDeadline = neverExpires
        vm.seerrToday = { "2026-11-11" }
        // Never `.standard`: the test host is the app, whose own « Masquer »
        // (a series hidden on the simulator) hid the episodes under test.
        vm.defaults = UserDefaults.isolatedForTesting()
        return vm
    }

    @Test("the aired episodes an owned season lacks are listed, ascending; the others are not")
    func missingEpisodesOfTheSeasonOnScreen() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1])])
        transport.setSeason("/tv/1399/season/1", seasonOneBody)
        let (app, session) = await seerrBench(api: partialSeasonAPI([1, 3]), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value

        let missing = vm.seerrEpisodes(for: session.snapshot())
        #expect(missing.map(\.episodeNumber) == [2, 4])
        #expect(missing.map(\.name) == ["Deux", "Quatre"])
        // Another profile never sees this account's answer.
        #expect(vm.seerrEpisodes(for: SeerrSession.Snapshot(accountKey: "S1|B", generation: 99)).isEmpty)
    }

    @Test("without Seerr for this account nothing is asked")
    func nothingAskedWhenSeerrDoesNotApply() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1])])
        transport.setSeason("/tv/1399/season/1", seasonOneBody)
        let (app, session) = await seerrBench(api: partialSeasonAPI([1, 3]), transport: transport)
        let vm = makeViewModel(session, allowed: false)

        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value

        #expect(transport.seasonRequestCount == 0)
        #expect(vm.seerrEpisodes(for: session.snapshot()).isEmpty)
    }

    @Test("a failed lookup shows nothing")
    func failedLookupShowsNothing() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1])])
        let (app, session) = await seerrBench(api: partialSeasonAPI([1, 3]), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value

        #expect(transport.seasonRequestCount == 1)
        #expect(vm.seerrEpisodes(for: session.snapshot()).isEmpty)
    }

    @Test("a report sends ONE issue naming Seerr's media id, the season and the episodes")
    func reportSendsOneIssue() async {
        let tv = #"{"id":1399,"name":"Série du banc","seasons":[{"seasonNumber":1,"episodeCount":6}],"mediaInfo":{"id":77,"status":4}}"#
        let transport = DetailSeerrTransport(series: [1399: tv])
        transport.setSeason("/tv/1399/season/1", seasonOneBody)
        let (app, session) = await seerrBench(api: partialSeasonAPI([1, 3]), transport: transport)
        let vm = makeViewModel(session)
        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value
        let missing = vm.seerrEpisodes(for: session.snapshot())

        let message = SeerrEpisodeReportDraft.message(numbers: missing.map(\.episodeNumber), note: " merci ", loc: loc)
        #expect(await vm.reportMissingEpisodes(missing, message: message))

        #expect(transport.issues.count == 1)
        let sent = transport.issues.first ?? ""
        #expect(sent.contains(#""mediaId":77"#))
        #expect(sent.contains(#""problemSeason":1"#))
        #expect(sent.contains(#""problemEpisode":0"#))
        #expect(sent.contains(#""issueType":4"#))
        #expect(sent.contains("2, 4"))
        #expect(sent.contains("merci"))
        // Sent ⇒ never offered again from this fiche.
        #expect(vm.seerrEpisodes(for: session.snapshot()).allSatisfy { $0.isReported })
    }

    @Test("episodes an open report already names are marked reported, the others stay on offer")
    func openReportsMarkEpisodes() async {
        // CREATE_ISSUES + REQUEST: this account may report, so its open reports are read.
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1])], permissions: 4_194_336)
        transport.setSeason("/tv/1399/season/1", seasonOneBody)
        func row(_ id: Int, season: Int, tmdb: Int = 1399, type: Int = 4, _ message: String) -> String {
            #"{"id":\#(id),"issueType":\#(type),"status":1,"problemSeason":\#(season),"problemEpisode":0,"#
                + #""createdAt":"2026-11-11T10:00:00.000Z","media":{"id":8,"tmdbId":\#(tmdb),"mediaType":"tv"},"#
                + #""comments":[{"id":\#(id),"message":"\#(message)"}]}"#
        }
        let rows = [
            row(1, season: 1, "Missing episodes: 2"),
            row(2, season: 1, "L image est en 4:3"),          // a free text, not ours
            row(3, season: 2, "Missing episodes: 4"),          // another season
            row(4, season: 1, tmdb: 1, "Missing episodes: 4"), // another series
            row(5, season: 1, type: 1, "Missing episodes: 4")  // another kind
        ]
        transport.setOpenIssues(#"{"pageInfo":{"pages":1,"pageSize":100,"results":5,"page":1},"results":["#
            + rows.joined(separator: ",") + "]}")
        let (app, session) = await seerrBench(api: partialSeasonAPI([1, 3]), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value

        let missing = vm.seerrEpisodes(for: session.snapshot())
        #expect(missing.map(\.episodeNumber) == [2, 4])
        #expect(missing.map(\.isReported) == [true, false])
    }

    @Test("a failed read of the open reports still shows every missing episode")
    func failedOpenReportsReadOffersAll() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1])], permissions: 4_194_336)
        transport.setSeason("/tv/1399/season/1", seasonOneBody)
        let (app, session) = await seerrBench(api: partialSeasonAPI([1, 3]), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value

        let missing = vm.seerrEpisodes(for: session.snapshot())
        #expect(missing.map(\.episodeNumber) == [2, 4])
        #expect(!missing.contains { $0.isReported })
    }

    @Test("a complete season asks neither the series nor the library's numbering")
    func completeSeasonCostsNothingMore() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1])])
        transport.setSeason("/tv/1399/season/1", seasonOneBody)
        let api = partialSeasonAPI([1, 2, 3, 4])
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value

        #expect(vm.seerrEpisodes(for: session.snapshot()).isEmpty)
        #expect(api.getEpisodeNumberingCallCount == 0)
    }

    @Test("a library numbered otherwise than TMDb shows no missing episode")
    func otherNumberingShowsNothing() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1])])
        transport.setSeason("/tv/1399/season/1", seasonOneBody)
        let api = partialSeasonAPI([1, 3])
        // « 501 » for S01E01: past TMDb's 8 episodes.
        api.stubbedEpisodeNumbering = [EpisodeNumbering(season: 1, first: 101), EpisodeNumbering(season: 1, first: 103)]
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value

        #expect(api.getEpisodeNumberingCallCount == 1)
        #expect(vm.seerrEpisodes(for: session.snapshot()).isEmpty)
    }

    @Test("« Masquer pour cette série » hides at once, keeps it on this device, and « Annuler » brings them back")
    func hideForThisSeries() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1])])
        transport.setSeason("/tv/1399/season/1", seasonOneBody)
        let (app, session) = await seerrBench(api: partialSeasonAPI([1, 3]), transport: transport)
        let defaults = UserDefaults.isolatedForTesting()
        let vm = makeViewModel(session)
        vm.defaults = defaults
        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value
        #expect(!vm.seerrEpisodes(for: session.snapshot()).isEmpty)

        #expect(!vm.missingEpisodesHidden)
        vm.hideMissingEpisodes()
        #expect(vm.missingEpisodesHidden)
        #expect(vm.seerrEpisodes(for: session.snapshot()).isEmpty)
        #expect(defaults.array(forKey: SettingsKey.seerrHiddenMissingEpisodes) as? [Int] == [1399])

        // Reopened: nothing is even asked.
        let again = makeViewModel(session)
        again.defaults = defaults
        let asked = transport.seasonRequestCount
        await again.load(using: app, loc: loc)
        await again.seerrEpisodesTask?.value
        #expect(again.seerrEpisodes(for: session.snapshot()).isEmpty)
        #expect(again.missingEpisodesHidden)
        #expect(transport.seasonRequestCount == asked)

        again.unhideMissingEpisodes(using: app)
        // The « masqués » line stays until the answer (tvOS hands the focus on).
        #expect(again.missingEpisodesHidden)
        await again.seerrEpisodesTask?.value
        #expect(again.seerrEpisodes(for: session.snapshot()).map(\.episodeNumber) == [2, 4])
        #expect(!again.missingEpisodesHidden)
        #expect(defaults.array(forKey: SettingsKey.seerrHiddenMissingEpisodes) as? [Int] == [])
    }

    @Test("a title Seerr does not know cannot be reported")
    func unknownMediaIsNotReported() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1])])
        transport.setSeason("/tv/1399/season/1", seasonOneBody)
        let (app, session) = await seerrBench(api: partialSeasonAPI([1, 3]), transport: transport)
        let vm = makeViewModel(session)
        await vm.load(using: app, loc: loc)
        await vm.seerrEpisodesTask?.value
        let missing = vm.seerrEpisodes(for: session.snapshot())

        #expect(await vm.reportMissingEpisodes(missing, message: "x") == false)
        #expect(transport.issues.isEmpty)
        #expect(!vm.seerrEpisodes(for: session.snapshot()).contains { $0.isReported })
    }
}

@MainActor
@Suite("Detail — missing seasons")
struct MediaDetailMissingSeasonsTests {
    private let loc = LocalizationManager()

    private func makeViewModel(_ session: SeerrSession, allowed: Bool = true) -> MediaDetailViewModel {
        let vm = MediaDetailViewModel(itemId: "series-1", itemType: .series)
        vm.seerr = session
        vm.allowsSeerr = { allowed }
        vm.seerrDeadline = neverExpires
        return vm
    }

    @Test("the owned seasons are on screen before Seerr answers; the missing ones follow, ascending")
    func missingSeasonsAfterOwned() async {
        let gate = TestLatch()
        let transport = DetailSeerrTransport(
            series: [1399: seerrTVBody(1399, seasons: [3, 1, 6, 2, 5, 0, 4])], gates: [1399: gate])
        let (app, session) = await seerrBench(api: ownedSeriesAPI(), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await transport.tvArrived.wait()

        // Seerr is held: the fiche is painted with what the library owns.
        #expect(!vm.isLoading)
        #expect(vm.seasons.compactMap(\.indexNumber) == [1, 2, 3])
        #expect(!vm.episodes.isEmpty)
        #expect(vm.seerrSeasons == .loading)

        gate.open()
        await vm.seerrSeasonsTask?.value
        // Seerr's order is not the row's: ascending, specials left out.
        #expect(vm.seerrSeasons == .loaded(missingSeasons(1399, [4, 5, 6])))
        #expect(vm.seerrSeasons(for: session.snapshot()) == vm.seerrSeasons)
        #expect(vm.seerrSeasons(for: SeerrSession.Snapshot(accountKey: "S1|B", generation: 99)) == .hidden)
        #expect(vm.seerrSeriesTitle == SeerrTitle(kind: .tv, tmdbId: 1399, title: "Série du banc", year: 2011))
    }

    @Test("specials are offered only when Seerr enables them")
    func specialsOnlyWhenEnabled() async {
        let transport = DetailSeerrTransport(
            series: [1399: seerrTVBody(1399, seasons: [0, 1, 2, 3, 4])], specials: true)
        let (app, session) = await seerrBench(api: ownedSeriesAPI(), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrSeasonsTask?.value

        #expect(vm.seerrSeasons == .loaded(missingSeasons(1399, [0, 4])))
    }

    @Test("no TMDb id on the series: no Seerr call, nothing shown")
    func noTmdbIdNoCall() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1, 2, 3, 4])])
        let (app, session) = await seerrBench(api: ownedSeriesAPI(tmdb: nil), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrSeasonsTask?.value

        #expect(vm.seerrSeasons == .hidden)
        #expect(transport.tvRequestCount == 0)
        #expect(vm.seerrSeriesTitle == nil)
    }

    @Test("not allowed (Pro, cap, offline…): no Seerr call at all")
    func notAllowedNoCall() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1, 2, 3, 4])])
        let (app, session) = await seerrBench(api: ownedSeriesAPI(), transport: transport)
        let vm = makeViewModel(session, allowed: false)

        await vm.load(using: app, loc: loc)
        await vm.seerrSeasonsTask?.value

        #expect(vm.seerrSeasons == .hidden)
        #expect(transport.tvRequestCount == 0)
    }

    @Test("an answer for a fiche the screen has moved past is dropped")
    func staleSeasonsDropped() async {
        // The first load matches TMDb 1399, held; an identify then reloads the
        // fiche (tier-1), now matched to 1400, which answers at once.
        let gate = TestLatch()
        let transport = DetailSeerrTransport(
            series: [1399: seerrTVBody(1399, seasons: [1, 2, 3, 4, 5, 6]), 1400: seerrTVBody(1400, seasons: [1, 2, 3, 4])],
            gates: [1399: gate])
        let api = ownedSeriesAPI(tmdbForCall: { $0 == 1 ? "1399" : "1400" })
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await transport.tvArrived.wait()
        let first = vm.seerrSeasonsTask
        await vm.load(using: app, loc: loc)
        await vm.seerrSeasonsTask?.value
        gate.open()
        await first?.value

        #expect(vm.seerrSeasons == .loaded(missingSeasons(1400, [4])))
    }

    @Test("a playback refresh while Seerr answers keeps the row")
    func playbackRefreshKeepsTheRow() async {
        let gate = TestLatch()
        let transport = DetailSeerrTransport(
            series: [1399: seerrTVBody(1399, seasons: [1, 2, 3, 4])], gates: [1399: gate])
        let (app, session) = await seerrBench(api: ownedSeriesAPI(), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await transport.tvArrived.wait()
        // Bumps `loadGeneration` without reloading Seerr.
        await vm.refreshAfterPlayback(using: app)
        gate.open()
        await vm.seerrSeasonsTask?.value

        #expect(vm.seerrSeasons == .loaded(missingSeasons(1399, [4])))
    }

    @Test("a pass cancelled before it starts writes nothing — not even the skeleton")
    func cancelledPassWritesNothing() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1, 2, 3, 4])])
        let (app, session) = await seerrBench(api: ownedSeriesAPI(), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        // Still enqueued: a newer pass (or the screen going away) cancels it
        // before it ever runs.
        vm.seerrSeasonsTask?.cancel()
        await vm.seerrSeasonsTask?.value

        #expect(vm.seerrSeasons == .hidden)
        #expect(transport.tvRequestCount == 0)
    }

    @Test("a one-season series still gets its row")
    func oneSeasonSeriesStillGetsRow() async {
        let transport = DetailSeerrTransport(series: [1399: seerrTVBody(1399, seasons: [1, 2, 3])])
        let (app, session) = await seerrBench(api: ownedSeriesAPI(owned: [1]), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrSeasonsTask?.value

        #expect(vm.seasons.count == 1)
        #expect(vm.seerrSeasons == .loaded(missingSeasons(1399, [2, 3])))
    }

    @Test("an unreachable Seerr hides the row and leaves the fiche alone")
    func unreachableSeerrHidesTheRow() async {
        // No `/tv` answer at all: the transport throws.
        let transport = DetailSeerrTransport(series: [:])
        let (app, session) = await seerrBench(api: ownedSeriesAPI(), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.seerrSeasonsTask?.value

        #expect(vm.seerrSeasons == .hidden)
        #expect(vm.errorMessage == nil)
        #expect(vm.seasons.count == 3)
    }
}

@MainActor
@Suite("Seerr season request entry point")
struct SeerrSeasonRequestTests {
    private let loc = LocalizationManager()
    private let series = SeerrTitle(kind: .tv, tmdbId: 1399, title: "Série du banc", year: 2011)

    @Test("a season card opens the picker over every requestable season, that one ticked")
    func seasonCardPreselectsItsSeason() {
        let presenter = SeerrRequestPresenter()
        let missing = missingSeasons(1399, [4, 5, 6])

        presenter.request(season: missing[1], among: missing, of: series, loc: loc, toasts: ToastCenter())

        #expect(presenter.draft == .series(series, seasons: [4, 5, 6], preselected: [5]))
    }

    @Test("« Demander les N » ticks every requestable season")
    func requestAllTicksThemAll() {
        let presenter = SeerrRequestPresenter()
        let missing = missingSeasons(1399, [6, 4, 5])

        presenter.requestAll(missing, of: series, loc: loc, toasts: ToastCenter())

        #expect(presenter.draft == .series(series, seasons: [4, 5, 6], preselected: [4, 5, 6]))
    }

    @Test("a season already asked for: « Déjà demandé », nothing opens, and the others' picker leaves it out")
    func alreadyRequestedSeasonShowsInfo() {
        let presenter = SeerrRequestPresenter()
        let toasts = ToastCenter()
        let missing = [
            SeerrMissingSeason(seriesTmdbId: 1399, seasonNumber: 4, badge: .pending),
            SeerrMissingSeason(seriesTmdbId: 1399, seasonNumber: 5, badge: .declined),
            SeerrMissingSeason(seriesTmdbId: 1399, seasonNumber: 6, badge: .processing),
        ]

        presenter.request(season: missing[0], among: missing, of: series, loc: loc, toasts: toasts)
        #expect(presenter.draft == nil)
        #expect(toasts.current?.level == .info)
        #expect(toasts.current?.title == loc.localized("seerr.request.duplicate"))
        #expect(toasts.current?.message == loc.localized("seerr.request.already.pending"))

        presenter.request(season: missing[2], among: missing, of: series, loc: loc, toasts: toasts)
        #expect(presenter.draft == nil)
        #expect(toasts.current?.message == loc.localized("seerr.request.already.processing"))

        // Declined may be asked again — alone: the two others are already out.
        #expect(presenter.requestableSeasons(missing) == [5])
        presenter.request(season: missing[1], among: missing, of: series, loc: loc, toasts: toasts)
        #expect(presenter.draft == .series(series, seasons: [5], preselected: [5]))
    }

    @Test("a season just requested counts as requested, without reloading the row")
    func justRequestedSeasonCounts() async {
        let transport = DetailSeerrTransport(series: [:])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let presenter = SeerrRequestPresenter()
        let toasts = ToastCenter()
        let missing = missingSeasons(1399, [4, 5])

        await presenter.submit(
            .series(series, seasons: [4, 5], preselected: [4]), selection: [4],
            session: session, loc: loc, toasts: toasts)
        #expect(presenter.badge(for: missing[0].id, default: .request) == .pending)
        #expect(presenter.requestableSeasons(missing) == [5])

        presenter.request(season: missing[0], among: missing, of: series, loc: loc, toasts: toasts)
        #expect(presenter.draft == nil)
        #expect(toasts.current?.message == loc.localized("seerr.request.already.pending"))
    }
}

// MARK: - Seerr — the missing films of a saga

/// `/collection/{id}` as Seerr answers it: `parts` without `mediaType`, in
/// Seerr's (TMDb's) order — not the release order. `status` is Seerr's media
/// status for that part (4/5/6 = it has it), `nil` = Seerr knows nothing.
private func seerrCollectionBody(_ id: Int, name: String, parts: [(tmdb: Int, year: Int, status: Int?)]) -> String {
    let list = parts.map { part -> String in
        let info = part.status.map { #","mediaInfo":{"status":\#($0)}"# } ?? ""
        return #"{"id":\#(part.tmdb),"title":"Film \#(part.tmdb)","releaseDate":"\#(part.year)-06-01"\#(info)}"#
    }.joined(separator: ",")
    return #"{"id":\#(id),"name":"\#(name)","parts":[\#(list)]}"#
}

/// TMDb collection 1241: 671 and 672 are the library's, 674 is available in
/// Seerr only (Jellyfin can't prove it owns it), 675 is pending.
private let sagaBody = seerrCollectionBody(1241, name: "Saga du banc", parts: [
    (675, 2007, 2), (671, 2001, nil), (673, 2004, nil), (672, 2002, nil), (674, 2005, 5),
])

/// A film of the library, matched to TMDb `tmdb`.
private func ownedFilm(_ tmdb: Int, year: Int) -> BaseItemDto {
    var film = makeMovie(id: "movie-\(tmdb)", played: false)
    film.name = "Film \(tmdb)"
    film.productionYear = year
    film.providerIDs = ["Tmdb": String(tmdb)]
    return film
}

/// A movie fiche for film 671 of TMDb collection 1241. `boxSet` = the
/// library's BoxSet holding it (`getCollections`), whose members are
/// `members`; `nil` ⇒ in no BoxSet. `collectionsGate` holds the FIRST
/// `getCollections` call; `collectionsArrived` opens when it arrives.
private func sagaMovieAPI(
    boxSet: Bool = true, members: [BaseItemDto] = [ownedFilm(671, year: 2001), ownedFilm(672, year: 2002)],
    collectionsGate: TestLatch? = nil, collectionsArrived: TestLatch? = nil, boxSetOnCall: (@Sendable (Int) -> Bool)? = nil
) -> MockAPIClient {
    let api = MockAPIClient()
    api.getItemHandler = { _ in
        var film = ownedFilm(671, year: 2001)
        film.providerIDs = ["Tmdb": "671", "TmdbCollection": "1241"]
        return film
    }
    let calls = CallCounter()
    api.getCollectionsHandler = { _, _ in
        let call = calls.next()
        if call == 1 {
            collectionsArrived?.open()
            await collectionsGate?.wait()
        }
        guard boxSetOnCall?(call) ?? boxSet else { return [] }
        var collection = BaseItemDto()
        collection.id = "boxset-1"
        collection.name = "Saga du banc"
        collection.type = .boxSet
        return [collection]
    }
    api.stubbedItems = members
    api.stubbedTotalCount = members.count
    return api
}

/// A BoxSet fiche of TMDb collection 1241 (`providers`), holding `children`.
private func sagaBoxSetAPI(
    providers: [String: String] = ["TmdbCollection": "1241"],
    children: [BaseItemDto] = [ownedFilm(671, year: 2001), ownedFilm(672, year: 2002)]
) -> MockAPIClient {
    let api = MockAPIClient()
    api.getItemHandler = { id in
        var collection = BaseItemDto()
        collection.id = id
        collection.name = "Saga du banc"
        collection.type = .boxSet
        collection.providerIDs = providers
        return collection
    }
    api.stubbedItems = children
    api.stubbedTotalCount = children.count
    return api
}

/// `allowsSeerr`'s answer, flipped by a test mid-pass.
@MainActor
private final class VisibilityBox {
    var isOn = false
}

/// The section's titles as `kind-tmdbId` + badge, `nil` unless loaded.
private func sagaEntries(_ section: MissingSection<SeerrMissingTitle>) -> [String]? {
    guard case .loaded(let missing) = section else { return nil }
    return missing.map { "\($0.id) \($0.badge)" }
}

@MainActor
@Suite("Detail — saga")
struct MediaDetailSagaTests {
    private let loc = LocalizationManager()

    private func makeViewModel(
        _ session: SeerrSession, itemId: String = "movie-671", type: BaseItemKind = .movie, allowed: Bool = true
    ) -> MediaDetailViewModel {
        let vm = MediaDetailViewModel(itemId: itemId, itemType: type)
        vm.seerr = session
        vm.allowsSeerr = { allowed }
        vm.seerrDeadline = neverExpires
        return vm
    }

    @Test("BoxSet fiche: the owned members unchanged, then only the films the library lacks, in release order")
    func boxSetSectionListsOnlyMissing() async {
        let transport = DetailSeerrTransport(series: [:], collections: [1241: sagaBody])
        let api = sagaBoxSetAPI()
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session, itemId: "boxset-1", type: .boxSet)

        await vm.load(using: app, loc: loc)
        await vm.collectionTask?.value

        #expect(vm.collectionChildren.compactMap(\.id) == ["movie-671", "movie-672"])
        // 671 / 672 owned by Jellyfin, 674 available in Seerr: never offered.
        #expect(sagaEntries(vm.seerrSaga) == ["movie-673 request", "movie-675 pending"])
        #expect(vm.seerrSaga(for: session.snapshot()) == vm.seerrSaga)
        #expect(vm.seerrSaga(for: SeerrSession.Snapshot(accountKey: "S1|B", generation: 99)) == .hidden)
        #expect(vm.sagaPlacement == .afterCollectionContents)
        // The members carry their TMDb ids only while Seerr may show.
        #expect(api.getItemsQueries.last?.fieldSet == .cardWithProviderIds)
    }

    @Test("BoxSet matched by Jellyfin's TMDb provider (`Tmdb`, no `TmdbCollection`): same section")
    func boxSetTmdbProviderCounts() async {
        let transport = DetailSeerrTransport(series: [:], collections: [1241: sagaBody])
        let (app, session) = await seerrBench(api: sagaBoxSetAPI(providers: ["Tmdb": "1241"]), transport: transport)
        let vm = makeViewModel(session, itemId: "boxset-1", type: .boxSet)

        await vm.load(using: app, loc: loc)
        await vm.collectionTask?.value

        #expect(sagaEntries(vm.seerrSaga) == ["movie-673 request", "movie-675 pending"])
    }

    @Test("movie in a « Fait partie de » row: the missing films come AFTER the owned cards, which keep their index")
    func movieRowAppendsAtEnd() async {
        let transport = DetailSeerrTransport(series: [:], collections: [1241: sagaBody])
        let api = sagaMovieAPI()
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.collectionTask?.value

        #expect(vm.collectionItems.compactMap(\.id) == ["movie-672"])
        #expect(sagaEntries(vm.seerrSaga) == ["movie-673 request", "movie-675 pending"])
        #expect(vm.sagaPlacement == .appendedToPartOfRow)
        #expect(api.getItemsQueries.last?.fieldSet == .cardWithProviderIds)
        // The whole BoxSet, like a BoxSet fiche's members: the row is the
        // owned set, and a 20-film cap would offer a film the library holds.
        #expect(api.getItemsQueries.last?.limit == 100)

        // The row: owned first, untouched; then the missing cards, or the
        // skeletons while loading; the action card closes it.
        let owned = vm.collectionItems
        #expect(MediaDetailSimilarSection.rowItems(owned: owned, trailing: .hidden, showsRequestAll: false).map(\.id)
            == ["owned-movie-672"])
        #expect(MediaDetailSimilarSection.rowItems(owned: owned, trailing: .loading, showsRequestAll: false).map(\.id)
            == ["owned-movie-672", "skeleton-0", "skeleton-1"])
        #expect(MediaDetailSimilarSection.rowItems(owned: owned, trailing: vm.seerrSaga, showsRequestAll: true).map(\.id)
            == ["owned-movie-672", "missing-movie-673", "missing-movie-675", "requestAll"])
        #expect(MediaDetailSimilarSection.rowItems(owned: owned, trailing: .loaded([]), showsRequestAll: true).map(\.id)
            == ["owned-movie-672"])
    }

    @Test("movie in no BoxSet but with a TMDb collection: a new row, named after the saga, at the end of the fiche")
    func noRowMakesNewRowAtEnd() async {
        let transport = DetailSeerrTransport(series: [:], collections: [1241: sagaBody])
        let (app, session) = await seerrBench(api: sagaMovieAPI(boxSet: false), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.collectionTask?.value

        #expect(vm.collectionItems.isEmpty)
        #expect(vm.sagaPlacement == .endOfFiche)
        #expect(vm.sagaName == "Saga du banc")
        // Nothing but the fiche's own film proves ownership here: 672 is
        // offered, 674 is dropped on Seerr's word alone.
        #expect(sagaEntries(vm.seerrSaga) == ["movie-672 request", "movie-673 request", "movie-675 pending"])
    }

    @Test("the fiche's own film is never listed, even when Seerr does not know it is available")
    func currentMovieNeverListed() async {
        let body = seerrCollectionBody(1241, name: "Saga du banc", parts: [(671, 2001, nil), (672, 2002, nil)])
        let transport = DetailSeerrTransport(series: [:], collections: [1241: body])
        let (app, session) = await seerrBench(api: sagaMovieAPI(boxSet: false), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.collectionTask?.value

        #expect(sagaEntries(vm.seerrSaga) == ["movie-672 request"])
    }

    @Test("a superseded pass writes neither the collection row nor the saga")
    func collectionLoadersAreGenerationGuarded() async {
        // Pass 1 finds the BoxSet, but late; an identify reloads the fiche
        // (tier-1) and pass 2 finds no BoxSet at once.
        let gate = TestLatch()
        let arrived = TestLatch()
        let transport = DetailSeerrTransport(series: [:], collections: [1241: sagaBody])
        let api = sagaMovieAPI(collectionsGate: gate, collectionsArrived: arrived, boxSetOnCall: { $0 == 1 })
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await arrived.wait()
        let first = vm.collectionTask
        await vm.load(using: app, loc: loc)
        await vm.collectionTask?.value
        gate.open()
        await first?.value

        #expect(vm.collectionItems.isEmpty)
        #expect(vm.collectionName == nil)
        #expect(sagaEntries(vm.seerrSaga) == ["movie-672 request", "movie-673 request", "movie-675 pending"])
    }

    @Test("a playback refresh while the collection loads keeps the row and the saga")
    func playbackRefreshKeepsTheSaga() async {
        let gate = TestLatch()
        let arrived = TestLatch()
        let transport = DetailSeerrTransport(series: [:], collections: [1241: sagaBody])
        let (app, session) = await seerrBench(
            api: sagaMovieAPI(collectionsGate: gate, collectionsArrived: arrived), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await arrived.wait()
        // Bumps `loadGeneration` without reloading the collection.
        await vm.refreshAfterPlayback(using: app)
        gate.open()
        await vm.collectionTask?.value

        #expect(vm.collectionItems.compactMap(\.id) == ["movie-672"])
        #expect(sagaEntries(vm.seerrSaga) == ["movie-673 request", "movie-675 pending"])
    }

    @Test("not allowed (Pro, cap, offline…): the row as today — lean members, no Seerr call")
    func notAllowedLeavesTheRowAlone() async {
        let transport = DetailSeerrTransport(series: [:], collections: [1241: sagaBody])
        let api = sagaMovieAPI()
        let (app, session) = await seerrBench(api: api, transport: transport)
        let vm = makeViewModel(session, allowed: false)

        await vm.load(using: app, loc: loc)
        await vm.collectionTask?.value

        #expect(vm.collectionItems.compactMap(\.id) == ["movie-672"])
        #expect(vm.seerrSaga == .hidden)
        #expect(transport.collectionRequestCount == 0)
        #expect(api.getItemsQueries.last?.fieldSet == .card)
        #expect(api.getItemsQueries.last?.limit == 20)
    }

    @Test("one decision per pass: Seerr turning visible mid-pass asks nothing — members fetched without their TMDb ids prove nothing")
    func sagaDecidedOncePerPass() async {
        let gate = TestLatch()
        let arrived = TestLatch()
        let transport = DetailSeerrTransport(series: [:], collections: [1241: sagaBody])
        let api = sagaMovieAPI(collectionsGate: gate, collectionsArrived: arrived)
        let (app, session) = await seerrBench(api: api, transport: transport)
        let visible = VisibilityBox()
        let vm = makeViewModel(session)
        vm.allowsSeerr = { visible.isOn }

        await vm.load(using: app, loc: loc)
        await arrived.wait()
        // Back online / Pro granted while the BoxSet lookup is in flight.
        visible.isOn = true
        gate.open()
        await vm.collectionTask?.value

        #expect(vm.collectionItems.compactMap(\.id) == ["movie-672"])
        #expect(api.getItemsQueries.last?.fieldSet == .card)
        #expect(api.getItemsQueries.last?.limit == 20)
        #expect(vm.seerrSaga == .hidden)
        #expect(transport.collectionRequestCount == 0)
    }

    @Test("an unreachable Seerr hides the saga and leaves the collection row alone")
    func unreachableSeerrHidesTheSaga() async {
        let transport = DetailSeerrTransport(series: [:])
        let (app, session) = await seerrBench(api: sagaMovieAPI(), transport: transport)
        let vm = makeViewModel(session)

        await vm.load(using: app, loc: loc)
        await vm.collectionTask?.value

        #expect(vm.seerrSaga == .hidden)
        #expect(vm.errorMessage == nil)
        #expect(vm.collectionItems.compactMap(\.id) == ["movie-672"])
    }

    @Test("« Demander les N »: every requestable film, all ticked; none left ⇒ « Déjà demandé »")
    func requestAllFilms() {
        let presenter = SeerrRequestPresenter()
        let toasts = ToastCenter()
        func film(_ id: Int, _ badge: SeerrBadge) -> SeerrMissingTitle {
            SeerrMissingTitle(title: SeerrTitle(kind: .movie, tmdbId: id, title: "Film \(id)", year: 2004), badge: badge)
        }
        let missing = [film(673, .request), film(675, .pending), film(676, .declined), film(677, .processing)]

        #expect(presenter.requestableFilms(missing).map(\.id) == ["movie-673", "movie-676"])
        presenter.requestAll(films: missing, loc: loc, toasts: toasts)
        #expect(presenter.draft == .films([missing[0].title, missing[2].title]))

        presenter.draft = nil
        presenter.requestAll(films: [missing[1], missing[3]], loc: loc, toasts: toasts)
        #expect(presenter.draft == nil)
        #expect(toasts.current?.level == .info)
        #expect(toasts.current?.title == loc.localized("seerr.request.duplicate"))
    }
}
