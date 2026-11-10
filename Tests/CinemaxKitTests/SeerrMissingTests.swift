import Foundation
import Testing
import JellyfinAPI
@testable import CinemaxKit
@testable import Cinemax

// MARK: - Fixtures

private func movie(_ id: Int, _ status: SeerrMediaStatus? = nil, requests: [SeerrRequestSummary] = []) -> SeerrTitle {
    SeerrTitle(
        kind: .movie, tmdbId: id, title: "M\(id)",
        mediaInfo: status.map { SeerrMediaInfo(status: $0, requests: requests) })
}

private func tvTitle(_ id: Int) -> SeerrTitle {
    SeerrTitle(kind: .tv, tmdbId: id, title: "T\(id)")
}

private func creditKey(_ title: SeerrTitle) -> String {
    "\(title.kind.rawValue)-\(title.tmdbId)"
}

private func show(
    seasons: [Int], info: SeerrMediaInfo? = nil
) -> SeerrTVDetails {
    SeerrTVDetails(
        tmdbId: 9, name: "S", seasons: seasons.map { SeerrSeason(seasonNumber: $0, episodeCount: 8) },
        mediaInfo: info)
}

private func owned(_ providers: [String: String], _ type: BaseItemKind = .movie) -> BaseItemDto {
    var item = BaseItemDto()
    item.type = type
    item.providerIDs = providers
    return item
}

/// A session connected as Alice on a fresh stub; the op closures under test
/// never reach the network.
@MainActor
private func connectedSession() async -> (SeerrSession, AppState) {
    let bench = await requestBench()
    return (bench.session, bench.app)
}

