import Testing
import Foundation
@testable import CinemaxKit
@testable import Cinemax

/// The request mini-fiche (owner's choice B, 2026-11-22): the whole
/// `/movie` / `/tv` payload it reads, and the pure choices it prints.
@Suite("Seerr request fiche")
struct SeerrRequestFicheTests {

    private func decode(_ json: String) throws -> SeerrTitleDetails {
        try SeerrJSON.decoder().decode(SeerrTitleDetails.self, from: Data(json.utf8))
    }

    /// Trimmed from the owner's Seerr 3.5.2 (2026-11-22, TMDb 1551025) — no
    /// `mediaType`, as `/movie/{id}` never sends one.
    private let movieJSON = """
    {"id":1551025,"title":"Protection (très) rapprochée","originalTitle":"Guarding Stars","originalLanguage":"en",
     "releaseDate":"2026-11-18","runtime":109,"voteAverage":6.969,"voteCount":81,
     "backdropPath":"/qHvap0vpfTBIbv7cnR0OyBRqQHG.jpg",
     "genres":[{"id":10749,"name":"Romance"},{"id":35,"name":"Comédie"}],
     "credits":{"cast":[
        {"castId":1,"character":"Hannah","id":11,"name":"Leighton Meester","order":0,"profilePath":"/a.jpg"},
        {"castId":2,"character":"Jack","id":12,"name":"Jared Padalecki","order":1,"profilePath":null},
        {"castId":3,"character":"x","id":13,"order":2}],
      "crew":[{"id":20,"name":"Elizabeth Allen Rosenbaum","job":"Director"},{"id":21,"name":"Someone","job":"Writer"}]},
     "relatedVideos":[{"type":"Featurette","site":"YouTube","url":"https://www.youtube.com/watch?v=f"},
                      {"type":"Trailer","site":"YouTube","url":"https://www.youtube.com/watch?v=xxU571CuZfM"}],
     "watchProviders":[{"iso_3166_1":"FR","flatrate":[{"name":"Netflix"},{"name":"Netflix Standard with Ads"}]},
                       {"iso_3166_1":"US","buy":[{"name":"Apple TV"}]}]}
    """

    @Test("A film's payload: runtime, rating, genres, original title, cast, director, trailer, services")
    func decodesAFilm() throws {
        let details = try decode(movieJSON)
        #expect(details.runtimeMinutes == 109)
        #expect(details.voteAverage == 6.969)
        #expect(details.voteCount == 81)
        #expect(details.genres == ["Romance", "Comédie"])
        #expect(details.originalTitle == "Guarding Stars")
        #expect(details.originalLanguage == "en")
        #expect(details.releaseDate == "2026-11-18")
        #expect(details.backdropPath == "/qHvap0vpfTBIbv7cnR0OyBRqQHG.jpg")
        // A member without a name is dropped, not the list.
        #expect(details.cast.map(\.name) == ["Leighton Meester", "Jared Padalecki"])
        #expect(details.cast.first?.character == "Hannah")
        #expect(details.cast.last?.profilePath == nil)
        #expect(details.creators == ["Elizabeth Allen Rosenbaum"])
        #expect(details.trailerURL?.absoluteString == "https://www.youtube.com/watch?v=xxU571CuZfM")
        // Only subscription services (`flatrate`): a region that only sells has none.
        #expect(details.streamingProviders == ["FR": ["Netflix", "Netflix Standard with Ads"]])
    }

    @Test("A series' payload: episode length, first air date, creators, a teaser when no trailer")
    func decodesASeries() throws {
        let details = try decode("""
        {"id":1399,"name":"Game of Thrones","originalName":"Game of Thrones","firstAirDate":"2011-04-17",
         "episodeRunTime":[57,60],"voteAverage":8.5,"voteCount":28227,
         "createdBy":[{"id":1,"name":"David Benioff"},{"id":2,"name":"D.B. Weiss"}],
         "credits":{"cast":[],"crew":[]},
         "relatedVideos":[{"type":"Featurette","site":"YouTube","url":"https://www.youtube.com/watch?v=f"},
                          {"type":"Teaser","site":"YouTube","url":"https://www.youtube.com/watch?v=t"}]}
        """)
        #expect(details.runtimeMinutes == 57)
        #expect(details.releaseDate == "2011-04-17")
        #expect(details.creators == ["David Benioff", "D.B. Weiss"])
        #expect(details.trailerURL?.absoluteString == "https://www.youtube.com/watch?v=t")
        #expect(details.cast.isEmpty)
    }

