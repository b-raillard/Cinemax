import Foundation
import Testing
@preconcurrency import JellyfinAPI
@testable import CinemaxKit

/// A server generation whose raw responses sit in `Fixtures/`. Adding one is a
/// script run plus a case here — see `Fixtures/README.md`
/// (`scripts/fixtures/capture-jellyfin-fixtures.sh`).
enum FixtureServer: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// `jellyfin/jellyfin:10.10.7`, captured 2026-09-11.
    case jellyfin10_10 = "10.10"
    /// `jellyfin/jellyfin:10.11.11`, captured 2026-09-11.
    case jellyfin10_11 = "10.11"
    /// `UserDto` + `BaseItemDto-movie` from the reference server (12.0,
    /// 2026-09-10); `Resume` + `NextUp` from `jellyfin/jellyfin:12.0` = 12.0.0.
    case jellyfin12_0 = "12.0"

    var testDescription: String { "Jellyfin \(rawValue)" }

    func resource(_ name: String) -> String { "jellyfin-\(rawValue)-\(name)" }

    /// What the generation writes in the movie's `UserData.ItemId`.
    ///
    /// Measured, not assumed: **10.10 sends `Guid.Empty` on every item**, 10.11
    /// and 12.0 the item's own id. Harmless for the app — nothing reads
    /// `userData.itemID` — but it is exactly the kind of difference an
    /// in-memory DTO would never have shown, so it is pinned here rather than
    /// papered over with a shape-agnostic assertion.
    var movieUserDataItemID: String {
        switch self {
        case .jellyfin10_10: "00000000000000000000000000000000"
        case .jellyfin10_11, .jellyfin12_0: "11111111111111111111111111111111"
        }
    }
}

/// A4 of the 2026-09-10 platform audit: **the decode contract, against bytes a
/// real server actually sent — on every server generation the app supports.**
///
/// jellyfin-sdk-swift 3.1.0 is generated from the 12.0 spec, and that spec
/// marks some fields required — so the SDK calls `decode` on them, not
/// `decodeIfPresent`. A server that omitted one would fail **the whole DTO**,
/// not just that field: `UserItemDataDto.key` (every list carrying userData),
/// `UserPolicy.authenticationProviderID` / `.passwordResetProviderID` (login
/// and `validateSession`). The blast radius is the app's hot paths, which is
/// why this exists.
///
/// **Every other test in the suite builds its DTOs in memory**, which proves
/// nothing about the wire: an in-memory `UserItemDataDto(key:)` satisfies the
/// compiler and never exercises `init(from:)`. These fixtures are raw
/// responses decoded with the SDK's own decoder configuration (`JSONDecoder` +
/// `OpenISO8601DateFormatter`, as `JellyfinClient` builds it), so what is
/// asserted is the decoder the app really runs against bytes servers really
/// produced.
///
/// **Scope, stated plainly: 10.10.7, 10.11.11 and 12.0 are measured; the 10.9
/// floor is not.** The 10.x sets come from throwaway Docker servers fed
/// synthetic clips, so they speak for the server's serialisation, not for a
/// real library's metadata — the reference server's 12.0 item (HDR, nine
/// streams, provider metadata) stays the richest single fixture.
///
/// Identifiers, titles and paths are placeholders of the same SHAPE (32-hex or
/// dashed guids, `/data/...` paths). Nothing else is touched: every key the
/// server sent is still there, with its original type.
@Suite("Server DTO decoding fixtures (Jellyfin 10.10 / 10.11 / 12.0)")
struct ServerDTODecodingFixtureTests {

    private static let movieID = "11111111111111111111111111111111"
    private static let resumePositionTicks = 1_200_000_000
    private static let fixtureNames = ["UserDto", "BaseItemDto-movie", "Resume", "NextUp"]