/// `connectedSession`, parameterised by the user's Seerr permissions and the
/// server's partial-requests switch, and handing back the stub so a test can
/// queue the answers to the POSTs it triggers.
@MainActor
private func requestBench(
    permissions: Int = 32, partialRequests: Bool = true
) async -> (session: SeerrSession, app: AppState, stub: StubSeerrTransport) {
    let url = URL(string: "http://192.168.1.20:5055")!
    let jellyfin = URL(string: "https://maison.local")!
    let api = MockAPIClient()
    api.displayPreferences["me|\(SeerrUserConfig.preferencesId)|\(SeerrUserConfig.client)"] =
        SeerrUserConfig.merged(SeerrUserConfig(isEnabled: true, url: url), into: nil)
    let keychain = MockKeychain()
    keychain.savedServers = [ServerEntry(
        id: "S1", name: "Maison", url: jellyfin, serverID: "srv",
        accessToken: "tokA", userId: "A", username: "A", lastUsedAt: Date(timeIntervalSince1970: 1_000))]
    keychain.savedActiveServerId = "S1"
    let app = AppState(apiClient: api, keychain: keychain)
    app.settingsDefaults = .isolatedForTesting()
    app.loadServersFromKeychain()
    app.serverURL = jellyfin
    app.hasServer = true
    app.isAuthenticated = true
    app.accessToken = "tokA"
    app.currentUserId = "A"
    var user = UserDto()
    user.id = "A"
    user.policy = UserPolicy(authenticationProviderID: "", passwordResetProviderID: "")
    app.currentUser = user

    let stub = StubSeerrTransport([
        .response(status: 200, body: #"{"mediaServerType":2,"partialRequestsEnabled":\#(partialRequests)}"#),
        .response(status: 200, body: #"{"id":7,"permissions":\#(permissions),"jellyfinUserId":"A","displayName":"Alice"}"#),
    ])
    let storage = MockKeychain()
    storage.saveSeerrSessions(["S1|A": SeerrBoundSecret(value: "abc", origin: url)])
    let session = SeerrSession(storage: storage, defaults: .isolatedForTesting(), transport: stub, signInPause: {})
    session.proAllowsProvider = { true }
    session.activeAccountKeyProvider = { [app] in app.activeAccountKey }
    await session.reload(appState: app)
    return (session, app, stub)
}

/// `status`: 1 = pending (what an ordinary user's POST answers), 2 = approved
/// (what Seerr answers a user it auto-approves).
private func created(_ type: String = "movie", id: Int = 1, status: Int = 1) -> StubSeerrTransport.Reply {
    .response(status: 201, body: """
    {"id":\(id),"status":\(status),"type":"\(type)","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z",
    "requestedBy":{"id":7,"permissions":32},"media":{"tmdbId":1,"status":3}}
    """)
}

@MainActor
private func sentBody(_ stub: StubSeerrTransport, _ index: Int) -> [String: Any]? {
    stub.requests.filter { $0.httpMethod == "POST" }[safe: index]?.httpBody
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var didFire: Bool { lock.withLock { fired } }
    func fire() { lock.withLock { fired = true } }
}

// MARK: - Suite

@MainActor
@Suite("Seerr missing")
struct SeerrMissingTests {

    // MARK: loadSection

    @Test("a slow Seerr hides its section once the deadline passes")
    func slowSeerrSkeletonExpires() async {
        let (session, _) = await connectedSession()
        let started = TestLatch()
        let gate = TestLatch()

        let load = Task {
            await session.loadSection(deadline: { await gate.wait() }) { _, _ -> [Int] in
                started.open()
                // Never served: parked until the race cancels it.
                let parked = TestLatch()
                await withTaskCancellationHandler { await parked.wait() } onCancel: { parked.open() }
                try Task.checkCancellation()
                return [1]
            }
        }
        await started.wait()
        gate.open()

        #expect(await load.value == .hidden)
    }

    @Test("an answer lands as loaded, before the deadline")
    func answerWinsTheRace() async {
        let (session, _) = await connectedSession()
        let never = TestLatch()

        let section = await session.loadSection(deadline: {
            await withTaskCancellationHandler { await never.wait() } onCancel: { never.open() }
        }) { _, _ -> [Int] in [1, 2] }

        #expect(section == .loaded([1, 2]))
    }

    @Test("an account switch during the call yields nil, not hidden")
    func staleSectionIsNil() async {
        let (session, app) = await connectedSession()
        let never = TestLatch()

        let section = await session.loadSection(deadline: {
            await withTaskCancellationHandler { await never.wait() } onCancel: { never.open() }
        }) { [app] _, _ -> [Int] in
            await MainActor.run { app.currentUserId = "B" }
            return [1]
        }

        #expect(section == nil)
    }

    @Test("an error hides the section")
    func errorIsHidden() async {
        let (session, _) = await connectedSession()
        let never = TestLatch()

        let section = await session.loadSection(deadline: {
            await withTaskCancellationHandler { await never.wait() } onCancel: { never.open() }
        }) { _, _ -> [Int] in throw SeerrError.unreachable }

        #expect(section == .hidden)
    }

    @Test("no account means nil and no call")
    func noAccountIsNil() async {
        let session = SeerrSession(
            storage: MockKeychain(), defaults: .isolatedForTesting(),
            transport: StubSeerrTransport(), signInPause: {})
        let called = CallFlag()

        let section = await session.loadSection { _, _ -> [Int] in called.fire(); return [] }

        #expect(section == nil)
        #expect(!called.didFire)
    }

    @Test("a deadline bounds an op that ignores cancellation", .timeLimit(.minutes(1)))
    func deadlineBoundsAnOpThatIgnoresCancellation() async {
        let (session, _) = await connectedSession()
        let started = TestLatch()
        let release = TestLatch()
        let returned = CallFlag()

        let load = Task {
            await session.loadSection(deadline: {}) { _, _ -> [Int] in
                started.open()
                await release.wait()
                returned.fire()
                return [1]
            }
        }
        await started.wait()

        #expect(await load.value == .hidden)
        #expect(!returned.didFire)
        release.open()
    }

    // MARK: Missing titles

    @Test("Jellyfin wins by TMDb id")
    func jellyfinWinsByTmdbId() {
        let result = SeerrMissing.titles([movie(1), movie(2)], owned: [SeerrOwnedKey(kind: .movie, tmdbId: 1)])
        #expect(result.map(\.title.tmdbId) == [2])
    }

    @Test("available, partially available and blocklisted titles are dropped")
    func availableAndBlocklistedDropped() {
        let result = SeerrMissing.titles(
            [movie(1, .partiallyAvailable), movie(2, .available), movie(3, .blocklisted), movie(4, .pending)],
            owned: [])
        #expect(result.map(\.title.tmdbId) == [4])
    }

    @Test("a deleted title stays missing and can be requested again")
    func deletedStaysMissing() {
        let result = SeerrMissing.titles([movie(1, .deleted)], owned: [])
        #expect(result.map(\.badge) == [.request])
    }

    @Test("duplicates collapse and Seerr's order is kept")
    func duplicatesCollapse() {
        let result = SeerrMissing.titles([movie(3), movie(1), movie(3)], owned: [])
        #expect(result.map(\.title.tmdbId) == [3, 1])
    }

    @Test("the owned ids read a lowercase provider key and skip non-numbers")
    func ownedIdsReadLowercaseKey() {
        let ids = SeerrMissing.ownedTmdbIds([
            owned(["tmdb": "10"]), owned(["Tmdb": "11"], .series), owned(["TMDB": "12"]),
            owned(["Tmdb": "tt1"]), owned(["Imdb": "13"]), owned(["Tmdb": "14"], .episode), BaseItemDto(),
        ])
        #expect(ids == [.init(kind: .movie, tmdbId: 10), .init(kind: .tv, tmdbId: 11), .init(kind: .movie, tmdbId: 12)])
    }

    @Test("the TMDb collection id: `TmdbCollection` on a film or a BoxSet, Jellyfin's `Tmdb` on a BoxSet only")
    func tmdbCollectionId() {
        #expect(SeerrMissing.tmdbCollectionId(of: owned(["TmdbCollection": "1241", "Tmdb": "671"])) == 1241)
        #expect(SeerrMissing.tmdbCollectionId(of: owned(["tmdbcollection": "1241"])) == 1241)
        // A film's `Tmdb` is the FILM's id, never its saga's.
        #expect(SeerrMissing.tmdbCollectionId(of: owned(["Tmdb": "671"])) == nil)
        #expect(SeerrMissing.tmdbCollectionId(of: owned(["Tmdb": "1241"], .boxSet)) == 1241)
        #expect(SeerrMissing.tmdbCollectionId(of: owned(["Tmdb": "9", "TmdbCollection": "1241"], .boxSet)) == 1241)
        #expect(SeerrMissing.tmdbCollectionId(of: owned(["TmdbCollection": "x"], .boxSet)) == nil)
        #expect(SeerrMissing.tmdbCollectionId(of: owned(["Tmdb": "1241"], .series)) == nil)
    }

    // MARK: Badges

    @Test("badge: no info, unknown or no request asks for the title")
    func requestBadge() {
        #expect(SeerrMissing.badge(nil) == .request)
        #expect(SeerrMissing.badge(SeerrMediaInfo(status: .unknown)) == .request)
        #expect(SeerrMissing.badge(SeerrMediaInfo(status: .deleted)) == .request)
    }

    @Test("badge: the latest request decides")
    func latestRequestDecides() {
        func info(_ requests: [SeerrRequestSummary]) -> SeerrMediaInfo {
            SeerrMediaInfo(status: .pending, requests: requests)
        }
        #expect(SeerrMissing.badge(info([.init(id: 1, status: .pending)])) == .pending)
        #expect(SeerrMissing.badge(info([.init(id: 1, status: .approved)])) == .processing)
        #expect(SeerrMissing.badge(info([.init(id: 1, status: .completed)])) == .processing)
        #expect(SeerrMissing.badge(info([.init(id: 5, status: .declined), .init(id: 2, status: .pending)])) == .declined)
        #expect(SeerrMissing.badge(info([.init(id: 2, status: .declined), .init(id: 5, status: .pending)])) == .pending)
        #expect(SeerrMissing.badge(SeerrMediaInfo(status: .processing)) == .processing)
        #expect(SeerrMissing.badge(SeerrMediaInfo(status: .pending)) == .pending)
    }

    @Test("a declined request shows the declined badge")
    func declinedBadge() {
        let info = SeerrMediaInfo(status: .unknown, requests: [.init(id: 1, status: .declined)])
        #expect(SeerrMissing.badge(info) == .declined)
    }

    // MARK: Seasons

    @Test("a pending season comes from the request, not from mediaInfo.seasons")
    func pendingSeasonFromRequestNotMediaSeasons() {
        let info = SeerrMediaInfo(status: .pending, seasons: [], requests: [.init(id: 1, status: .pending, seasons: [1])])
        let result = SeerrMissing.seasons(show(seasons: [1, 2], info: info), ownedSeasonNumbers: [], includeSpecials: false)
        #expect(result.map(\.seasonNumber) == [1, 2])
        #expect(result.map(\.badge) == [.pending, .request])
        #expect(result.first?.id == "tv-9-s1")
    }

    @Test("a missing season carries its own poster, nil when TMDb has none")
    func seasonPoster() {
        let tv = SeerrTVDetails(tmdbId: 9, name: "S", seasons: [
            SeerrSeason(seasonNumber: 1, episodeCount: 8, posterPath: "/s1.jpg"),
            SeerrSeason(seasonNumber: 2, episodeCount: 8),
        ], mediaInfo: nil)
        let result = SeerrMissing.seasons(tv, ownedSeasonNumbers: [], includeSpecials: false)
        #expect(result.map(\.posterPath) == ["/s1.jpg", nil])
    }

    @Test("specials only when enabled")
    func specialsOnlyWhenEnabled() {
        let tv = show(seasons: [0, 1])
        #expect(SeerrMissing.seasons(tv, ownedSeasonNumbers: [], includeSpecials: false).map(\.seasonNumber) == [1])
        #expect(SeerrMissing.seasons(tv, ownedSeasonNumbers: [], includeSpecials: true).map(\.seasonNumber) == [0, 1])
    }

    @Test("owned and available seasons are dropped, a processing one is badged")
    func ownedAndAvailableSeasonsDropped() {
        let info = SeerrMediaInfo(status: .partiallyAvailable, seasons: [
            .init(seasonNumber: 2, status: .available), .init(seasonNumber: 3, status: .partiallyAvailable),
            .init(seasonNumber: 4, status: .processing),
        ])
        let result = SeerrMissing.seasons(
            show(seasons: [1, 2, 3, 4, 5], info: info), ownedSeasonNumbers: [1], includeSpecials: false)
        #expect(result.map(\.seasonNumber) == [4, 5])
        #expect(result.map(\.badge) == [.processing, .request])
    }

    @Test("a deleted season can be requested again, past its completed request")
    func deletedSeasonIsRequestable() {
        let done = SeerrRequestSummary(id: 1, status: .completed, seasons: [3])
        let deleted = SeerrMediaInfo(status: .partiallyAvailable, seasons: [.init(seasonNumber: 3, status: .deleted)], requests: [done])
        #expect(SeerrMissing.seasons(show(seasons: [3], info: deleted), ownedSeasonNumbers: [], includeSpecials: false)
            .map(\.badge) == [.request])
        let again = SeerrMediaInfo(
            status: .partiallyAvailable, seasons: [.init(seasonNumber: 3, status: .deleted)],
            requests: [done, .init(id: 2, status: .pending, seasons: [3])])
        #expect(SeerrMissing.seasons(show(seasons: [3], info: again), ownedSeasonNumbers: [], includeSpecials: false)
            .map(\.badge) == [.pending])
        let older = SeerrMediaInfo(
            status: .partiallyAvailable, seasons: [.init(seasonNumber: 3, status: .deleted)],
            requests: [.init(id: 1, status: .declined, seasons: [3]), .init(id: 2, status: .completed, seasons: [3])])
        #expect(SeerrMissing.seasons(show(seasons: [3], info: older), ownedSeasonNumbers: [], includeSpecials: false)
            .map(\.badge) == [.request])
    }

    @Test("a failed season request reads as processing")
    func failedSeasonRequestIsProcessing() {
        let info = SeerrMediaInfo(status: .pending, requests: [.init(id: 1, status: .failed, seasons: [1])])
        #expect(SeerrMissing.seasons(show(seasons: [1], info: info), ownedSeasonNumbers: [], includeSpecials: false)
            .map(\.badge) == [.processing])
    }

    @Test("ownership is per kind")
    func ownershipIsPerKind() {
        let series = SeerrTitle(kind: .tv, tmdbId: 42, title: "T")
        let result = SeerrMissing.titles([series, movie(42)], owned: [SeerrOwnedKey(kind: .movie, tmdbId: 42)])
        #expect(result.map(\.id) == ["tv-42"])
    }

    // MARK: Actor page

    @Test("an actor's credits: the cast only, in Seerr's order")
    func actorUsesCastOnly() {
        let credits = SeerrCombinedCredits(cast: [movie(3), tvTitle(5), movie(1)], crew: [movie(7), tvTitle(8)])
        let titles = SeerrMissing.creditTitles(credits, person: SeerrPerson(knownForDepartment: "Acting"))
        #expect(titles.map(creditKey) == ["movie-3", "tv-5", "movie-1"])
    }

    @Test("a director's crew credits follow the cast; a title credited twice is listed once")
    func directorAddsCrew() {
        let credits = SeerrCombinedCredits(
            cast: [movie(3)], crew: [movie(7), movie(3), tvTitle(3), movie(7), tvTitle(9)])
        let titles = SeerrMissing.creditTitles(credits, person: SeerrPerson(knownForDepartment: "Directing"))
        // TV 3 is not film 3: the ids overlap across kinds.
        #expect(titles.map(creditKey) == ["movie-3", "movie-7", "tv-3", "tv-9"])
    }

    @Test("an unknown or empty department: the cast only (fail closed)")
    func unknownDepartmentIsCastOnly() {
        let credits = SeerrCombinedCredits(cast: [movie(3)], crew: [movie(7)])
        #expect(SeerrMissing.creditTitles(credits, person: SeerrPerson()).map(creditKey) == ["movie-3"])
        #expect(SeerrMissing.creditTitles(credits, person: SeerrPerson(knownForDepartment: "")).map(creditKey)
            == ["movie-3"])
    }

    @Test("the person's owned titles are dropped, per kind; what Seerr has available too")
    func ownedDropped() {
        let credits = SeerrCombinedCredits(
            cast: [movie(3), tvTitle(3), tvTitle(5), movie(8, .available), movie(9, .pending)], crew: [])
        let ownedIds = SeerrMissing.ownedTmdbIds([owned(["Tmdb": "3"]), owned(["Tmdb": "5"], .series)])
        let missing = SeerrMissing.titles(
            SeerrMissing.creditTitles(credits, person: SeerrPerson(knownForDepartment: "Acting")), owned: ownedIds)
        #expect(missing.map(\.id) == ["tv-3", "movie-9"])
        #expect(missing.map(\.badge) == [.request, .pending])
    }

    @Test("a deleted title with old completed requests is requestable")
    func deletedWithOldRequestsIsRequestable() {
        let info = SeerrMediaInfo(status: .deleted, requests: [.init(id: 1, status: .completed, seasons: [])])
        #expect(SeerrMissing.badge(info) == .request)
    }

    // MARK: Poster

    @Test("the poster URL keeps the sub-path of a hosted Seerr")
    func posterURLKeepsSubPath() {
        let base = URL(string: "https://h/seerr")!
        #expect(SeerrImages.posterURL(path: "/x.jpg", seerrBase: base, cacheImages: true)?.absoluteString
                == "https://h/seerr/imageproxy/tmdb/t/p/w300/x.jpg")
        #expect(SeerrImages.posterURL(path: "/x.jpg", seerrBase: base, cacheImages: false)?.absoluteString
                == "https://image.tmdb.org/t/p/w300/x.jpg")
        #expect(SeerrImages.posterURL(path: nil, seerrBase: base, cacheImages: true) == nil)
    }

    /// A missing-title card without a poster URL draws the bare outline.
    @Test("a session with no Seerr client gives a card no poster")
    func noClientNoPoster() {
        let session = SeerrSession(
            storage: MockKeychain(), defaults: .isolatedForTesting(),
            transport: StubSeerrTransport([]), signInPause: {})
        #expect(session.posterURL("/x.jpg") == nil)
    }
}

