import Testing
import Foundation
import JellyfinAPI
@testable import CinemaxKit

@Suite("CinemaxKit Tests")
struct CinemaxKitTests {

    @Test("ServerInfo initialization")
    func testServerInfo() {
        let info = ServerInfo(
            name: "Test Server",
            serverID: "abc123",
            version: "10.8.10",
            url: URL(string: "http://localhost:8096")!
        )
        #expect(info.name == "Test Server")
        #expect(info.version == "10.8.10")
    }

    @Test("ImageURLBuilder generates correct URLs")
    func testImageURLBuilder() {
        let builder = ImageURLBuilder(serverURL: URL(string: "http://localhost:8096")!)
        let url = builder.imageURL(itemId: "item123", imageType: .primary, maxWidth: 300)
        #expect(url.path().contains("/Items/item123/Images/Primary"))
        #expect(url.absoluteString.contains("maxWidth=300"))
    }

    /// Locks the contract `ChapterController`/`VLCStreamPresenter` depend on:
    /// the chapter thumbnail URL must carry the server's per-chapter `imageTag`
    /// as a cache-buster, else regenerated chapter images stay masked behind
    /// Nuke's disk-cache URL key (see `AuthenticatedImageFetch`) until eviction.
    @Test("ImageURLBuilder chapter URL carries the cache-busting tag")
    func testChapterImageURLCarriesTag() {
        let builder = ImageURLBuilder(serverURL: URL(string: "http://localhost:8096")!)
        let url = builder.chapterImageURL(itemId: "item123", imageIndex: 2, tag: "abc123tag", maxWidth: 480)
        #expect(url.path().contains("/Items/item123/Images/Chapter/2"))
        #expect(url.absoluteString.contains("tag=abc123tag"))
    }

    @Test("ImageURLBuilder chapter URL omits the tag param when nil")
    func testChapterImageURLWithoutTag() {
        let builder = ImageURLBuilder(serverURL: URL(string: "http://localhost:8096")!)
        let url = builder.chapterImageURL(itemId: "item123", imageIndex: 0, maxWidth: 480)
        #expect(!url.absoluteString.contains("tag="))
    }
}

/// `setEndpointPath(_:preservingBasePathOf:)` must keep the sub-path of a
/// reverse-proxy-hosted server (`https://host/jellyfin`) — a regression silently
/// 404s every hand-built playback/image URL. Locks all four base-path shapes.
@Suite("URLComponents.setEndpointPath")
struct SetEndpointPathTests {

    private func resolved(server: String, endpoint: String) -> String {
        let url = URL(string: server)!
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.setEndpointPath(endpoint, preservingBasePathOf: url)
        return comps.path
    }

    @Test("empty base path uses the endpoint verbatim")
    func emptyBase() {
        #expect(resolved(server: "https://host", endpoint: "/Videos/1/stream") == "/Videos/1/stream")
    }

    @Test("root base path uses the endpoint verbatim")
    func rootBase() {
        #expect(resolved(server: "https://host/", endpoint: "/Videos/1/stream") == "/Videos/1/stream")
    }

    @Test("sub-path base is preserved as a prefix")
    func subPathBase() {
        #expect(resolved(server: "https://host/jellyfin", endpoint: "/Videos/1/stream") == "/jellyfin/Videos/1/stream")
    }

    @Test("trailing-slash sub-path base drops the slash before prefixing")
    func trailingSlashBase() {
        #expect(resolved(server: "https://host/jellyfin/", endpoint: "/Videos/1/stream") == "/jellyfin/Videos/1/stream")
    }
}

/// `redactedURL` scrubs the access token before a URL hits the logs. Security
/// sensitive — locks the redacted names (incl. case variants) and that
/// non-secret items and structure survive.
@Suite("redactedURL")
struct RedactedURLTests {

