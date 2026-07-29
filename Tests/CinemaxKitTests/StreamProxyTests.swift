import Testing
import Foundation
@testable import Cinemax

/// `CinemaxStreamProxy` brings its loopback `NWListener` up asynchronously, so
/// `localURL(for:token:)` returns nil until the listener reports `.ready`.
/// These tests use a bounded retry loop (no fixed sleeps) and only assert
/// deterministic behavior: URL shape, per-registration uniqueness, and the
/// `stop()` → nil → restart cycle. No actual HTTP traffic is exercised — the
/// forwarding path needs a live origin and belongs to integration testing.
@Suite("CinemaxStreamProxy", .serialized)
struct StreamProxyTests {

    private static let target = URL(string: "https://example.org/Videos/abc/stream?static=true&api_key=tok")!

    /// Polls `localURL` until the listener is ready, bounded at `timeout`.
    private func waitForLocalURL(
        _ proxy: CinemaxStreamProxy,
        timeout: Duration = .seconds(3)
    ) async -> URL? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let url = proxy.localURL(for: Self.target, token: "tok") { return url }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return proxy.localURL(for: Self.target, token: "tok")
    }

    @Test("registrations return distinct unguessable /s/<uuid>/<name> loopback URLs")
    func distinctUnguessableURLs() async throws {
        let proxy = CinemaxStreamProxy()
        proxy.prestart()
        defer { proxy.stop() }

        let url1 = try #require(await waitForLocalURL(proxy))
        // Listener is up now — a second registration resolves synchronously.
        let url2 = try #require(proxy.localURL(for: Self.target, token: nil))

        for url in [url1, url2] {
            #expect(url.scheme == "http")
            #expect(url.host == "127.0.0.1")
            #expect(url.port != nil)
            #expect(url.path.hasPrefix("/s/"))
            // The target's own name and query are PRESERVED — that is what lets
            // libVLC resolve a playlist's relative children against this URL.
            #expect(url.lastPathComponent == "stream")
            #expect(url.query == "static=true&api_key=tok")
        }

        // Path ids must be unguessable UUIDs (not small sequential integers)
        // and unique per registration so a retry/episode swap can never read
        // the wrong stream. The id is the component AFTER `/s/`, not the last
        // one — the last one is now the media's own name.
        let id1 = try #require(CinemaxStreamProxy.route(path: url1.path)?.id)
        let id2 = try #require(CinemaxStreamProxy.route(path: url2.path)?.id)
        #expect(UUID(uuidString: id1) != nil)
        #expect(UUID(uuidString: id2) != nil)
        #expect(id1 != id2)
    }

    @Test("stop() drops the listener: localURL returns nil, then recovers after restart")
    func stopThenRestart() async throws {
        let proxy = CinemaxStreamProxy()
        proxy.prestart()
        defer { proxy.stop() }

        _ = try #require(await waitForLocalURL(proxy))

        proxy.stop()

        // stop() clears the cached port synchronously, so the very next call
        // must return nil. (It also kicks an async listener restart — same
        // warm-for-next-time behavior production relies on.)
        #expect(proxy.localURL(for: Self.target, token: nil) == nil)

        // Bounded wait until the relaunched listener is ready again.
        let revived = try #require(await waitForLocalURL(proxy))
        #expect(revived.host == "127.0.0.1")
        #expect(revived.path.hasPrefix("/s/"))
    }

    // MARK: - Origin directory mapping (pure)

    @Test("an HLS tree round-trips: master, the variant VLC resolves from it, and a segment")
    func hlsTreeRoundTrips() throws {
        // The exact shape Jellyfin hands back for a forced AVI/XviD transcode.
        let master = URL(string: """
            https://movies.example.net/videos/e3415c16-9ad9-d61c-2928-c50a32900511/master.m3u8\
            ?MediaSourceId=e3415c169ad9d61c2928c50a32900511&VideoCodec=hevc,h264&api_key=tok
            """)!
        let (origin, name) = try #require(OriginDirectory.split(master))
        #expect(name == "master.m3u8")
        #expect(origin.encodedDirectory == "/videos/e3415c16-9ad9-d61c-2928-c50a32900511")

        // libVLC resolves the master's relative children against the loopback
        // URL, so they arrive as /s/<id>/<child>. Each must map back onto the
        // SAME origin directory — that is the whole fix.
        let variant = try #require(CinemaxStreamProxy.route(path: "/s/ID/main.m3u8?PlaySessionId=abc"))
        #expect(variant.id == "ID")
        #expect(variant.rest == "main.m3u8")
        #expect(try #require(origin.url(forRest: variant.rest, encodedQuery: variant.query)).absoluteString
            == "https://movies.example.net/videos/e3415c16-9ad9-d61c-2928-c50a32900511/main.m3u8?PlaySessionId=abc")

        // Segments sit several components deep — `rest` must keep its slashes.
        let segment = try #require(CinemaxStreamProxy.route(path: "/s/ID/hls1/main/0.mp4?runtimeTicks=0"))
        #expect(segment.rest == "hls1/main/0.mp4")
        #expect(try #require(origin.url(forRest: segment.rest, encodedQuery: segment.query)).absoluteString
            == "https://movies.example.net/videos/e3415c16-9ad9-d61c-2928-c50a32900511/hls1/main/0.mp4?runtimeTicks=0")
    }

    @Test("a sub-path-hosted server keeps its base path through the mapping")
    func subPathServerPreserved() throws {
        // Dropping `/jellyfin` would 404 every proxied request — the base-path
        // rule applies here as everywhere.
        let target = URL(string: "https://host.example/jellyfin/Videos/abc/stream?static=true")!
        let (origin, name) = try #require(OriginDirectory.split(target))
        #expect(name == "stream")
        #expect(origin.encodedDirectory == "/jellyfin/Videos/abc")
        let route = try #require(CinemaxStreamProxy.route(path: "/s/ID/stream?static=true"))
        #expect(try #require(origin.url(forRest: route.rest, encodedQuery: route.query)).absoluteString
            == "https://host.example/jellyfin/Videos/abc/stream?static=true")
    }

    @Test("path traversal out of the registered directory is refused, encoded or not")
    func traversalRefused() {
        // `rest` is fetched from the origin WITH the account's token attached,
        // so climbing out of the directory would read arbitrary origin paths as
        // the user. Percent-encoded dot-segments must not slip through either.
        for path in [
            "/s/ID/../../Users/Me",
            "/s/ID/hls1/../../../System/Info",
            "/s/ID/%2e%2e/Users/Me",           // percent-encoded dot-segment
            "/s/ID/%2E%2E%2Fsecret",           // ONE component that decodes to `../secret`
            "/s/ID/hls1/%2e%2E%2fmain",        // mixed case, encoded separator
            "/s/ID/./main.m3u8",
        ] {
            #expect(CinemaxStreamProxy.route(path: path) == nil, "\(path) must not route")
        }
        // A name that merely CONTAINS dots is legitimate and must still route.
        #expect(CinemaxStreamProxy.route(path: "/s/ID/..foo.mp4") != nil)
        #expect(CinemaxStreamProxy.route(path: "/s/ID/main..m3u8") != nil)
    }

    @Test("malformed loopback paths route nowhere instead of guessing")
    func malformedPathsRefused() {
        for path in [
            "/s/ID",          // no name to re-attach — the OLD form, now invalid
            "/s/",
            "/s",
            "/",
            "/other/ID/x",
            "/s//main.m3u8",  // empty id
            "/s/ID//x",       // empty component
        ] {
            #expect(CinemaxStreamProxy.route(path: path) == nil, "\(path) must not route")
        }
    }

    @Test("a query-less request routes with a nil query rather than an empty one")
    func queryLessRouting() throws {
        let route = try #require(CinemaxStreamProxy.route(path: "/s/ID/stream"))
        #expect(route.query == nil)
        let origin = try #require(OriginDirectory.split(URL(string: "https://h.example/a/b/stream")!)).origin
        #expect(try #require(origin.url(forRest: route.rest, encodedQuery: route.query)).absoluteString
            == "https://h.example/a/b/stream")
    }

    // MARK: - Transport policy

    @Test("an unresolvable host pins the session to the proxy; a resolvable one doesn't")
    func resolverDrivesProxyPreference() {
        // This is the signal the corporate-Wi-Fi failure reduces to: libVLC only
        // has the BSD resolver, so when it can't answer, the proxy is the only
        // path — and we must know that BEFORE the first open, not after a failed
        // one plus a retry.
        #expect(StreamTransportPolicy.hostResolvesForLibVLC("localhost"))
        #expect(StreamTransportPolicy.hostResolvesForLibVLC("cinemax-does-not-exist.invalid") == false)
    }

    // MARK: - Request admission (pure)

    @Test("a normal loopback GET with a ported Host is accepted")
    func normalGETAccepted() {
        #expect(CinemaxStreamProxy.admission(
            method: "GET", path: "/s/\(UUID().uuidString)", hostHeader: " 127.0.0.1:52341"
        ) == .accept)
        // libVLC doesn't always send a Host header — that stays allowed.
        #expect(CinemaxStreamProxy.admission(
            method: "GET", path: "/s/abc", hostHeader: nil
        ) == .accept)
        // HEAD is a legitimate probe for content length.
        #expect(CinemaxStreamProxy.admission(
            method: "HEAD", path: "/s/abc", hostHeader: "localhost:52341"
        ) == .accept)
        #expect(CinemaxStreamProxy.admission(
            method: "GET", path: "/s/abc", hostHeader: "[::1]:52341"
        ) == .accept)
    }

    @Test("DNS-rebinding style Host headers are rejected, not prefix-matched")
    func rebindingHostRejected() {
        // These are exactly the hosts a `hasPrefix("127.")` / `hasPrefix("localhost")`
        // check waves through — the bug this validation exists to stop.
        for host in ["localhost.evil.com", "127.evil.com", "127.0.0.1.evil.com",
                     "evil.com", "[::1].evil.com", "localhost.evil.com:52341"] {
            #expect(
                CinemaxStreamProxy.admission(method: "GET", path: "/s/abc", hostHeader: host)
                    == .reject(status: "400 Bad Request"),
                "host \(host) must be rejected"
            )
            #expect(!CinemaxStreamProxy.isLoopbackHost(host))
        }

        // Precedence pin: the HOST check runs before the method check, so a
        // rebinding probe that also uses a disallowed method is answered 400
        // (bad host) — never 405, which would confirm to the caller that the
        // host was accepted and only the verb was wrong.
        #expect(
            CinemaxStreamProxy.admission(method: "POST", path: "/s/abc", hostHeader: "localhost.evil.com")
                == .reject(status: "400 Bad Request")
        )

        // A Host header that is PRESENT but empty/whitespace is malformed and
        // rejected — only a genuinely ABSENT Host (nil) is waved through.
        for empty in ["", " ", "\t "] {
            #expect(
                CinemaxStreamProxy.admission(method: "GET", path: "/s/abc", hostHeader: empty)
                    == .reject(status: "400 Bad Request"),
                "empty host \(empty.debugDescription) must be rejected"
            )
        }
    }

    @Test("only GET/HEAD are forwarded upstream — writes get 405")
    func nonReadMethodsRejected() {
        for method in ["POST", "PUT", "DELETE", "PATCH", "OPTIONS", "CONNECT"] {
            #expect(
                CinemaxStreamProxy.admission(method: method, path: "/s/abc", hostHeader: "127.0.0.1:1")
                    == .reject(status: "405 Method Not Allowed"),
                "method \(method) must be rejected"
            )
        }
        // Case-insensitive on the method name.
        #expect(CinemaxStreamProxy.admission(
            method: "get", path: "/s/abc", hostHeader: "127.0.0.1"
        ) == .accept)
    }

    @Test("paths outside /s/ are rejected before anything else")
    func nonStreamPathsRejected() {
        for path in ["/", "/admin", "/s", "//s/abc", "/S/abc"] {
            #expect(
                CinemaxStreamProxy.admission(method: "GET", path: path, hostHeader: "127.0.0.1")
                    == .reject(status: "400 Bad Request"),
                "path \(path) must be rejected"
            )
        }
    }

    @Test("loopback host matching accepts only the exact loopback names")
    func loopbackHostMatching() {
        for host in ["127.0.0.1", "127.0.0.1:8080", "LOCALHOST", "localhost:1",
                     "::1", "[::1]", "[::1]:9", " 127.0.0.1 "] {
            #expect(CinemaxStreamProxy.isLoopbackHost(host), "\(host) should be loopback")
        }
        for host in ["", "127.0.0.2", "0.0.0.0", "192.168.1.10", "127.0.0.1:",
                     "127.0.0.1:port", "[::1", "[::2]", "example.com"] {
            #expect(!CinemaxStreamProxy.isLoopbackHost(host), "\(host) should NOT be loopback")
        }
    }
}
