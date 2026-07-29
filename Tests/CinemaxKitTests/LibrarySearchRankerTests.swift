import Testing
import Foundation
@testable import Cinemax
@testable import CinemaxKit
import JellyfinAPI

private func makePerson(id: String, name: String) -> BaseItemDto {
    var dto = BaseItemDto()
    dto.id = id
    dto.name = name
    dto.type = .person
    return dto
}

/// Tests for `LibrarySearchRanker.rankPersons` — the person half of the search
/// SSOT. Unlike `rank`, it issues a single server call: Jellyfin's contiguous,
/// punctuation-sensitive `searchTerm` breaks titles ("Mission Impossible" misses
/// "Mission : Impossible") but not person names, where a `contains` is enough.
/// The local scoring exists only to order the row.
@Suite("LibrarySearchRanker — persons")
struct LibrarySearchRankerPersonTests {

    @Test("orders matches by score, exact name first")
    func personsRankedByScore() async throws {
        let mock = MockAPIClient()
        mock.stubbedPersonResults = [
            makePerson(id: "p1", name: "Cillian Murphy Jr."),
            makePerson(id: "p2", name: "Cillian Murphy"),
        ]

        let result = await LibrarySearchRanker.rankPersons(
            query: "cillian murphy", userId: "u1", api: mock
        )
        #expect(result.map(\.id) == ["p2", "p1"])
    }

    @Test("drops the zero-score noise the server returned")
    func personsDropNonMatches() async throws {
        let mock = MockAPIClient()
        mock.stubbedPersonResults = [
            makePerson(id: "p1", name: "Cillian Murphy"),
            makePerson(id: "p2", name: "Zendaya"),
        ]

        let result = await LibrarySearchRanker.rankPersons(
            query: "murphy", userId: "u1", api: mock
        )
        #expect(result.map(\.id) == ["p1"])
    }

    @Test("caps the row at 10 portraits")
    func personsCapped() async throws {
        let mock = MockAPIClient()
        mock.stubbedPersonResults = (0..<25).map {
            makePerson(id: "p\($0)", name: "Murphy \($0)")
        }

        let result = await LibrarySearchRanker.rankPersons(
            query: "murphy", userId: "u1", api: mock
        )
        #expect(result.count == LibrarySearchRanker.personRowLimit)
    }

    @Test("swallows a failure and returns empty")
    func personsFailureIsSilent() async throws {
        let mock = MockAPIClient()
        mock.shouldThrow = true

        let result = await LibrarySearchRanker.rankPersons(
            query: "murphy", userId: "u1", api: mock
        )
        #expect(result.isEmpty)
    }

    @Test("an empty query issues no request")
    func emptyQuerySkipsFetch() async throws {
        let mock = MockAPIClient()
        mock.stubbedPersonResults = [makePerson(id: "p1", name: "Cillian Murphy")]

        let result = await LibrarySearchRanker.rankPersons(
            query: "   ", userId: "u1", api: mock
        )
        #expect(result.isEmpty)
        #expect(mock.searchPersonsCallCount == 0)
    }

    /// A person fetch that throws must not disturb the title results — the row
    /// simply doesn't render. The error state with its Retry button belongs to
    /// the title search alone.
    @Test("a person failure leaves title results untouched")
    func personFailureDoesNotBreakTitles() async throws {
        let mock = MockAPIClient()
        mock.stubbedSearchResults = [makePerson(id: "m1", name: "Oppenheimer")]
        mock.searchPersonsHandler = { _ in throw MockError.genericFailure }

        let titles = await LibrarySearchRanker.rank(
            query: "oppenheimer", userId: "u1",
            includeItemTypes: [.movie], api: mock
        )
        let people = await LibrarySearchRanker.rankPersons(
            query: "oppenheimer", userId: "u1", api: mock
        )

        #expect(titles.items.count == 1)
        #expect(titles.failed == false)
        #expect(people.isEmpty)
    }
}