    @Test("Missing or malformed fields empty their block, never the decode")
    func lossy() throws {
        let details = try decode("""
        {"id":1,"runtime":0,"episodeRunTime":[],"voteAverage":0,"voteCount":0,"genres":"oops",
         "credits":"oops","relatedVideos":[{"type":"Trailer","site":"Vimeo","url":"https://vimeo.com/1"}],
         "watchProviders":[{"iso_3166_1":"","flatrate":[{"name":"X"}]}],"originalTitle":""}
        """)
        #expect(details.runtimeMinutes == nil)
        #expect(details.voteAverage == nil)
        #expect(details.genres.isEmpty)
        #expect(details.cast.isEmpty)
        #expect(details.creators.isEmpty)
        #expect(details.trailerURL == nil)
        #expect(details.streamingProviders.isEmpty)
        #expect(details.originalTitle == nil)
    }

    @Test("The client reads /movie for a film and /tv for a series")
    func clientRoutes() async throws {
        let stub = StubSeerrTransport([
            .response(status: 200, body: movieJSON),
            .response(status: 200, body: #"{"id":1399,"name":"GoT"}"#)
        ])
        let client = SeerrClient(baseURL: URL(string: "http://192.168.1.20:5055")!, languageCode: "fr", transport: stub)
        _ = try await client.titleDetails(kind: .movie, tmdbId: 1_551_025, .session(cookie: "abc"))
        _ = try await client.titleDetails(kind: .tv, tmdbId: 1399, .session(cookie: "abc"))
        #expect(stub.requests.map { $0.url?.path } == ["/api/v1/movie/1551025", "/api/v1/tv/1399"])
    }

    @Test("Seerr's streaming region: empty means none, and it wins over the device's")
    func streamingRegion() throws {
        let empty = try SeerrJSON.decoder().decode(
            SeerrPublicSettings.self, from: Data(#"{"mediaServerType":2,"streamingRegion":""}"#.utf8))
        #expect(empty.streamingRegion == nil)
        let french = try SeerrJSON.decoder().decode(
            SeerrPublicSettings.self, from: Data(#"{"mediaServerType":2,"streamingRegion":"fr"}"#.utf8))
        #expect(french.streamingRegion == "FR")
        #expect(SeerrRequestFiche.region(seerr: "FR", device: "BE") == "FR")
        #expect(SeerrRequestFiche.region(seerr: nil, device: "be") == "BE")
        #expect(SeerrRequestFiche.region(seerr: nil, device: nil) == nil)
    }

    @Test("Services: the region's own, a plan folded into its service, three at most")
    func providers() {
        let details = SeerrTitleDetails(streamingProviders: [
            "FR": ["Netflix", "Netflix Standard with Ads", "Canal+", "Prime Video", "Disney Plus"]
        ])
        #expect(SeerrRequestFiche.providers(details, region: "FR") == ["Netflix", "Canal+", "Prime Video"])
        #expect(SeerrRequestFiche.providers(details, region: "US").isEmpty)
        #expect(SeerrRequestFiche.providers(details, region: nil).isEmpty)
    }

    @Test("A release date is TMDb's day, whatever the time zone")
    func releaseDate() throws {
        let date = try #require(SeerrRequestFiche.releaseDate("2026-11-18"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: 2026, month: 11, day: 18))
        #expect(SeerrRequestFiche.releaseDate("2026") == nil)
        #expect(SeerrRequestFiche.releaseDate(nil) == nil)
    }

    @MainActor
    @Test("Infos: a film says « directed by », a series « created by »; an original title equal to the title is left out")
    func facts() {
        let loc = LocalizationManager()
        let details = SeerrTitleDetails(
            runtimeMinutes: 109, originalTitle: "Guarding Stars", originalLanguage: "en",
            releaseDate: "2026-11-18", creators: ["Elizabeth Allen Rosenbaum"],
            streamingProviders: ["FR": ["Netflix"]])
        let film = SeerrTitle(kind: .movie, tmdbId: 1, title: "Protection (très) rapprochée")
        let labels = SeerrRequestFiche.facts(title: film, details: details, streamingRegion: "FR", loc: loc).map(\.label)
        #expect(labels == [
            loc.localized("seerr.fiche.directedBy"), loc.localized("seerr.fiche.release"),
            loc.localized("seerr.fiche.runtime"), loc.localized("seerr.fiche.originalLanguage"),
            loc.localized("seerr.fiche.originalTitle"), loc.localized("seerr.fiche.streaming")
        ])
        let series = SeerrTitle(kind: .tv, tmdbId: 2, title: "Guarding Stars")
        let seriesLabels = SeerrRequestFiche.facts(title: series, details: details, streamingRegion: nil, loc: loc)
            .map(\.label)
        #expect(seriesLabels.first == loc.localized("seerr.fiche.createdBy"))
        #expect(!seriesLabels.contains(loc.localized("seerr.fiche.originalTitle")))
        #expect(seriesLabels.contains(loc.localized("seerr.fiche.episodeRuntime")))
    }
}