    @Test("redacts api_key")
    func apiKey() {
        #expect(redactedURL("https://h/p?api_key=secret") == "https://h/p?api_key=REDACTED")
    }

    @Test("redacts case-variant names and any token-bearing key")
    func caseVariants() {
        #expect(redactedURL("https://h/p?ApiKey=s") == "https://h/p?ApiKey=REDACTED")
        #expect(redactedURL("https://h/p?apikey=s") == "https://h/p?apikey=REDACTED")
        #expect(redactedURL("https://h/p?X-Emby-Token=s") == "https://h/p?X-Emby-Token=REDACTED")
        #expect(redactedURL("https://h/p?AccessToken=s") == "https://h/p?AccessToken=REDACTED")
    }

    @Test("preserves non-secret query items and their order")
    func preservesOthers() {
        #expect(redactedURL("https://h/p?api_key=s&static=true") == "https://h/p?api_key=REDACTED&static=true")
        #expect(redactedURL("https://h/p?static=true") == "https://h/p?static=true")
    }

    @Test("nil and empty map to \"nil\"")
    func nilEmpty() {
        #expect(redactedURL(nil as String?) == "nil")
        #expect(redactedURL("") == "nil")
    }

    @Test("URL overload redacts the same way")
    func urlOverload() {
        #expect(redactedURL(URL(string: "https://h/p?api_key=secret")!) == "https://h/p?api_key=REDACTED")
    }
}

/// SyncPlay timestamps: round-trip and the .NET 7-digit ("tick") fraction
/// fallback that `Date.ISO8601FormatStyle` rejects outright.
@Suite("SyncPlayDateParser")
struct SyncPlayDateParserTests {

    @Test("round-trips a Date through string/date")
    func roundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        let string = SyncPlayDateParser.string(from: date)
        let back = try #require(SyncPlayDateParser.date(from: string))
        #expect(abs(back.timeIntervalSince(date)) < 0.001)
    }

    @Test("parses a plain UTC timestamp without fractional seconds")
    func noFraction() throws {
        let plain = try #require(SyncPlayDateParser.date(from: "2024-01-02T03:04:05Z"))
        let withMs = try #require(SyncPlayDateParser.date(from: "2024-01-02T03:04:05.000Z"))
        #expect(abs(plain.timeIntervalSince(withMs)) < 0.0005)
    }

    @Test("falls back on 7-digit tick fractions and truncates to milliseconds")
    func sevenDigitTicks() throws {
        // .NET emits 100-ns ticks (7 fractional digits) that the format style rejects.
        let ticks = try #require(SyncPlayDateParser.date(from: "2024-01-02T03:04:05.1234567Z"))
        let ms = try #require(SyncPlayDateParser.date(from: "2024-01-02T03:04:05.123Z"))
        #expect(abs(ticks.timeIntervalSince(ms)) < 0.0005)
    }

    @Test("returns nil for a non-date string")
    func garbage() {
        #expect(SyncPlayDateParser.date(from: "not-a-date") == nil)
    }
}

// MARK: - Server version gating

@Suite("ServerVersion")
struct ServerVersionTests {

    @Test("Parses the 2-to-4 component forms Jellyfin reports")
    func parsesComponentForms() throws {
        let two = try #require(ServerVersion("10.10"))
        #expect(two == ServerVersion(10, 10, 0, 0))

        let three = try #require(ServerVersion("10.10.7"))
        #expect(three == ServerVersion(10, 10, 7, 0))

        let four = try #require(ServerVersion("10.8.13.0"))
        #expect(four == ServerVersion(10, 8, 13, 0))
    }

    @Test("Truncates a pre-release suffix rather than rejecting it")
    func parsesPreRelease() throws {
        // A release candidate carries the capabilities of its release; refusing
        // to parse it would silently disable every gated feature for testers.
        #expect(try #require(ServerVersion("10.11.0-rc1")) == ServerVersion(10, 11, 0))
        #expect(try #require(ServerVersion("10.11.0+build.5")) == ServerVersion(10, 11, 0))
        #expect(try #require(ServerVersion("v10.11.2")) == ServerVersion(10, 11, 2))
        #expect(try #require(ServerVersion("  10.10.7  ")) == ServerVersion(10, 10, 7))
    }

