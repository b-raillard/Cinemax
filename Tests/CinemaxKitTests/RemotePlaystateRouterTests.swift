import Testing
import Foundation
@testable import Cinemax
@testable import CinemaxKit

/// Locks the routing of an inbound `Playstate` command (#176): it reaches the
/// player on screen, a command after teardown is dropped, a stale teardown
/// cannot evict the player that replaced it, and a Watch Together group owns
/// the playhead.
@MainActor
@Suite("Remote Playstate routing")
struct RemotePlaystateRouterTests {

    @Test("A command reaches the registered player")
    func routesToPlayer() {
        let router = RemotePlaystateRouter()
        var received: [RemotePlaystateCommand] = []
        _ = router.register { received.append($0); return true }
        let outcome = router.route(RemotePlaystateCommand(kind: .pause), inSyncPlayGroup: false)
        #expect(outcome == .applied)
        #expect(received == [RemotePlaystateCommand(kind: .pause)])
    }

    @Test("With no player on screen the command is dropped")
    func noPlayer() {
        let router = RemotePlaystateRouter()
        #expect(!router.hasActivePlayer)
        #expect(router.route(RemotePlaystateCommand(kind: .pause), inSyncPlayGroup: false) == .noPlayer)
    }

    @Test("A command after teardown is dropped")
    func afterTeardown() {
        let router = RemotePlaystateRouter()
        var calls = 0
        let token = router.register { _ in calls += 1; return true }
        router.unregister(token)
        #expect(router.route(RemotePlaystateCommand(kind: .unpause), inSyncPlayGroup: false) == .noPlayer)
        #expect(calls == 0)
    }

    @Test("A stale teardown cannot unregister the player that replaced it")
    func staleUnregister() {
        let router = RemotePlaystateRouter()
        var first = 0, second = 0
        let old = router.register { _ in first += 1; return true }
        _ = router.register { _ in second += 1; return true }
        // The outgoing player's teardown lands after the new one registered.
        router.unregister(old)
        #expect(router.route(RemotePlaystateCommand(kind: .stop), inSyncPlayGroup: false) == .applied)
        #expect(first == 0)
        #expect(second == 1)
    }

    @Test("Unregistering token 0 is a no-op")
    func zeroTokenIgnored() {
        let router = RemotePlaystateRouter()
        _ = router.register { _ in true }
        router.unregister(0)
        #expect(router.hasActivePlayer)
    }

    @Test("A Watch Together group owns the playhead: Playstate is ignored")
    func ignoredInGroup() {
        let router = RemotePlaystateRouter()
        var calls = 0
        _ = router.register { _ in calls += 1; return true }
        let seek = RemotePlaystateCommand(kind: .seek, seekPositionTicks: 10_000_000)
        #expect(router.route(seek, inSyncPlayGroup: true) == .ignoredSyncPlay)
        #expect(calls == 0)
    }

    @Test("A player that cannot act reports it")
    func notApplicable() {
        let router = RemotePlaystateRouter()
        _ = router.register { _ in false }
        #expect(router.route(RemotePlaystateCommand(kind: .nextTrack), inSyncPlayGroup: false) == .notApplicable)
    }
}