    /// The SDK's decoder, as `JellyfinClient.init` configures it.
    ///
    /// Reproduced rather than reached for: the client exposes no decoder, and
    /// while `OpenISO8601DateFormatter` is a public class its `init()` is not,
    /// so it cannot be constructed from here. This mirrors it exactly —
    /// including the fallback to a seconds-precision format, which is what
    /// makes Jellyfin's two date spellings both parse. A divergence would show
    /// up as a date test failing, not as a silently different decoder.
    private func sdkDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(SDKDateFormatter())
        return decoder
    }

    private func fixture(_ server: FixtureServer, _ name: String) throws -> Data {
        // `project.yml` copies `Tests/CinemaxKitTests/Fixtures` as a FOLDER
        // reference, so the JSON keeps that subdirectory inside the bundle.
        let resource = server.resource(name)
        let url = try #require(
            Bundle(for: FixtureBundleToken.self)
                .url(forResource: resource, withExtension: "json", subdirectory: "Fixtures"),
            "fixture Fixtures/\(resource).json missing from the test bundle — check project.yml's resources"
        )
        return try Data(contentsOf: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ server: FixtureServer, _ name: String) throws -> T {
        try sdkDecoder().decode(T.self, from: try fixture(server, name))
    }

    private func jsonObject(_ server: FixtureServer, _ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: try fixture(server, name)) as? [String: Any])
    }

    // MARK: - The wire, before any decoder

    /// Decoder-independent, so a failure names the VERSION, the FILE, the FIELD
    /// and the JSON path where it should have been — which a `DecodingError`
    /// surfacing from deep inside the SDK does not reliably do.
    @Test("every strict-decode field of SDK 3.1.0 is on the wire", arguments: FixtureServer.allCases)
    func strictFieldsAreOnTheWire(_ server: FixtureServer) throws {
        for name in Self.fixtureNames {
            let scan = StrictFieldScan(try jsonObject(server, name), root: name)
            #expect(scan.checked > 0, "\(server) \(name): no UserData / Policy object found — the scan proved nothing")
            #expect(
                scan.missing.isEmpty,
                "\(server) \(name): strict field(s) absent — SDK 3.1.0 fails the whole DTO: \(scan.missing.joined(separator: ", "))"
            )
        }
    }

    // MARK: - The SDK's own decoder

    @Test("a real BaseItemDto decodes, userData included", arguments: FixtureServer.allCases)
    func baseItemDtoDecodes(_ server: FixtureServer) throws {
        let item = try decode(BaseItemDto.self, server, "BaseItemDto-movie")

        #expect(item.id == Self.movieID)
        #expect(item.name == "Fixture Movie")
        #expect(item.type == .movie)
        // Dates go through the SDK's own formatter — the one thing a plain
        // `JSONDecoder()` would get wrong.
        #expect(item.premiereDate != nil)
        // `MediaSources` is what the Version row and `MediaSourceQuality` rank.
        #expect((item.mediaSources?.count ?? 0) >= 1)
        #expect(item.mediaSources?.first?.mediaStreams?.isEmpty == false)
    }

    /// The field the audit flagged first: `UserItemDataDto.key` is a
    /// non-optional `decode` in SDK 3.1.0, so a server omitting it would take
    /// the ENTIRE item down — every rail, every grid.
    @Test("UserItemDataDto.key is present on the wire and decodes", arguments: FixtureServer.allCases)
    func userItemDataKeyDecodes(_ server: FixtureServer) throws {
        let item = try decode(BaseItemDto.self, server, "BaseItemDto-movie")
        let userData = try #require(item.userData)

        #expect(userData.key.isEmpty == false, "`key` is decoded non-optionally — an absent one fails the whole DTO")
        #expect(userData.itemID == server.movieUserDataItemID)
        #expect(userData.isPlayed != nil)
        #expect(userData.playbackPositionTicks != nil)
        #expect(userData.isFavorite != nil)
    }

    /// The other two strict fields. Both live on the policy the app reads for
    /// every permission decision (`isAdministrator`, `syncPlayAccess`,
    /// `enableRemoteControlOfOtherUsers`), so losing the DTO loses all of them.
    @Test("UserDto and its policy decode, including the two provider ids", arguments: FixtureServer.allCases)
    func userDtoDecodes(_ server: FixtureServer) throws {
        let user = try decode(UserDto.self, server, "UserDto")

        #expect(user.id == "33333333333333333333333333333333")
        #expect(user.name == "fixture-user")
        let policy = try #require(user.policy)
        #expect(policy.authenticationProviderID.isEmpty == false)
        #expect(policy.passwordResetProviderID.isEmpty == false)
        // The three permissions the app actually gates on.
        #expect(policy.isAdministrator != nil)
        #expect(policy.syncPlayAccess != nil)
        #expect(policy.enableRemoteControlOfOtherUsers != nil)
        // And the per-user playback configuration `ProfileModel` read-modify-writes.
        #expect(user.configuration != nil)
    }

    /// Continue Watching: the list whose every entry carries userData, so one
    /// absent `Key` would blank the whole rail AND the Home hero it feeds.
    @Test("Continue Watching decodes, with a key on every item", arguments: FixtureServer.allCases)
    func resumeDecodes(_ server: FixtureServer) throws {
        let result = try decode(BaseItemDtoQueryResult.self, server, "Resume")
        let items = try #require(result.items)

        let movie = try #require(items.first { $0.id == Self.movieID })
        #expect(movie.type == .movie)
        #expect(movie.userData?.playbackPositionTicks == Self.resumePositionTicks)
        let episode = try #require(items.first { $0.type == .episode })
        #expect(episode.indexNumber == 2)
        #expect(episode.userData?.playbackPositionTicks == Self.resumePositionTicks)
        for item in items {
            #expect(item.userData?.key.isEmpty == false, "\(server): \(item.type?.rawValue ?? "?") \(item.name ?? "?") carries no userData key")
        }
    }

    /// #209 — the wire difference the app's own query shape exposes, pinned the
    /// way `movieUserDataItemID` pins 10.10's `Guid.Empty`: **12.0 also answers
    /// with the Season AND the Series** of a part-watched episode, both at
    /// position 0; 10.10 and 10.11 answer with the two playable items alone.
    ///
    /// It matters because Home renders this list VERBATIM, so those two entries
    /// reached « Reprendre » as cards with no media source behind them, and
    /// `heroItem` (`resumeItems.first ?? latestItems.first`) could make one of
    /// them the hero of the whole screen.
    ///
    /// These fixtures were captured with the app's **pre-fix** shape (no
    /// `mediaTypes`), which is what makes them evidence about the SERVER rather
    /// than about the client — and what keeps this test meaningful now that the
    /// client filters. Re-measured live on 2026-09-12 against throwaway
    /// 10.10.7 / 10.11.11 / 12.0.0 servers: same shape, same three answers.
    @Test("Continue Watching carries the Season and the Series on 12.0 only", arguments: FixtureServer.allCases)
    func resumeCarriesNonPlayableEntriesOn12Only(_ server: FixtureServer) throws {
        let result = try decode(BaseItemDtoQueryResult.self, server, "Resume")
        let kinds = Set(try #require(result.items).compactMap(\.type))

        switch server {
        case .jellyfin10_10, .jellyfin10_11:
            #expect(kinds == [.movie, .episode])
        case .jellyfin12_0:
            #expect(kinds == [.movie, .episode, .season, .series])
        }
    }

    /// The property `getResumeItems`' `mediaTypes: [.video]` rests on, asserted
    /// on every generation at once: the server tags the playable entries
    /// `"Video"` and tags the two folders `"Unknown"`. Without this the
    /// parameter would be a fix nobody can explain from the repository.
    ///
    /// `mediaTypes` was chosen over `includeItemTypes: [.movie, .episode]` and
    /// `excludeItemTypes: [.season, .series]` — all three measured, all three
    /// fix 12.0 — because the Widget's hand-built copy of this route
    /// (`JellyfinLite.fetchResumeItems`) already sends it, and because it says
    /// "playable video" instead of enumerating kinds that an allow-list would
    /// have to be extended for.
    @Test("MediaType.video selects exactly the playable entries", arguments: FixtureServer.allCases)
    func videoMediaTypeSelectsThePlayableEntries(_ server: FixtureServer) throws {
        let result = try decode(BaseItemDtoQueryResult.self, server, "Resume")
        let items = try #require(result.items)

        let playable = items.filter { $0.mediaType == .video }
        #expect(playable.isEmpty == false)
        #expect(Set(playable.compactMap(\.type)) == [.movie, .episode])

        // The converse, so the filter is proven to remove only folders: every
        // entry it drops is a Season or a Series tagged `Unknown`.
        for dropped in items where dropped.mediaType != .video {
            #expect(
                dropped.mediaType == .unknown,
                "\(server): \(dropped.type?.rawValue ?? "?") carries MediaType \(dropped.mediaType?.rawValue ?? "<absent>")"
            )
            #expect(dropped.type == .season || dropped.type == .series)
        }
    }

    @Test("Next Up decodes, with a key on the episode", arguments: FixtureServer.allCases)
    func nextUpDecodes(_ server: FixtureServer) throws {
        let result = try decode(BaseItemDtoQueryResult.self, server, "NextUp")
        let next = try #require(result.items?.first)

        #expect(next.type == .episode)
        #expect(next.parentIndexNumber == 1)
        #expect(next.indexNumber == 2)
        #expect(next.seriesName == "Fixture Show")
        #expect(next.userData?.key.isEmpty == false)
    }

    // MARK: - Paired controls

    /// The control that stops the tests above passing vacuously: a response
    /// with `Key` removed must FAIL, which is what makes the field's presence
    /// in the fixture meaningful rather than incidental.
    @Test("removing UserData.Key fails the whole item", arguments: FixtureServer.allCases)
    func missingKeyFailsTheWholeItem(_ server: FixtureServer) throws {
        var json = try jsonObject(server, "BaseItemDto-movie")
        var userData = try #require(json["UserData"] as? [String: Any])
        userData.removeValue(forKey: "Key")
        json["UserData"] = userData
        let mutated = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: (any Error).self) {
            _ = try sdkDecoder().decode(BaseItemDto.self, from: mutated)
        }
    }

    /// The blast radius, measured: ONE item without a key takes the intact
    /// items of the same response down with it — the rail, not the card.
    @Test("removing one item's UserData.Key fails the whole Continue Watching list", arguments: FixtureServer.allCases)
    func missingKeyFailsTheWholeRail(_ server: FixtureServer) throws {
        var json = try jsonObject(server, "Resume")
        var items = try #require(json["Items"] as? [[String: Any]])
        try #require(items.count >= 2, "the point is that the OTHER, intact items go down too")
        var userData = try #require(items[0]["UserData"] as? [String: Any])
        userData.removeValue(forKey: "Key")
        items[0]["UserData"] = userData
        json["Items"] = items
        let mutated = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: (any Error).self) {
            _ = try sdkDecoder().decode(BaseItemDtoQueryResult.self, from: mutated)
        }
    }

    /// Same control for the two policy fields — sign-in and `validateSession`
    /// decode this DTO, so either one missing would read as a failed login.
    @Test(
        "removing a provider id fails the whole user",
        arguments: FixtureServer.allCases, ["AuthenticationProviderId", "PasswordResetProviderId"]
    )
    func missingProviderIdFailsTheWholeUser(_ server: FixtureServer, _ field: String) throws {
        var json = try jsonObject(server, "UserDto")
        var policy = try #require(json["Policy"] as? [String: Any])
        try #require(policy.removeValue(forKey: field) != nil, "\(server): the fixture never carried \(field)")
        json["Policy"] = policy
        let mutated = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: (any Error).self) {
            _ = try sdkDecoder().decode(UserDto.self, from: mutated)
        }
    }
}

