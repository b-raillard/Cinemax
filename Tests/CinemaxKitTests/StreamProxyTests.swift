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
