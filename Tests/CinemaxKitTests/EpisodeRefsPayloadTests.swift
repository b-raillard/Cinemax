import Foundation
import Testing
import JellyfinAPI
@testable import Cinemax
@testable import CinemaxKit

/// R1 of the 2026-09-10 platform audit: `getEpisodes` was the app's single
/// largest payload, and its heaviest consumer — episode NAVIGATION — read two
/// fields of it.
///
/// Measured against the reference server (Jellyfin 12.0) on 2026-09-10, one
/// season at a time, with and without the fields the app asks for:
///
///     Arrow   23 épisodes   164 069 o → 18 292 o   9.0×
///     Arcane   9 épisodes    64 426 o →  7 285 o   8.8×
///     Ahsoka   8 épisodes    53 488 o →  6 672 o   8.0×
///                           ─────────────────────
///                           281 983 o → 32 249 o   8.7×
///
/// A Home load resolves up to 40 distinct seasons, and re-resolves them on
/// every tier-1 refresh and pull-to-refresh.
@Suite("Episode refs payload")
struct EpisodeRefsPayloadTests {

    // MARK: - The cache contract

    /// **The load-bearing half of the split.** `episodes-` is swept by every
    /// userData mutator because its payload carries watched marks and resume
    /// positions. `episoderefs-` carries NONE (`enableUserData: false`, no
    /// `fields`), so it must NOT be in that list: an episode's id and title
    /// change only on a library re-scan, and sweeping it would re-fetch an
    /// identical answer after every watched toggle anywhere in the app.
    @Test("episoderefs- is NOT swept by the userData mutators")
    func episodeRefsSurviveAUserDataSweep() {
        let cache = APICache()
        cache.set("episodes-season1-user1", value: ["full"], ttl: 10)
        cache.set("episoderefs-season1-user1", value: ["lean"], ttl: 300)

        for prefix in JellyfinAPIClient.userDataCachePrefixes {
            cache.invalidate(prefix: prefix)
        }

        let full: [String]? = cache.get("episodes-season1-user1")
        let lean: [String]? = cache.get("episoderefs-season1-user1")
        #expect(full == nil, "the userData-bearing list must still be swept")
        #expect(lean == ["lean"], "the lean list carries no userData — nothing can make it stale")
        #expect(JellyfinAPIClient.userDataCachePrefixes.contains("episoderefs-") == false)
    }

    /// The two keys are distinct, so filling one never serves the other: a
    /// navigation fetch must not poison the detail screen's full list (which
    /// would leave it without watched marks), nor be served BY it.
    @Test("the lean and full episode caches are separate keys")
    func cachesDoNotAlias() {
        let cache = APICache()
        cache.set("episodes-season1-user1", value: ["full"], ttl: 10)

        let lean: [String]? = cache.get("episoderefs-season1-user1")
        #expect(lean == nil)
    }

    // MARK: - The navigation derived from it

    @Test("prev/next are derived from the lean refs exactly as from the full DTOs")
    func navigationMatchesTheFullShape() {
        let refs = [
            EpisodeReference(id: "e1", name: "Pilot"),
            EpisodeReference(id: "e2", name: "Honor Thy Father"),
            EpisodeReference(id: "e3", name: "Lone Gunmen"),
        ]

        let middle = buildEpisodeNavigation(for: "e2", in: refs)
        #expect(middle.previous?.id == "e1")
        #expect(middle.previous?.title == "Pilot")
        #expect(middle.next?.id == "e3")
        #expect(middle.navigator != nil)

        let first = buildEpisodeNavigation(for: "e1", in: refs)
        #expect(first.previous == nil)
        #expect(first.next?.id == "e2")

        let last = buildEpisodeNavigation(for: "e3", in: refs)
        #expect(last.previous?.id == "e2")
        #expect(last.next == nil)
    }

    /// A one-episode season yields no navigator at all — handing the player an
    /// empty trio would behave like `nil` while claiming navigation exists.
    @Test("a single-episode season yields no navigator")
    func singleEpisodeSeasonHasNoNavigator() {
        let nav = buildEpisodeNavigation(for: "e1", in: [EpisodeReference(id: "e1", name: "Only")])
        #expect(nav.navigator == nil)
        #expect(nav.previous == nil)
        #expect(nav.next == nil)
    }

    /// The navigator answers for ANY episode of the season, not just the one it
    /// was built around — that is what lets the player step through a whole
    /// season without re-fetching.
    @Test("the navigator covers every episode of the season")
    func navigatorCoversTheSeason() throws {
        let refs = (1...4).map { EpisodeReference(id: "e\($0)", name: "E\($0)") }
        let navigator = try #require(buildEpisodeNavigation(for: "e1", in: refs).navigator)

        let atThree = try #require(navigator("e3"))
        #expect(atThree.0?.id == "e2")
        #expect(atThree.1?.id == "e4")
        #expect(navigator("nope") == nil)
    }

    // MARK: - Who asks for which shape

    @MainActor
    @Test("Home's navigation maps ask for the lean list, never the full one")
    func homeUsesTheLeanList() async {
        let api = MockAPIClient()
        var episode = BaseItemDto()
        episode.id = "ep-2"
        episode.type = .episode
        episode.seasonID = "season-1"
        episode.seriesID = "series-1"
        api.stubbedResumeItems = [episode]
        api.getEpisodeRefsHandler = { _ in
            [EpisodeReference(id: "ep-1", name: "E1"), EpisodeReference(id: "ep-2", name: "E2")]
        }
        let appState = AppState(apiClient: api, keychain: MockKeychain())
        appState.currentUserId = "user1"
        let vm = HomeViewModel()

        await vm.load(using: appState)

        #expect(api.getEpisodeRefsCallCount == 1)
        #expect(api.getEpisodesCallCount == 0)
        #expect(vm.resumeNavigation["ep-2"]?.previous?.id == "ep-1")
    }
}
