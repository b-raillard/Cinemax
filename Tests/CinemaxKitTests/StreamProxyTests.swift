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

    @Test("registrations return distinct unguessable /s/<uuid> loopback URLs")
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
        }

        // Path ids must be unguessable UUIDs (not small sequential integers)
        // and unique per registration so a retry/episode swap can never read
        // the wrong stream.
        let id1 = url1.lastPathComponent
        let id2 = url2.lastPathComponent
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

    // MARK: - Playback network diagnostics (temporary probe)

    @Test("the diagnostic resolver reports loopback correctly (C interop sanity)")
    func diagnosticResolverHandlesLoopback() {
        // Not a network test — `localhost` resolves from /etc/hosts. It exists to
        // catch a getaddrinfo/getnameinfo pointer bug BEFORE the probe is carried
        // onto the one network where it has to produce a usable reading.
        let (rc, addresses) = PlaybackNetworkDiagnostics.resolve(host: "localhost")
        #expect(rc == 0)
        #expect(!addresses.isEmpty)
        // Every entry is family-tagged, and loopback resolves to a loopback literal.
        #expect(addresses.allSatisfy { $0.hasPrefix("v4:") || $0.hasPrefix("v6:") })
        #expect(addresses.contains { $0 == "v4:127.0.0.1" || $0 == "v6:::1" })
    }

    @Test("the diagnostic resolver reports failure instead of inventing addresses")
    func diagnosticResolverReportsFailure() {
        let (rc, addresses) = PlaybackNetworkDiagnostics.resolve(
            host: "cinemax-does-not-exist.invalid" // .invalid is reserved, never resolves
        )
        #expect(rc != 0)
        #expect(addresses.isEmpty)
    }

    // MARK: - Servable streams (pure)

    @Test("HLS/DASH manifests are refused — the single-target proxy can't serve a URL tree")
    func manifestsAreNotServable() {
        // The exact shape Jellyfin hands back for a forced transcode (AVI/XviD
        // and friends). Proxying it made libVLC resolve the master's relative
        // children against `http://127.0.0.1:<port>/s/<id>`, hitting an unknown
        // id (502) — the "Failed to create demuxer 0x0 Unknown" freeze.
        let hlsMaster = URL(string: """
            https://movies.example.net/videos/e3415c16-9ad9-d61c-2928-c50a32900511/master.m3u8\
            ?MediaSourceId=e3415c169ad9d61c2928c50a32900511&VideoCodec=hevc,h264&api_key=tok
            """)!
        #expect(CinemaxStreamProxy.canServe(hlsMaster) == false)
        // Sub-playlist, uppercase extension, and DASH fail for the same reason.
        for raw in [
            "https://example.org/videos/abc/main.m3u8?api_key=tok",
            "https://example.org/videos/abc/MASTER.M3U8",
            "https://example.org/videos/abc/playlist.m3u",
            "https://example.org/videos/abc/manifest.mpd?api_key=tok",
        ] {
            #expect(CinemaxStreamProxy.canServe(URL(string: raw)!) == false, "\(raw) must not be proxied")
        }
    }

    @Test("single-file streams stay servable — the proxy's whole purpose")
    func singleFileStreamsAreServable() {
        for raw in [
            // Direct stream: the seek-heavy-container case the proxy exists for.
            "https://example.org/Videos/abc/stream?static=true&api_key=tok",
            // Jellyfin's *progressive* transcode is one file, not a tree.
            "https://example.org/videos/abc/stream.mp4?api_key=tok",
            "https://example.org/videos/abc/file.mkv",
            // No extension at all must not be mistaken for a manifest.
            "https://example.org/Videos/abc/stream",
        ] {
            #expect(CinemaxStreamProxy.canServe(URL(string: raw)!), "\(raw) must stay proxyable")
        }
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
