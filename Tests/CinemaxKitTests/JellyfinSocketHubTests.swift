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

    private var url: URL { URL(string: "ws://127.0.0.1:1/socket?ApiKey=t&deviceId=d")! }
    private var otherURL: URL { URL(string: "ws://127.0.0.1:2/socket?ApiKey=t&deviceId=d")! }

    @Test("Two consumers share one hub, and each is counted")
    func countsSubscribers() async {
        let hub = JellyfinSocketHub()
        let a = await hub.subscribe(url: url)
        #expect(await hub.subscriberCount == 1)
        let b = await hub.subscribe(url: url)
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
        let a = await hub.subscribe(url: url)
        await hub.unsubscribe(UUID())
        #expect(await hub.subscriberCount == 1)
        await hub.unsubscribe(a.id)
        await hub.unsubscribe(a.id)
        #expect(await hub.subscriberCount == 0)
    }

    @Test("A URL change rebuilds under the subscribers rather than dropping them")
    func urlChangeKeepsSubscribers() async {
        // A server switch or a re-login mints a new token, so the URL changes.
        // The consumers are still interested; only the connection is stale.
        let hub = JellyfinSocketHub()
        let a = await hub.subscribe(url: url)
        let b = await hub.subscribe(url: otherURL)
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
        let handle = await hub.subscribe(url: url)
        await hub.unsubscribe(handle.id)
        var delivered = 0
        for await _ in handle.messages { delivered += 1 }
        #expect(delivered == 0)
    }
}