    @Test("Keeps the components read before an unparseable tail")
    func keepsLeadingComponents() throws {
        // `10.10.beta` → the suffix strip leaves `10.10.`, whose trailing empty
        // component must not throw away the two real ones.
        #expect(try #require(ServerVersion("10.10.beta")) == ServerVersion(10, 10, 0))
    }

    @Test("Rejects input with no leading integer")
    func rejectsGarbage() {
        #expect(ServerVersion("") == nil)
        #expect(ServerVersion("unknown") == nil)
        #expect(ServerVersion("...") == nil)
    }

    @Test("Orders numerically, not lexicographically")
    func ordersNumerically() throws {
        // The whole reason this type exists: as strings, "10.9" > "10.10".
        let nine = try #require(ServerVersion("10.9.0"))
        let ten = try #require(ServerVersion("10.10.0"))
        #expect(nine < ten)

        let patchTwo = try #require(ServerVersion("10.10.2"))
        let patchTen = try #require(ServerVersion("10.10.10"))
        #expect(patchTwo < patchTen)

        let older = try #require(ServerVersion("9.99.99"))
        let newer = try #require(ServerVersion("10.0.0"))
        #expect(older < newer)
    }

    @Test("supports() is inclusive of the threshold")
    func supportsThreshold() throws {
        let exact = try #require(ServerVersion("10.10.0"))
        let patch = try #require(ServerVersion("10.10.7"))
        let minor = try #require(ServerVersion("10.11.0"))
        let below = try #require(ServerVersion("10.9.11"))

        #expect(exact.supports(.itemUserDataEndpoint))
        #expect(patch.supports(.itemUserDataEndpoint))
        #expect(minor.supports(.itemUserDataEndpoint))
        #expect(below.supports(.itemUserDataEndpoint) == false)
    }

    // Jellyfin dropped the `10.` prefix after 10.11: the next release is 12.0
    // (there is no 10.12). The parser needs no change for it, but a threshold
    // written as 12.x must order ABOVE every 10.x — which is exactly what a
    // string compare would get wrong, and what this locks.
    @Test("Parses the 12.0 forms Jellyfin reports and orders them above 10.x")
    func twelveOrdersAboveTen() throws {
        #expect(try #require(ServerVersion("12.0.0")) == ServerVersion(12, 0, 0))
        #expect(try #require(ServerVersion("12.0")) == ServerVersion(12, 0, 0))
        #expect(try #require(ServerVersion("12.0.0-rc7")) == ServerVersion(12, 0, 0))
        #expect(try #require(ServerVersion("v12.0.1")) == ServerVersion(12, 0, 1))

        let twelve = try #require(ServerVersion("12.0.0"))
        let lastTen = try #require(ServerVersion("10.11.11"))
        #expect(twelve > lastTen)
        #expect(twelve.supports(.itemUserDataEndpoint))
    }

    // `GET /Items/{id}/Collections` ships in 12.0 (jellyfin#15516). A 10.x
    // server answers 404, so the threshold must refuse the last 10.11 patch and
    // admit 12.0.0 exactly — including its release candidates.
    @Test("collectionsReverseLookup admits 12.0 and refuses every 10.x")
    func collectionsReverseLookupThreshold() throws {
        #expect(ServerVersion.collectionsReverseLookup == ServerVersion(12, 0, 0))
        #expect(try #require(ServerVersion("10.11.11")).supports(.collectionsReverseLookup) == false)
        #expect(try #require(ServerVersion("10.10.7")).supports(.collectionsReverseLookup) == false)
        #expect(try #require(ServerVersion("12.0.0-rc7")).supports(.collectionsReverseLookup))
        #expect(try #require(ServerVersion("12.0.0")).supports(.collectionsReverseLookup))
        #expect(try #require(ServerVersion("12.1.0")).supports(.collectionsReverseLookup))
    }
}

