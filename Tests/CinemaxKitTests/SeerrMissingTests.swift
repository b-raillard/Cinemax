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

private func owned(_ providers: [String: String]) -> BaseItemDto {
    var item = BaseItemDto()
    item.providerIDs = providers
    return item
}

/// A session connected as Alice on a fresh stub; the op closures under test
/// never reach the network.
@MainActor
private func connectedSession() async -> (SeerrSession, AppState) {
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
        .response(status: 200, body: #"{"mediaServerType":2,"partialRequestsEnabled":true}"#),
        .response(status: 200, body: #"{"id":7,"permissions":32,"jellyfinUserId":"A","displayName":"Alice"}"#),
    ])
    let storage = MockKeychain()
    storage.saveSeerrSessions(["S1|A": SeerrBoundSecret(value: "abc", origin: url)])
    let session = SeerrSession(storage: storage, defaults: .isolatedForTesting(), transport: stub, signInPause: {})
    session.proAllowsProvider = { true }
    session.activeAccountKeyProvider = { [app] in app.activeAccountKey }
    await session.reload(appState: app)
    return (session, app)
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

    // MARK: Missing titles

    @Test("Jellyfin wins by TMDb id")
    func jellyfinWinsByTmdbId() {
        let result = SeerrMissing.titles([movie(1), movie(2)], owned: [1])
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
            owned(["tmdb": "10"]), owned(["Tmdb": "11"]), owned(["TMDB": "12"]),
            owned(["Tmdb": "tt1"]), owned(["Imdb": "13"]), BaseItemDto(),
        ])
        #expect(ids == [10, 11, 12])
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