// MARK: - Request flow

@MainActor
@Suite("Seerr request flow")
struct SeerrRequestFlowTests {
    private let loc = LocalizationManager()
    private let series = SeerrTitle(kind: .tv, tmdbId: 90228, title: "Série")

    @Test("without partial requests every missing season is sent, whatever the selection")
    func nonPartialSendsAllMissingSeasons() async {
        let bench = await requestBench(partialRequests: false)
        bench.stub.enqueue(created("tv"))
        let presenter = SeerrRequestPresenter()
        let toasts = ToastCenter()
        await presenter.submit(
            .series(series, seasons: [2, 3, 4], preselected: [4]), selection: [4],
            session: bench.session, loc: loc, toasts: toasts)
        #expect(sentBody(bench.stub, 0)?["seasons"] as? [Int] == [2, 3, 4])
        #expect(presenter.badge(for: "tv-90228", default: .request) == .pending)
        #expect(presenter.badge(for: "tv-90228-s3", default: .request) == .pending)
    }

    @Test("with partial requests only the selection is sent, in order")
    func partialSendsTheSelection() async {
        let bench = await requestBench(permissions: 128)
        bench.stub.enqueue(created("tv", status: 2))
        let presenter = SeerrRequestPresenter()
        await presenter.submit(
            .series(series, seasons: [2, 3, 4], preselected: []), selection: [4, 2],
            session: bench.session, loc: loc, toasts: ToastCenter())
        #expect(sentBody(bench.stub, 0)?["seasons"] as? [Int] == [2, 4])
        #expect(presenter.badge(for: "tv-90228-s2", default: .request) == .processing)
        #expect(presenter.badge(for: "tv-90228-s3", default: .request) == .request)
        #expect(presenter.badge(for: "tv-90228", default: .request) == .processing)
    }

