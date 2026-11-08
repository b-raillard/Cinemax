import Testing
import Foundation
import JellyfinAPI
@testable import CinemaxKit
@testable import Cinemax

@Suite("Seerr models")
struct SeerrModelTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try SeerrJSON.decoder().decode(type, from: Data(json.utf8))
    }

    @Test("Search drops people and collections")
    func searchDropsPeopleAndCollections() throws {
        let json = """
        {"page":1,"totalPages":1,"totalResults":3,"results":[
        {"mediaType":"movie","id":438631,"title":"Dune","releaseDate":"2021-09-15"},
        {"mediaType":"person","id":1},
        {"mediaType":"tv","id":90228,"name":"Dune : Prophecy","firstAirDate":"2024-11-17",
         "mediaInfo":{"status":2,"seasons":[],"requests":[{"id":2,"status":1,"seasons":[{"seasonNumber":1}]}]}}]}
        """
        let page = try decode(SeerrSearchPage.self, json)
        #expect(page.results.count == 2)
        #expect(page.results[0].year == 2021)
        #expect(page.results[1].kind == .tv)
        #expect(page.results[1].mediaInfo?.requests.first?.seasons == [1])
    }

    @Test("A malformed mediaInfo keeps the title; a season without status is unknown")
    func badMediaInfoKeepsTitle() throws {
        let json = """
        {"page":1,"totalPages":1,"results":[
        {"mediaType":"movie","id":1,"title":"Dune","mediaInfo":{"status":"nope","requests":"x"}},
        {"mediaType":"movie","id":2,"title":"Heat"}]}
        """
        let page = try decode(SeerrSearchPage.self, json)
        #expect(page.results.map(\.title) == ["Dune", "Heat"])
        #expect(page.results[0].mediaInfo == nil)
        let season = try decode(SeerrSeasonInfo.self, #"{"seasonNumber":2}"#)
        #expect(season.status == .unknown)
    }

    @Test("Unknown statuses fall back")
    func unknownStatusesFallBack() throws {
        let media = try decode(SeerrMediaInfo.self, #"{"status":9}"#)
        #expect(media.status == .unknown)
        let summary = try decode(SeerrRequestSummary.self, #"{"id":1,"status":9}"#)
        #expect(summary.status == .pending)
    }

    @Test("Admin passes every permission check")
    func permissionsAdminPassesEverything() {
        #expect(SeerrPermissions(rawValue: 2).allows(.manageRequests))
        #expect(SeerrPermissions(rawValue: 32).canManageRequests == false)
        #expect(SeerrPermissions(rawValue: 256).autoApproves(.movie))
        #expect(SeerrPermissions(rawValue: 256).autoApproves(.tv) == false)
        #expect(SeerrPermissions(rawValue: 512).autoApproves(.tv))
        #expect(SeerrPermissions(rawValue: 128).autoApproves(.tv))
    }

    @Test("Request page total comes from pageInfo")
    func requestPageTotalComesFromPageInfo() throws {
        let json = """
        {"pageInfo":{"pages":5,"pageSize":1,"results":5,"page":1},"results":[
        {"id":7,"status":2,"type":"movie","createdAt":"2026-11-01T10:00:00.000Z","updatedAt":"2026-11-02T10:00:00.000Z",
         "seasons":[],
         "requestedBy":{"id":3,"permissions":32,"jellyfinUserId":"abc","jellyfinUsername":"bob"},
         "media":{"tmdbId":438631,"status":5,"jellyfinMediaId":"jf1"}}]}
        """
        let page = try decode(SeerrRequestPage.self, json)
        #expect(page.total == 5)
        #expect(page.results.first?.media.jellyfinMediaId == "jf1")
        #expect(page.results.first?.requestedBy.displayName == "bob")
        #expect(page.results.first?.kind == .movie)
    }

    @Test("TV keeps season zero")
    func tvKeepsSeasonZero() throws {
        let json = """
        {"id":1,"name":"Show","seasons":[{"seasonNumber":0,"episodeCount":17},{"seasonNumber":1,"episodeCount":6,"posterPath":"/s1.jpg"}]}
        """
        let tv = try decode(SeerrTVDetails.self, json)
        #expect(tv.seasons.map(\.seasonNumber) == [0, 1])
        #expect(tv.seasons[0].episodeCount == 17)
        #expect(tv.seasons.map(\.posterPath) == [nil, "/s1.jpg"])
    }

    @Test("Collection parts without mediaType are movies")
    func collectionPartsDefaultToMovie() throws {
        let json = #"{"id":9,"name":"Saga","parts":[{"id":1,"title":"A","releaseDate":""},{"id":2,"mediaType":"person"}]}"#
        let c = try decode(SeerrCollection.self, json)
        #expect(c.parts.count == 1)
        #expect(c.parts[0].kind == .movie)
        #expect(c.parts[0].year == nil)
    }
}

@Suite("Seerr configuration")
struct SeerrConfigurationTests {

    private let address = URL(string: "http://h:5055")!

    @Test("merge keeps the legacy keys Jellyfin injects")
    func mergeRoundTripsLegacyKeys() {
        let dto = DisplayPreferencesDto(customPrefs: ["skipForwardLength": "30000", "chromecastVersion": "stable"])
        let merged = SeerrUserConfig.merged(SeerrUserConfig(isEnabled: true, url: address), into: dto)
        #expect(merged.customPrefs?["skipForwardLength"] == "30000")
        #expect(merged.customPrefs?["chromecastVersion"] == "stable")
        #expect(merged.customPrefs?["seerr.enabled"] == "true")
        #expect(merged.customPrefs?["seerr.url"] == "http://h:5055")
        #expect(merged.id == SeerrUserConfig.preferencesId)
        #expect(merged.client == SeerrUserConfig.client)
    }

    @Test("disabling keeps the address")
    func disableKeepsAddress() {
        let merged = SeerrUserConfig.merged(SeerrUserConfig(isEnabled: false, url: address), into: nil)
        #expect(merged.customPrefs?["seerr.enabled"] == nil)
        #expect(merged.customPrefs?["seerr.url"] == "http://h:5055")
    }

    @Test("garbage reads as off / no address")
    func readIgnoresGarbage() {
        let dto = DisplayPreferencesDto(customPrefs: ["seerr.enabled": "yes", "seerr.url": "not a url"])
        let config = SeerrUserConfig.read(dto)
        #expect(config.isEnabled == false)
        #expect(config.url == nil)
        #expect(SeerrUserConfig.read(nil) == SeerrUserConfig(isEnabled: false, url: nil))
    }

    /// What a real server answers (bench Jellyfin 10.11.0, 2026-11-07): it
    /// injects legacy keys into EVERY entity's `CustomPrefs`, two of them
    /// `null` — which the SDK's `[String: String]` cannot hold, so the whole
    /// read failed and Seerr's configuration was never read on a server.
    private static let serverBody = Data("""
    {"Id":"17617b18-f4d4-ffb3-0974-ff669560942d","SortBy":"SortName","RememberIndexing":false,
     "PrimaryImageHeight":250,"PrimaryImageWidth":250,
     "CustomPrefs":{"chromecastVersion":"stable","skipForwardLength":"30000","skipBackLength":"10000",
                    "enableNextVideoInfoOverlay":"False","tvhome":null,"dashboardTheme":null,
                    "seerr.enabled":"true","seerr.url":"http://h:5055"},
     "ScrollDirection":"Horizontal","ShowBackdrop":true,"RememberSorting":false,"SortOrder":"Ascending",
     "ShowSidebar":false,"Client":"jellyglass"}
    """.utf8)

    @Test("a server's preferences with null legacy values still read")
    func serverBodyWithNullsDecodes() throws {
        // The SDK's own decoding refuses the body: the cause, kept in view.
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DisplayPreferencesDto.self, from: Self.serverBody) }
        let dto = try DisplayPreferencesDecoding.decode(Self.serverBody)
        #expect(dto.customPrefs?["chromecastVersion"] == "stable")
        #expect(dto.customPrefs?.keys.contains("tvhome") == false)
        #expect(dto.client == "jellyglass")
        #expect(dto.scrollDirection == .horizontal)
        #expect(SeerrUserConfig.read(dto) == SeerrUserConfig(isEnabled: true, url: address))
    }

    @Test("a body that is not an object is refused")
    func nonObjectBodyThrows() {
        #expect(throws: (any Error).self) { try DisplayPreferencesDecoding.decode(Data("[1]".utf8)) }
    }

    @Test("enabled round-trips through read")
    func readRoundTrips() {
        let config = SeerrUserConfig(isEnabled: true, url: address)
        #expect(SeerrUserConfig.read(SeerrUserConfig.merged(config, into: nil)) == config)
    }

    @Test("secret storage round-trips in the mock")
    func secretsRoundTripInMock() {
        let keychain = MockKeychain()
        let origin = URL(string: "http://seerr.local:5055")!
        keychain.saveSeerrSessions(["srv|usr": SeerrBoundSecret(value: "cookie", origin: origin)])
        keychain.saveSeerrAPIKeys(["srv": SeerrBoundSecret(value: "key", origin: origin)])
        #expect(keychain.seerrSessions() == ["srv|usr": SeerrBoundSecret(value: "cookie", origin: origin)])
        #expect(keychain.seerrAPIKeys() == ["srv": SeerrBoundSecret(value: "key", origin: origin)])
    }

    @Test("the mock serves and records display preferences")
    func mockDisplayPreferences() async throws {
        let api = MockAPIClient()
        let empty = try await api.getDisplayPreferences(id: "x", client: "c", userId: nil)
        #expect(empty.customPrefs == nil)
        let dto = SeerrUserConfig.merged(SeerrUserConfig(isEnabled: true, url: address), into: empty)
        try await api.updateDisplayPreferences(dto, id: "x", client: "c", userId: nil)
        let back = try await api.getDisplayPreferences(id: "x", client: "c", userId: nil)
        #expect(SeerrUserConfig.read(back).isEnabled)
        #expect(api.updateDisplayPreferencesCalls.count == 1)
    }
}