/// Walks a raw response for the strict-decode fields of SDK 3.1.0 —
/// `UserData.Key` on every object under a `UserData` key, and the two provider
/// ids on every `Policy` — and records each absent one by JSON path.
private struct StrictFieldScan {
    private(set) var checked = 0
    private(set) var missing: [String] = []

    init(_ root: Any, root rootName: String) {
        visit(root, path: rootName)
    }

    private mutating func visit(_ node: Any, path: String) {
        if let object = node as? [String: Any] {
            for (key, value) in object {
                let here = "\(path).\(key)"
                if key == "UserData", let userData = value as? [String: Any] {
                    check(userData, field: "Key", at: here)
                }
                if key == "Policy", let policy = value as? [String: Any] {
                    check(policy, field: "AuthenticationProviderId", at: here)
                    check(policy, field: "PasswordResetProviderId", at: here)
                }
                visit(value, path: here)
            }
        } else if let array = node as? [Any] {
            for (index, value) in array.enumerated() {
                visit(value, path: "\(path)[\(index)]")
            }
        }
    }

    private mutating func check(_ object: [String: Any], field: String, at path: String) {
        checked += 1
        if !(object[field] is String) { missing.append("\(path).\(field)") }
    }
}

/// Anchors `Bundle(for:)` on the test bundle so the fixtures resolve. A class
/// because `Bundle(for:)` takes `AnyClass`.
private final class FixtureBundleToken {}

/// Mirror of jellyfin-sdk-swift's `OpenISO8601DateFormatter`, whose `init()` is
/// internal to the SDK. Same two formats, same order: fractional seconds
/// first, then a seconds-precision fallback — Jellyfin emits both.
private final class SDKDateFormatter: DateFormatter, @unchecked Sendable {
    private static let withoutSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter
    }()

    override init() {
        super.init()
        calendar = Calendar(identifier: .iso8601)
        locale = Locale(identifier: "en_US_POSIX")
        timeZone = TimeZone(secondsFromGMT: 0)
        dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func date(from string: String) -> Date? {
        super.date(from: string) ?? Self.withoutSeconds.date(from: string)
    }
}
