import Testing
import Foundation
@testable import CinemaxKit

/// Locks the reference counting that enforces **one socket per session**.
///
/// Jellyfin keys a session on device + client + user, so two concurrent
/// `/socket` connections from this app are the same session server-side and
/// every message arrives twice. Remote control and Watch Together are
/// independent consumers of the same connection, so the count is the whole
/// contract: the socket lives exactly as long as somebody is listening.
///
/// The URLs here are unreachable on purpose — `JellyfinSocket` retries a failed
/// connection with backoff and never surfaces the failure, so subscribing costs
/// nothing observable and the bookkeeping is what these assertions read.
@Suite("Realtime socket hub reference counting")
struct JellyfinSocketHubTests {

    private var url: RealtimeSocketEndpoint { endpoint("ws://127.0.0.1:1/socket?deviceId=d") }
    private var otherURL: RealtimeSocketEndpoint { endpoint("ws://127.0.0.1:2/socket?deviceId=d") }

    private func endpoint(_ url: String, token: String = "t") -> RealtimeSocketEndpoint {
        RealtimeSocketEndpoint(url: URL(string: url)!, token: token, authorization: "MediaBrowser Token=\(token)")
    }

    @Test("Two consumers share one hub, and each is counted")
    func countsSubscribers() async {
        let hub = JellyfinSocketHub()
        let a = await hub.subscribe(endpoint: url)
        #expect(await hub.subscriberCount == 1)
        let b = await hub.subscribe(endpoint: url)
        #expect(await hub.subscriberCount == 2)

        // Watch Together leaving must NOT take remote control's socket with it.
        await hub.unsubscribe(b.id)
        #expect(await hub.subscriberCount == 1)
        await hub.unsubscribe(a.id)
        #expect(await hub.subscriberCount == 0)
    }

    @Test("Unsubscribing an unknown handle is a no-op, not a miscount")
    func unknownHandleIgnored() async {
        // The orphan-subscription bug this guards against ended with a handle
        // being released twice and another never at all.
        let hub = JellyfinSocketHub()
        let a = await hub.subscribe(endpoint: url)
        await hub.unsubscribe(UUID())
        #expect(await hub.subscriberCount == 1)
        await hub.unsubscribe(a.id)
        await hub.unsubscribe(a.id)
        #expect(await hub.subscriberCount == 0)
    }

    @Test("An endpoint change rebuilds under the subscribers rather than dropping them")
    func urlChangeKeepsSubscribers() async {
        // A server switch or a re-login mints a new token, so the endpoint changes.
        // The consumers are still interested; only the connection is stale.
        let hub = JellyfinSocketHub()
        let a = await hub.subscribe(endpoint: url)
        let b = await hub.subscribe(endpoint: otherURL)
        #expect(await hub.subscriberCount == 2)
        await hub.unsubscribe(a.id)
        await hub.unsubscribe(b.id)
        #expect(await hub.subscriberCount == 0)
    }

    @Test("A subscriber's stream finishes when it unsubscribes")
    func streamFinishes() async {
        // Without this the consumer's `for await` loop never returns and the
        // task outlives the session it belonged to.
        let hub = JellyfinSocketHub()
        let handle = await hub.subscribe(endpoint: url)
        await hub.unsubscribe(handle.id)
        var delivered = 0
        for await _ in handle.messages { delivered += 1 }
        #expect(delivered == 0)
    }

    // MARK: - Identité et authentification (audit 2026-09-22, S7)

    @Test("Same socket URL and token = same connection; a new token or host is another")
    func explicitIdentity() {
        let a = endpoint("wss://nas.local/jf/socket?deviceId=d", token: "t1")
        #expect(a.isSameConnection(as: endpoint("wss://nas.local/jf/socket?deviceId=d", token: "t1")))
        #expect(!a.isSameConnection(as: endpoint("wss://nas.local/jf/socket?deviceId=d", token: "t2")), "re-login / user switch")
        #expect(!a.isSameConnection(as: endpoint("wss://other.local/jf/socket?deviceId=d", token: "t1")), "server switch")
    }

    @Test("The upgrade carries the token in the header, and in the URL only as a fallback")
    func headerThenQuery() {
        let e = endpoint("wss://nas.local/socket?deviceId=d", token: "secret")
        let header = e.request(queryAuth: false)
        #expect(header.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=secret")
        #expect(header.url?.absoluteString.contains("secret") == false)
        let query = e.request(queryAuth: true)
        #expect(query.url?.absoluteString == "wss://nas.local/socket?deviceId=d&ApiKey=secret")
        #expect(query.value(forHTTPHeaderField: "Authorization") != nil)
    }

    @Test("Fallback to ApiKey: on 401/403, or after repeated silent failures, never once the header worked")
    func fallbackDecision() {
        #expect(RealtimeSocketAuth.shouldFallBackToQuery(usingQuery: false, headerEverWorked: false, statusCode: 401, failedHeaderAttempts: 1))
        #expect(RealtimeSocketAuth.shouldFallBackToQuery(usingQuery: false, headerEverWorked: false, statusCode: 403, failedHeaderAttempts: 1))
        #expect(!RealtimeSocketAuth.shouldFallBackToQuery(usingQuery: false, headerEverWorked: false, statusCode: nil, failedHeaderAttempts: 1))
        #expect(RealtimeSocketAuth.shouldFallBackToQuery(usingQuery: false, headerEverWorked: false, statusCode: nil, failedHeaderAttempts: 2))
        #expect(!RealtimeSocketAuth.shouldFallBackToQuery(usingQuery: false, headerEverWorked: true, statusCode: 401, failedHeaderAttempts: 5))
        #expect(!RealtimeSocketAuth.shouldFallBackToQuery(usingQuery: true, headerEverWorked: false, statusCode: 401, failedHeaderAttempts: 5))
    }
}