    @Test("a duplicate flips the card to pending and says so")
    func duplicateFlipsToPending() async {
        let bench = await requestBench()
        bench.stub.enqueue(.response(status: 409, body: #"{"message":"Request for this media already exists."}"#))
        let presenter = SeerrRequestPresenter()
        let toasts = ToastCenter()
        await presenter.submit(
            .movie(SeerrTitle(kind: .movie, tmdbId: 5, title: "Film")), selection: [],
            session: bench.session, loc: loc, toasts: toasts)
        #expect(presenter.badge(for: "movie-5", default: .request) == .pending)
        #expect(toasts.current?.title == loc.localized("seerr.request.duplicate"))
    }

    @Test("a refusal leaves the card alone and explains the fix")
    func forbiddenShowsRefusal() async {
        let bench = await requestBench()
        bench.stub.enqueue(.response(status: 403, body: #"{"message":"You do not have permission"}"#))
        bench.stub.enqueue(.response(status: 200, body: #"{"id":7,"permissions":32,"jellyfinUserId":"A"}"#))
        let presenter = SeerrRequestPresenter()
        let toasts = ToastCenter()
        await presenter.submit(
            .movie(SeerrTitle(kind: .movie, tmdbId: 5, title: "Film")), selection: [],
            session: bench.session, loc: loc, toasts: toasts)
        #expect(presenter.badge(for: "movie-5", default: .request) == .request)
        #expect(toasts.current?.title == loc.localized("seerr.request.forbidden.title"))
        #expect(toasts.current?.message == loc.localized("seerr.request.forbidden.fix"))
        // A browse-surface toast never names Seerr, in any language.
        for language in ["fr", "en", "de"] {
            let fix = Bundle.localizedBundle(for: language)
                .localizedString(forKey: "seerr.request.forbidden.fix", value: nil, table: nil)
            #expect(fix != "seerr.request.forbidden.fix", "\(language)")
            #expect(!fix.contains("Seerr"), "\(language): \(fix)")
        }
    }

    @Test("after a request, the badge reads the status Seerr answered, not the permissions")
    func badgeFollowsTheCreatedStatus() async {
        // The permissions say « an admin approves »; Seerr approved at once.
        let bench = await requestBench(permissions: 32)
        bench.stub.enqueue(created(status: 2))
        let presenter = SeerrRequestPresenter()
        await presenter.submit(
            .movie(SeerrTitle(kind: .movie, tmdbId: 5, title: "Film")), selection: [],
            session: bench.session, loc: loc, toasts: ToastCenter())
        #expect(presenter.badge(for: "movie-5", default: .request) == .processing)

        // The permissions say « auto-approved »; Seerr kept it pending.
        let auto = await requestBench(permissions: 128)
        auto.stub.enqueue(created("tv", status: 1))
        let autoPresenter = SeerrRequestPresenter()
        await autoPresenter.submit(
            .series(series, seasons: [2, 3], preselected: []), selection: [2, 3],
            session: auto.session, loc: loc, toasts: ToastCenter())
        #expect(autoPresenter.badge(for: "tv-90228", default: .request) == .pending)
        #expect(autoPresenter.badge(for: "tv-90228-s3", default: .request) == .pending)
    }

    @Test("a withdrawn request gives its card and seasons back to what the section says")
    func withdrawnRequestForgetsItsBadges() async {
        let bench = await requestBench(permissions: 32)
        bench.stub.enqueue(created("tv", status: 1))
        let presenter = SeerrRequestPresenter()
        await presenter.submit(
            .series(series, seasons: [2, 3], preselected: []), selection: [2, 3],
            session: bench.session, loc: loc, toasts: ToastCenter())
        #expect(presenter.badge(for: "tv-90228-s2", default: .request) == .pending)

        let asker = SeerrUser(id: SeerrUserID(rawValue: 7), permissions: .request, jellyfinUserId: "A", displayName: "Alice")
        presenter.forget(SeerrRequest(
            id: 1, status: .pending, kind: .tv, seasons: [2, 3], createdAt: .distantPast, updatedAt: .distantPast,
            requestedBy: asker, media: SeerrRequestMedia(tmdbId: 90228, status: .pending)))

        #expect(presenter.badge(for: "tv-90228", default: .request) == .request)
        #expect(presenter.badge(for: "tv-90228-s2", default: .request) == .request)
        #expect(presenter.badge(for: "tv-90228-s3", default: .declined) == .declined)
        #expect(presenter.requestableSeasons([
            SeerrMissingSeason(seriesTmdbId: 90228, seasonNumber: 2, badge: .request),
        ]) == [2])
    }

    @Test("a 202 is a failure: nothing was available to request")
    func noSeasonsIsAFailure() async {
        let bench = await requestBench()
        bench.stub.enqueue(.response(status: 202, body: #"{"message":"No seasons available to request"}"#))
        let presenter = SeerrRequestPresenter()
        let toasts = ToastCenter()
        await presenter.submit(
            .series(series, seasons: [1], preselected: []), selection: [1],
            session: bench.session, loc: loc, toasts: toasts)
        #expect(presenter.badge(for: "tv-90228", default: .request) == .request)
        #expect(toasts.current?.title == loc.localized("seerr.request.noSeasons"))
    }

    @Test("several films: one request each, the failure counted in the same toast")
    func filmsPartialFailure() async {
        let bench = await requestBench()
        bench.stub.enqueue(created())
        bench.stub.enqueue(.response(status: 500, body: ""))
        bench.stub.enqueue(created())
        let presenter = SeerrRequestPresenter()
        let toasts = ToastCenter()
        let films = (1...3).map { SeerrTitle(kind: .movie, tmdbId: $0, title: "F\($0)") }
        await presenter.submit(.films(films), selection: [1, 2, 3], session: bench.session, loc: loc, toasts: toasts)
        #expect(bench.stub.requests.filter { $0.httpMethod == "POST" }.count == 3)
        #expect(presenter.badge(for: "movie-1", default: .request) == .pending)
        #expect(presenter.badge(for: "movie-2", default: .request) == .request)
        #expect(presenter.badge(for: "movie-3", default: .request) == .pending)
        #expect(toasts.current?.title == loc.counted("seerr.request.sentFilms", 2))
        #expect(toasts.current?.message == loc.counted("seerr.request.refusedCount", 1))
    }

    @Test("the line under the button depends on who approves")
    func autoApproveLine() {
        let auto = "seerr.request.next.auto"
        let manual = "seerr.request.next.approval"
        #expect(SeerrRequestPresenter.nextStepKey(permissions: SeerrPermissions(rawValue: 2), kind: .movie) == auto)
        #expect(SeerrRequestPresenter.nextStepKey(permissions: SeerrPermissions(rawValue: 128), kind: .tv) == auto)
        #expect(SeerrRequestPresenter.nextStepKey(permissions: SeerrPermissions(rawValue: 256), kind: .movie) == auto)
        #expect(SeerrRequestPresenter.nextStepKey(permissions: SeerrPermissions(rawValue: 256), kind: .tv) == manual)
        #expect(SeerrRequestPresenter.nextStepKey(permissions: SeerrPermissions(rawValue: 32), kind: .movie) == manual)
    }

    @Test("the confirmation reads a season, a range, or a count")
    func seasonLabels() {
        func label(_ s: Set<Int>) -> String {
            SeerrRequestPresenter.seasonsActionTitle(Array(s).sorted(), loc: loc)
        }
        #expect(label([4]) == loc.localized("seerr.request.action.season", 4))
        #expect(label([4, 5, 6]) == loc.localized("seerr.request.action.seasonRange", 4, 6))
        #expect(label([1, 3]) == loc.counted("seerr.request.action.seasons", 2))
    }

    @Test("the confirmation reads « Épisodes spéciaux » for season 0 alone, a count for a run from 0")
    func specialsLabels() {
        func label(_ s: [Int]) -> String { SeerrRequestPresenter.seasonsActionTitle(s, loc: loc) }
        #expect(label([0]) == loc.localized("seerr.request.action.specials"))
        #expect(label([0]) != loc.localized("seerr.request.action.season", 0))
        // « Demander les saisons 0 à 2 » would name a season 0 nobody calls that.
        #expect(label([0, 1, 2]) == loc.counted("seerr.request.action.seasons", 3))
        #expect(label([0, 2]) == loc.counted("seerr.request.action.seasons", 2))
    }

    @Test("without partial requests the label names what is sent")
    func nonPartialLabelMatchesPayload() async {
        let bench = await requestBench(partialRequests: false)
        bench.stub.enqueue(created("tv"))
        let draft = SeerrRequestDraft.series(series, seasons: [2, 3, 4], preselected: [4])
        let effective = SeerrRequestPresenter.effectiveSelection(draft, draft.defaultSelection(partial: false), partial: false)
        #expect(effective == [2, 3, 4])
        #expect(draft.defaultSelection(partial: true) == [4])
        // Even a stray selection of one season labels the whole.
        #expect(SeerrRequestPresenter.effectiveSelection(draft, [4], partial: false) == [2, 3, 4])
        #expect(SeerrRequestPresenter.actionTitle(for: draft, selection: effective, loc: loc)
                != SeerrRequestPresenter.actionTitle(for: draft, selection: [4], loc: loc))
        await SeerrRequestPresenter().submit(
            draft, selection: effective, session: bench.session, loc: loc, toasts: ToastCenter())
        #expect(sentBody(bench.stub, 0)?["seasons"] as? [Int] == [2, 3, 4])
    }

    @Test("films stop going out once the account changed")
    func filmsStopOnAccountSwitch() async {
        let bench = await requestBench()
        let box = KeyBox("S1|A")
        bench.session.activeAccountKeyProvider = { box.value }
        bench.stub.enqueue(created())
        bench.stub.enqueue(created())
        bench.stub.onSend = { box.value = "S1|B" }
        let presenter = SeerrRequestPresenter()
        let toasts = ToastCenter()
        let films = (1...3).map { SeerrTitle(kind: .movie, tmdbId: $0, title: "F\($0)") }
        await presenter.submit(.films(films), selection: [1, 2, 3], session: bench.session, loc: loc, toasts: toasts)
        #expect(bench.stub.requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(presenter.badge(for: "movie-1", default: .request) == .request)
        #expect(toasts.current == nil)
    }

    @Test("an account change forgets the overrides and any open draft")
    func resetClearsOverrides() async {
        let bench = await requestBench()
        bench.stub.enqueue(created())
        let presenter = SeerrRequestPresenter()
        let film = SeerrTitle(kind: .movie, tmdbId: 5, title: "Film")
        presenter.present(.movie(film))
        await presenter.submit(.movie(film), selection: [], session: bench.session, loc: loc, toasts: ToastCenter())
        #expect(presenter.badge(for: "movie-5", default: .request) == .pending)
        presenter.present(.movie(film))
        presenter.reset()
        #expect(presenter.badge(for: "movie-5", default: .request) == .request)
        #expect(presenter.draft == nil)
    }
}

private final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var key: String
    init(_ key: String) { self.key = key }
    var value: String {
        get { lock.withLock { key } }
        set { lock.withLock { key = newValue } }
    }
}

// MARK: - Actor page (« Pas encore dans ta bibliothèque »)

/// `/person/{id}/combined_credits` as Seerr answers it: cast and crew entries
/// carrying their `mediaType`, in Seerr's order.
private func creditsBody(cast: [(kind: String, id: Int)], crew: [(kind: String, id: Int)] = []) -> String {
    func list(_ entries: [(kind: String, id: Int)]) -> String {
        entries.map { #"{"mediaType":"\#($0.kind)","id":\#($0.id),"title":"Titre \#($0.id)","name":"Titre \#($0.id)"}"# }
            .joined(separator: ",")
    }
    return #"{"cast":[\#(list(cast))],"crew":[\#(list(crew))]}"#
}

/// Answers Seerr for an actor page: the session's reload (`/settings/public`,
/// `/auth/me`), then `/person/{id}` (`department`) and
/// `/person/{id}/combined_credits` from `credits` — held by that id's gate
/// when one is given. An id missing from `credits` fails its credits call.
private final class PersonSeerrTransport: SeerrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private let department: String
    private let credits: [Int: String]
    private let gates: [Int: TestLatch]
    /// Opens when the first credits request reaches the transport.
    let creditsArrived = TestLatch()

    init(department: String = "Acting", credits: [Int: String], gates: [Int: TestLatch] = [:]) {
        self.department = department
        self.credits = credits
        self.gates = gates
    }

    /// Every `/person/…` request, the credits included.
    var personRequestCount: Int {
        lock.withLock { sent }.filter { $0.url?.path.contains("/person/") == true }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        let path = request.url?.path.replacingOccurrences(of: "/api/v1", with: "") ?? ""
        let body: String
        switch path {
        case "/settings/public":
            body = #"{"mediaServerType":2,"partialRequestsEnabled":true,"enableSpecialEpisodes":false}"#
        case "/auth/me":
            body = #"{"id":7,"permissions":32,"jellyfinUserId":"A","displayName":"Alice"}"#
        case let path where path.hasSuffix("/combined_credits"):
            let id = Int(path.dropFirst("/person/".count).dropLast("/combined_credits".count))
            creditsArrived.open()
            if let id, let gate = gates[id] { await gate.wait() }
            guard let id, let reply = credits[id] else { throw StubSeerrTransport.Exhausted() }
            body = reply
        case let path where path.hasPrefix("/person/"):
            body = #"{"id":1,"knownForDepartment":"\#(department)"}"#
        default:
            throw StubSeerrTransport.Exhausted()
        }
        let url = request.url ?? URL(string: "http://192.168.1.20:5055")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (Data(body.utf8), response)
    }
}

/// The section's titles as `kind-tmdbId`, `nil` unless loaded.
private func personEntries(_ section: MissingSection<SeerrMissingTitle>) -> [String]? {
    guard case .loaded(let missing) = section else { return nil }
    return missing.map(\.id)
}

@MainActor
@Suite("Person — missing titles")
struct PersonDetailSeerrModelTests {
    /// Jellyfin owns film 3 and series 5 of person 31.
    private let ownedIds: Set<SeerrOwnedKey> = [.init(kind: .movie, tmdbId: 3), .init(kind: .tv, tmdbId: 5)]

    private func makeModel(
        _ session: SeerrSession, allowed: Bool = true,
        deadline: @escaping @Sendable () async throws -> Void = neverExpires
    ) -> PersonDetailSeerrModel {
        let model = PersonDetailSeerrModel()
        model.seerr = session
        model.allowsSeerr = { allowed }
        model.deadline = deadline
        return model
    }

    @Test("the rest of the person's credits, minus what the library owns, per kind")
    func missingCreditsAfterOwned() async {
        let transport = PersonSeerrTransport(credits: [31: creditsBody(
            cast: [("movie", 3), ("tv", 3), ("movie", 4), ("tv", 5), ("movie", 4)], crew: [("movie", 6)])])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let model = makeModel(session)

        model.load(tmdbId: 31, owned: ownedIds, fetchedProviderIds: true)
        await model.task?.value

        // Film 3 and series 5 are owned; series 3 shares the film's number
        // and stays missing; an actor's crew credit is not listed.
        #expect(personEntries(model.section) == ["tv-3", "movie-4"])
        #expect(model.section(for: session.snapshot()) == model.section)
        #expect(model.section(for: SeerrSession.Snapshot(accountKey: "S1|B", generation: 99)) == .hidden)
    }

    @Test("a person primarily crew: the crew credits follow the cast")
    func crewPersonListsCrew() async {
        let transport = PersonSeerrTransport(
            department: "Directing", credits: [31: creditsBody(cast: [("movie", 4)], crew: [("movie", 6), ("tv", 7)])])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let model = makeModel(session)

        model.load(tmdbId: 31, owned: ownedIds, fetchedProviderIds: true)
        await model.task?.value

        #expect(personEntries(model.section) == ["movie-4", "movie-6", "tv-7"])
    }

    @Test("the filmography: 200 titles with their TMDb ids while the section may show, the page's 60 lean otherwise")
    func filmographyOwnedSetIsWhole() async throws {
        let api = MockAPIClient()
        let allowed = PersonDetailSeerrModel()
        allowed.allowsSeerr = { true }
        let refused = PersonDetailSeerrModel()

        let shown = try await allowed.filmography(personId: "p", userId: "A", using: api)
        let hidden = try await refused.filmography(personId: "p", userId: "A", using: api)

        // Newest first: a 60 cap would offer a prolific person's older owned titles.
        #expect(api.personItemsLimits == [PersonDetailSeerrModel.ownedSetLimit, PersonDetailSeerrModel.pageLimit])
        #expect(api.personItemsLimits == [200, 60])
        #expect(api.personItemsProviderIdFlags == [true, false])
        #expect(shown.withProviderIds && !hidden.withProviderIds)
    }

    @Test("no TMDb id on the person: no Seerr call, nothing shown")
    func noTmdbIdNoCall() async {
        let transport = PersonSeerrTransport(credits: [31: creditsBody(cast: [("movie", 4)])])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let model = makeModel(session)

        model.load(tmdbId: nil, owned: ownedIds, fetchedProviderIds: true)
        await model.task?.value

        #expect(model.section == .hidden)
        #expect(transport.personRequestCount == 0)
    }

    @Test("not allowed, or the filmography fetched without its TMDb ids: no Seerr call")
    func notAllowedNoCall() async {
        let transport = PersonSeerrTransport(credits: [31: creditsBody(cast: [("movie", 4)])])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)

        let refused = makeModel(session, allowed: false)
        refused.load(tmdbId: 31, owned: ownedIds, fetchedProviderIds: true)
        await refused.task?.value
        // Without the owned ids nothing could be subtracted: never asked.
        let blind = makeModel(session)
        blind.load(tmdbId: 31, owned: [], fetchedProviderIds: false)
        await blind.task?.value

        #expect(refused.section == .hidden)
        #expect(blind.section == .hidden)
        #expect(transport.personRequestCount == 0)
    }

    @Test("a failed credits call hides the section")
    func failureHides() async {
        let transport = PersonSeerrTransport(credits: [:])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let model = makeModel(session)

        model.load(tmdbId: 31, owned: ownedIds, fetchedProviderIds: true)
        await model.task?.value

        #expect(model.section == .hidden)
    }

    @Test("one deadline bounds both calls: slow credits hide the section once it passes")
    func deadlineBoundsBothCalls() async {
        let gate = TestLatch()
        let deadline = TestLatch()
        let transport = PersonSeerrTransport(credits: [31: creditsBody(cast: [("movie", 4)])], gates: [31: gate])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let model = makeModel(session, deadline: { await deadline.wait() })

        model.load(tmdbId: 31, owned: ownedIds, fetchedProviderIds: true)
        await transport.creditsArrived.wait()
        #expect(model.section == .loading)
        deadline.open()
        await model.task?.value
        gate.open()

        #expect(model.section == .hidden)
    }

    @Test("a superseded pass writes nothing")
    func supersededPassDropped() async {
        let gate = TestLatch()
        let transport = PersonSeerrTransport(
            credits: [31: creditsBody(cast: [("movie", 4)]), 32: creditsBody(cast: [("movie", 8)])], gates: [31: gate])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let model = makeModel(session)

        model.load(tmdbId: 31, owned: ownedIds, fetchedProviderIds: true)
        await transport.creditsArrived.wait()
        let first = model.task
        model.load(tmdbId: 32, owned: ownedIds, fetchedProviderIds: true)
        await model.task?.value
        gate.open()
        await first?.value

        #expect(personEntries(model.section) == ["movie-8"])
    }

    @Test("a reset hides the section, and the pass in flight writes nothing")
    func resetDropsThePassInFlight() async {
        let gate = TestLatch()
        let transport = PersonSeerrTransport(credits: [31: creditsBody(cast: [("movie", 4)])], gates: [31: gate])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let model = makeModel(session)

        model.load(tmdbId: 31, owned: ownedIds, fetchedProviderIds: true)
        await transport.creditsArrived.wait()
        let first = model.task
        model.reset()
        gate.open()
        await first?.value

        #expect(model.section == .hidden)
    }

    @Test("a pass cancelled before it starts writes nothing — not even the skeleton")
    func cancelledPassWritesNothing() async {
        let transport = PersonSeerrTransport(credits: [31: creditsBody(cast: [("movie", 4)])])
        let (_, session) = await seerrBench(api: MockAPIClient(), transport: transport)
        let model = makeModel(session)

        model.load(tmdbId: 31, owned: ownedIds, fetchedProviderIds: true)
        model.task?.cancel()
        await model.task?.value

        #expect(model.section == .hidden)
        #expect(transport.personRequestCount == 0)
    }
}

// MARK: - One presentation context at a time (I3)

/// The deep-link fiche is a modal over the tabs: the root-hosted sheets cannot
/// present over it, so it hosts its own — and the root stands down meanwhile.
@MainActor
@Suite("Root-hosted flows inside the deep-link modal")
struct ModalPresentationHostTests {
    private let film = SeerrTitle(kind: .movie, tmdbId: 5, title: "Film")

    @Test("a Seerr request raised while the modal is up is presented by the modal only")
    func seerrRequestHasOneHost() {
        let presenter = SeerrRequestPresenter()
        presenter.present(.movie(film))
        #expect(presenter.draft(for: .root) == .movie(film))     // no modal: the root presents

        presenter.modalChanged(isUp: true)
        #expect(presenter.draft == nil)                           // a modal arriving takes no root draft in
        presenter.present(.movie(film))
        #expect(presenter.draft(for: .root) == nil)
        #expect(presenter.draft(for: .modal) == .movie(film))

        // The modal leaves with its request: the root never raises it afterwards.
        presenter.modalChanged(isUp: false)
        #expect(presenter.draft == nil)
        #expect(presenter.draft(for: .root) == nil)
        presenter.present(.movie(film))
        #expect(presenter.draft(for: .root) == .movie(film))
    }

    /// The stand-down is an ASSIGNMENT from `MainTabView.deepLinkFallback`,
    /// never a count of appear / disappear events: one unpaired appear left a
    /// counter at 1 and silenced every root-hosted request until relaunch.
    @Test("repeated « up » signals never leave the root silenced once the modal is gone")
    func repeatedSignalsCannotStrandTheRoot() {
        let seerr = SeerrRequestPresenter()
        let playlists = AddToPlaylistPresenter()
        for _ in 0..<3 {                      // a fiche replaced by another fiche, re-sent states
            seerr.modalChanged(isUp: true)
            playlists.modalChanged(isUp: true)
        }
        seerr.present(.movie(film))
        playlists.present(itemId: "item", title: "Film")
        #expect(seerr.draft(for: .root) == nil)
        #expect(playlists.request(for: .root) == nil)

        seerr.modalChanged(isUp: false)       // once, as `deepLinkFallback` goes nil
        playlists.modalChanged(isUp: false)
        seerr.present(.movie(film))
        playlists.present(itemId: "item", title: "Film")
        #expect(seerr.draft(for: .root) == .movie(film))
        #expect(playlists.request(for: .root)?.itemId == "item")
    }

    @Test("« Ajouter à une playlist » follows the same rule")
    func playlistRequestHasOneHost() {
        let presenter = AddToPlaylistPresenter()
        presenter.present(itemId: "item", title: "Film")
        #expect(presenter.request(for: .root)?.itemId == "item")

        presenter.modalChanged(isUp: true)
        #expect(presenter.request == nil)
        presenter.present(itemId: "item", title: "Film")
        #expect(presenter.request(for: .root) == nil)
        #expect(presenter.request(for: .modal)?.itemId == "item")

        presenter.modalChanged(isUp: false)
        #expect(presenter.request == nil)
        presenter.present(itemId: "item", title: "Film")
        #expect(presenter.request(for: .root)?.itemId == "item")
    }
}
