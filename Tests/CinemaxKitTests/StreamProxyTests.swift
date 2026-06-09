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
}
