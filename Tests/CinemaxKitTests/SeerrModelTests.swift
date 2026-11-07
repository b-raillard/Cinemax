import Testing
import Foundation
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
        {"id":1,"name":"Show","seasons":[{"seasonNumber":0,"episodeCount":17},{"seasonNumber":1,"episodeCount":6}]}
        """
        let tv = try decode(SeerrTVDetails.self, json)
        #expect(tv.seasons.map(\.seasonNumber) == [0, 1])
        #expect(tv.seasons[0].episodeCount == 17)
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
