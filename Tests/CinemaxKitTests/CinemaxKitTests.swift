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
