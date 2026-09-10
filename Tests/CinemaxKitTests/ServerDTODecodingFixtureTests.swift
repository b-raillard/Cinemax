import Foundation
import Testing
@preconcurrency import JellyfinAPI
@testable import CinemaxKit

/// A4 of the 2026-09-10 platform audit: **the decode contract, against bytes a
/// real server actually sent.**
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
/// compiler and never exercises `init(from:)`. These fixtures are raw responses
/// captured from the reference server on 2026-09-10 and decoded with the SDK's
/// own decoder configuration (`JSONDecoder` + `OpenISO8601DateFormatter`, as
/// `JellyfinClient` builds it), so what is asserted is the decoder the app
/// really runs against bytes the server really produced.
///
/// **Scope, stated plainly: the reference server is Jellyfin 12.0, so these
/// fixtures prove the 12.0 contract — NOT 10.10.** The app's floor is 10.9 and
/// nothing here speaks for it. What they do rule out is the more likely
/// failure: that the 12.0-generated SDK mis-decodes a 12.0 server. A 10.x
/// fixture would need a 10.x server to capture from; until one exists, the
/// 10.x side of the contract rests on the `[Required]` columns and
/// `WhenWritingNull` serialisation the audit checked by reading, not by
/// measuring.
///
/// Identifiers, titles and paths are replaced by fixed placeholders of the same
/// SHAPE (32-hex guids, a `/data/...` path). Nothing else is touched: every key
/// the server sent is still there, with its original type.
@Suite("Server DTO decoding fixtures (Jellyfin 12.0)")
struct ServerDTODecodingFixtureTests {

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

    private func fixture(_ name: String) throws -> Data {
        // `project.yml` copies `Tests/CinemaxKitTests/Fixtures` as a FOLDER
        // reference, so the JSON keeps that subdirectory inside the bundle.
        let url = try #require(
            Bundle(for: FixtureBundleToken.self)
                .url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "fixture Fixtures/\(name).json missing from the test bundle — check project.yml's resources"
        )
        return try Data(contentsOf: url)
    }

    @Test("a real BaseItemDto decodes, userData included")
    func baseItemDtoDecodes() throws {
        let item = try sdkDecoder().decode(BaseItemDto.self, from: try fixture("jellyfin-12.0-BaseItemDto-movie"))

        #expect(item.id == "11111111111111111111111111111111")
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
    @Test("UserItemDataDto.key is present on the wire and decodes")
    func userItemDataKeyDecodes() throws {
        let item = try sdkDecoder().decode(BaseItemDto.self, from: try fixture("jellyfin-12.0-BaseItemDto-movie"))
        let userData = try #require(item.userData)

        #expect(userData.key.isEmpty == false, "`key` is decoded non-optionally — an absent one fails the whole DTO")
        #expect(userData.itemID == "11111111111111111111111111111111")
        #expect(userData.isPlayed != nil)
        #expect(userData.playbackPositionTicks != nil)
        #expect(userData.isFavorite != nil)
    }

    /// The other two strict fields. Both live on the policy the app reads for
    /// every permission decision (`isAdministrator`, `syncPlayAccess`,
    /// `enableRemoteControlOfOtherUsers`), so losing the DTO loses all of them.
    @Test("UserDto and its policy decode, including the two provider ids")
    func userDtoDecodes() throws {
        let user = try sdkDecoder().decode(UserDto.self, from: try fixture("jellyfin-12.0-UserDto"))

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

    /// The paired control that stops the three tests above passing vacuously: a
    /// response with `Key` removed must FAIL, which is what makes the field's
    /// presence in the fixture meaningful rather than incidental.
    @Test("removing UserData.Key fails the whole item, as the SDK's strict decode implies")
    func missingKeyFailsTheWholeItem() throws {
        let raw = try fixture("jellyfin-12.0-BaseItemDto-movie")
        var json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var userData = try #require(json["UserData"] as? [String: Any])
        userData.removeValue(forKey: "Key")
        json["UserData"] = userData
        let mutated = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: (any Error).self) {
            _ = try sdkDecoder().decode(BaseItemDto.self, from: mutated)
        }
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
