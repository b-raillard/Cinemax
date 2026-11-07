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

private func created(_ type: String = "movie", id: Int = 1) -> StubSeerrTransport.Reply {
    .response(status: 201, body: """
    {"id":\(id),"status":1,"type":"\(type)","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z",
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
        bench.stub.enqueue(created("tv"))
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