// `DELETE /Videos/ActiveEncodings` is hidden from Jellyfin 12.0's OpenAPI
// spec, so jellyfin-sdk-swift ≥ 1.0 stopped generating it and the client
// builds the request by hand. The server still serves it; this locks the
// exact shape it expects (route, verb, both query names), since a typo here
// would leave every transcode job running until the server's own reaper.
@Suite("Hand-built hidden routes")
struct HiddenRouteRequestTests {

    @Test("stopEncoding targets DELETE /Videos/ActiveEncodings with deviceId + playSessionId")
    func stopEncodingRequestShape() throws {
        let request = JellyfinAPIClient.stopEncodingRequest(deviceID: "dev-1", playSessionID: "ps-9")
        #expect(request.url?.path == "/Videos/ActiveEncodings")
        #expect(request.method.rawValue == "DELETE")
        let query = try #require(request.query)
        #expect(query.map(\.0) == ["deviceId", "playSessionId"])
        #expect(query.map(\.1) == ["dev-1", "ps-9"])
        #expect(request.body == nil)
    }
}

// MARK: - Remote control, receiving side

@Suite("JellyfinSocket frame parsing")
struct JellyfinSocketParsingTests {

    @Test("Parses a Play message")
    func parsesPlay() throws {
        let request = try #require(JellyfinSocket.parsePlay([
            "ItemIds": ["abc"],
            "PlayCommand": "PlayNow",
            "StartPositionTicks": NSNumber(value: 1_200_000_000),
            "MediaSourceId": "src-1"
        ]))
        #expect(request.itemIds == ["abc"])
        #expect(request.isPlayNow)
        #expect(request.startPositionTicks == 1_200_000_000)
        #expect(request.mediaSourceId == "src-1")
    }

    @Test("Drops a Play message with no items")
    func dropsEmptyPlay() {
        #expect(JellyfinSocket.parsePlay(["ItemIds": [String](), "PlayCommand": "PlayNow"]) == nil)
        #expect(JellyfinSocket.parsePlay(["PlayCommand": "PlayNow"]) == nil)
    }

    @Test("An unknown play command parses but is not PlayNow")
    func unknownCommandIsNotPlayNow() throws {
        // Kept as a raw string precisely so a future value is ignored rather
        // than mis-mapped onto PlayNow — the queue-less client can only honor
        // "start this now".
        let next = try #require(JellyfinSocket.parsePlay(["ItemIds": ["a"], "PlayCommand": "PlayNext"]))
        #expect(!next.isPlayNow)
        let missing = try #require(JellyfinSocket.parsePlay(["ItemIds": ["a"]]))
        #expect(!missing.isPlayNow)
    }

    @Test("PlayNow matching is case-insensitive")
    func playNowCaseInsensitive() throws {
        let request = try #require(JellyfinSocket.parsePlay(["ItemIds": ["a"], "PlayCommand": "playnow"]))
        #expect(request.isPlayNow)
    }

    @Test("Parses a DisplayMessage general command")
    func parsesDisplayMessage() throws {
        let message = try #require(JellyfinSocket.parseDisplayMessage([
            "Name": "DisplayMessage",
            "Arguments": ["Header": "Cinemax", "Text": "Bonjour"]
        ]))
        #expect(message.header == "Cinemax")
        #expect(message.text == "Bonjour")
    }

    @Test("Ignores general commands the capability post never advertised")
    func ignoresUnadvertisedCommands() {
        // The app declares only DisplayMessage; anything else must be dropped
        // rather than surfaced as an empty toast.
        #expect(JellyfinSocket.parseDisplayMessage([
            "Name": "SetVolume",
            "Arguments": ["Volume": "50"]
        ]) == nil)
    }

    @Test("Drops a DisplayMessage with no usable text")
    func dropsEmptyDisplayMessage() {
        #expect(JellyfinSocket.parseDisplayMessage(["Name": "DisplayMessage"]) == nil)
        #expect(JellyfinSocket.parseDisplayMessage([
            "Name": "DisplayMessage",
            "Arguments": ["Text": "   "]
        ]) == nil)
    }

    @Test("A blank header collapses to nil rather than an empty toast title")
    func blankHeaderBecomesNil() throws {
        let message = try #require(JellyfinSocket.parseDisplayMessage([
            "Name": "DisplayMessage",
            "Arguments": ["Header": "  ", "Text": "Hello"]
        ]))
        #expect(message.header == nil)
        #expect(message.text == "Hello")
    }

    @Test("Parses every Playstate command the app honours")
    func parsesPlaystate() throws {
        for kind in RemotePlaystateCommand.Kind.allCases where kind != .seek {
            let command = try #require(JellyfinSocket.parsePlaystate(["Command": kind.rawValue]))
            #expect(command.kind == kind)
            #expect(command.seekPositionTicks == nil)
        }
        let seek = try #require(JellyfinSocket.parsePlaystate([
            "Command": "Seek",
            "SeekPositionTicks": NSNumber(value: 6_000_000_000),
            "ControllingUserId": "abc"
        ]))
        #expect(seek.kind == .seek)
        #expect(seek.seekPositionTicks == 6_000_000_000)
    }

    @Test("Playstate matching is case-insensitive")
    func playstateCaseInsensitive() throws {
        // jellyfin-web posts `stop` / `nextTrack` / `seek` in camel case.
        #expect(try #require(JellyfinSocket.parsePlaystate(["Command": "nexttrack"])).kind == .nextTrack)
        #expect(try #require(JellyfinSocket.parsePlaystate(["Command": "PLAYPAUSE"])).kind == .playPause)
    }

    @Test("A Playstate seek without a usable target is refused rather than sent to 0")
    func playstateSeekNeedsTarget() {
        #expect(JellyfinSocket.parsePlaystate(["Command": "Seek"]) == nil)
        #expect(JellyfinSocket.parsePlaystate([
            "Command": "Seek",
            "SeekPositionTicks": NSNumber(value: -1)
        ]) == nil)
    }

    @Test("Playstate commands the app does not execute are dropped at parse time")
    func unhonouredPlaystateDropped() {
        // Rewind / FastForward assume a rate-changing transport this app does
        // not have; an unknown future value must not be guessed at either.
        #expect(JellyfinSocket.parsePlaystate(["Command": "Rewind"]) == nil)
        #expect(JellyfinSocket.parsePlaystate(["Command": "FastForward"]) == nil)
        #expect(JellyfinSocket.parsePlaystate(["Command": "Teleport"]) == nil)
        #expect(JellyfinSocket.parsePlaystate([:]) == nil)
    }
}

/// The type-to-confirm phrase guarding `DestructiveConfirmSheet`.
///
/// The defect these lock: iOS's smart punctuation rewrites the apostrophe as
/// the user types it, so a raw `caseInsensitiveCompare` against the server's
/// own spelling of « L'Odyssée » could never match and the delete button stayed
/// disabled for ever — with no visible reason, the two apostrophe glyphs being
/// a few pixels apart. Every title carrying one was undeletable.
@Suite("Confirm phrase — type-to-confirm matching")
struct ConfirmPhraseTests {

    // MARK: - The reported defect

    @Test("A typographic apostrophe confirms a straight-quoted title")
    func smartQuoteMatchesStraightTitle() {
        // What the keyboard produced ↔ what Jellyfin stores.
        #expect(ConfirmPhrase.matches(typed: "L\u{2019}Odyssée", required: "L'Odyssée"))
    }

    @Test("And the reverse: a straight apostrophe confirms a typographic title")
    func straightQuoteMatchesSmartTitle() {
        // A provider that stores the typographic form is the same trap with the
        // sides swapped — the keyboard is not the only source of the mismatch.
        #expect(ConfirmPhrase.matches(typed: "L'Odyssée", required: "L\u{2019}Odyssée"))
    }

    @Test("A no-break space before a colon still confirms")
    func narrowNoBreakSpaceMatches() {
        // French metadata routinely carries U+202F / U+00A0 before a colon.
        // No keyboard produces either, so the plain space the user types has to
        // count.
        #expect(ConfirmPhrase.matches(
            typed: "Mission : Impossible",
            required: "Mission\u{202F}: Impossible"
        ))
        #expect(ConfirmPhrase.matches(
            typed: "Mission : Impossible",
            required: "Mission\u{00A0}: Impossible"
        ))
    }

    @Test("An en dash confirms against a typed hyphen")
    func dashFormsFold() {
        #expect(ConfirmPhrase.matches(typed: "Spider-Man", required: "Spider\u{2013}Man"))
    }

    // MARK: - The friction the sheet exists to create

    @Test("A different title never confirms")
    func differentTitleRefused() {
        #expect(!ConfirmPhrase.matches(typed: "L'Iliade", required: "L'Odyssée"))
        #expect(!ConfirmPhrase.matches(typed: "L'Odyss", required: "L'Odyssée"))
        #expect(!ConfirmPhrase.matches(typed: "L'Odyssée 2", required: "L'Odyssée"))
    }

    @Test("An empty field never confirms — including for an untitled item")
    func emptyNeverConfirms() {
        #expect(!ConfirmPhrase.matches(typed: "", required: "L'Odyssée"))
        #expect(!ConfirmPhrase.matches(typed: "   ", required: "L'Odyssée"))
        // The one outcome worse than refusing a legitimate delete: accepting an
        // untouched field as assent to an irreversible action.
        #expect(!ConfirmPhrase.matches(typed: "", required: ""))
        #expect(!ConfirmPhrase.matches(typed: "  ", required: "   "))
    }

    @Test("Case and surrounding whitespace are forgiven, the words are not")
    func caseAndTrimmingForgiven() {
        #expect(ConfirmPhrase.matches(typed: "  l'odyssée  ", required: "L'Odyssée"))
        #expect(ConfirmPhrase.matches(typed: "L'ODYSSÉE", required: "L'Odyssée"))
        // Collapsed, not deleted: the words still have to be separated.
        #expect(ConfirmPhrase.matches(typed: "Blade  Runner", required: "Blade Runner"))
        #expect(!ConfirmPhrase.matches(typed: "BladeRunner", required: "Blade Runner"))
    }

    @Test("Accents are forgiven; every other character still has to be typed")
    func diacriticsForgiven() {
        // A confirmation control, not an authentication one: an English
        // keyboard must not make a French title undeletable. Ten deliberate
        // characters still stand between a tap and a deletion.
        #expect(ConfirmPhrase.matches(typed: "L'Odyssee", required: "L'Odyssée"))
        #expect(!ConfirmPhrase.matches(typed: "L'Odysse", required: "L'Odyssée"))
    }

    // MARK: - normalize

    @Test("normalize folds punctuation and collapses whitespace runs")
    func normalizeFolds() {
        #expect(ConfirmPhrase.normalize("  L\u{2019}Odyssée  ") == "L'Odyssée")
        #expect(ConfirmPhrase.normalize("A\u{2014}B") == "A-B")
        #expect(ConfirmPhrase.normalize("a\t\n b") == "a b")
        #expect(ConfirmPhrase.normalize("   ").isEmpty)
        // Case and diacritics are `matches`'s business, not the fold's.
        #expect(ConfirmPhrase.normalize("Été") == "Été")
    }
}
