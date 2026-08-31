import Testing
import Foundation
@testable import Cinemax

/// The tvOS Menu button's rule, locked away from its single call site.
///
/// The behaviour it encodes was reported as a bug: on a page whose content runs
/// out of focusable rows (an actor's page), an Up press escapes into the top tab
/// bar, and tvOS's default Menu behaviour from there is to QUIT the app instead
/// of going back.
@Suite("tvOS back policy")
struct TVBackPolicyTests {

    @Test("something stacked in this tab wins over everything else")
    func backFirst() {
        // Even on the fallback tab itself: a pushed screen must pop, never
        // suspend the app.
        #expect(TVBackPolicy.decide(tabID: "home", hasBack: true, homeTabID: "home") == .goBack)
        #expect(TVBackPolicy.decide(tabID: "movies", hasBack: true, homeTabID: "home") == .goBack)
    }

    @Test("a main page other than Accueil falls back to Accueil")
    func nonHomeRootGoesHome() {
        #expect(
            TVBackPolicy.decide(tabID: "movies", hasBack: false, homeTabID: "home")
                == .switchTab("home")
        )
        #expect(
            TVBackPolicy.decide(tabID: "settings", hasBack: false, homeTabID: "home")
                == .switchTab("home")
        )
    }

    @Test("Accueil itself suspends the app")
    func homeRootSuspends() {
        // `.suspend` means "install no handler": passing nil to
        // `onExitCommand` is the only way to get the system's own behaviour,
        // since `UIApplication.suspend()` is private.
        #expect(TVBackPolicy.decide(tabID: "home", hasBack: false, homeTabID: "home") == .suspend)
    }

    @Test("a custom menu with no Accueil falls back to its first tab")
    func customMenuUsesFirstTab() {
        // `MenuConfigStore` lets the user drop the Home tab entirely. The Menu
        // button still needs one screen it converges on before giving up.
        #expect(
            TVBackPolicy.decide(tabID: "lib:2", hasBack: false, homeTabID: "lib:1")
                == .switchTab("lib:1")
        )
        #expect(TVBackPolicy.decide(tabID: "lib:1", hasBack: false, homeTabID: "lib:1") == .suspend)
    }

    @Test("no tabs at all never switches to a tab that doesn't exist")
    func noTabs() {
        #expect(TVBackPolicy.decide(tabID: "home", hasBack: false, homeTabID: nil) == .suspend)
    }
}

@MainActor
@Suite("tvOS back coordinator")
struct TVBackCoordinatorTests {

    @Test("a tab with nothing registered has nothing to go back to")
    func emptyByDefault() {
        let coordinator = TVBackCoordinator()
        #expect(!coordinator.canGoBack(in: "home"))
    }

    @Test("registration is scoped to its own tab")
    func perTabScoping() {
        // The whole point: Menu on Films must never pop something on Accueil.
        let coordinator = TVBackCoordinator()
        coordinator.register(UUID(), tabID: "movies", action: {})
        #expect(coordinator.canGoBack(in: "movies"))
        #expect(!coordinator.canGoBack(in: "home"))
    }

    @Test("an empty tab id is refused rather than parked under a bogus key")
    func emptyTabIDRefused() {
        // Views outside a tab's own stack (the root-hosted deep-link cover, and
        // every pushed screen on iOS) see no tab id. Registering them would
        // only create an entry nothing can ever clear.
        let coordinator = TVBackCoordinator()
        coordinator.register(UUID(), tabID: "", action: {})
        #expect(!coordinator.canGoBack(in: ""))
    }

    @Test("going back runs the innermost registered action")
    func innermostWins() {
        let coordinator = TVBackCoordinator()
        var fired: [String] = []
        coordinator.register(UUID(), tabID: "home", action: { fired.append("outer") })
        coordinator.register(UUID(), tabID: "home", action: { fired.append("inner") })

        coordinator.goBack(in: "home")

        #expect(fired == ["inner"])
    }

    @Test("SwiftUI's push order — inner appears, then outer disappears — keeps the top entry")
    func pushOrderKeepsTopEntry() {
        // Measured on the probe: pushing B fires `B.onAppear` BEFORE
        // `A.onDisappear`, so the two overlap for a moment and the array must
        // survive the outer one leaving without losing the inner one.
        let coordinator = TVBackCoordinator()
        let outer = UUID()
        let inner = UUID()
        var fired: [String] = []
        coordinator.register(outer, tabID: "home", action: { fired.append("outer") })
        coordinator.register(inner, tabID: "home", action: { fired.append("inner") })
        coordinator.unregister(outer, tabID: "home")

        #expect(coordinator.canGoBack(in: "home"))
        coordinator.goBack(in: "home")
        #expect(fired == ["inner"])
    }

    @Test("unregistering the last entry empties the tab")
    func unregisterEmpties() {
        let coordinator = TVBackCoordinator()
        let id = UUID()
        coordinator.register(id, tabID: "home", action: {})
        coordinator.unregister(id, tabID: "home")
        #expect(!coordinator.canGoBack(in: "home"))
    }

    @Test("re-registering the same screen doesn't stack a duplicate")
    func idempotentRegistration() {
        // A tab round-trip re-fires `onAppear` on the screen still pushed there.
        let coordinator = TVBackCoordinator()
        let id = UUID()
        var count = 0
        coordinator.register(id, tabID: "home", action: { count += 1 })
        coordinator.register(id, tabID: "home", action: { count += 1 })

        coordinator.goBack(in: "home")
        #expect(count == 1)

        coordinator.unregister(id, tabID: "home")
        #expect(!coordinator.canGoBack(in: "home"))
    }

    @Test("the tab root clears a stale entry, and only its own tab's")
    func rootClearsStaleEntries() {
        // Self-heal: a screen torn down without its `onDisappear` (pushed
        // inside a modal that was dismissed wholesale) would otherwise leave
        // Menu doing nothing at all on that tab root.
        let coordinator = TVBackCoordinator()
        coordinator.register(UUID(), tabID: "home", action: {})
        coordinator.register(UUID(), tabID: "movies", action: {})

        coordinator.clear(tabID: "home")

        #expect(!coordinator.canGoBack(in: "home"))
        #expect(coordinator.canGoBack(in: "movies"))
    }

    @Test("going back on a tab with nothing registered does nothing")
    func goBackNoOp() {
        let coordinator = TVBackCoordinator()
        var fired = false
        coordinator.register(UUID(), tabID: "movies", action: { fired = true })
        coordinator.goBack(in: "home")
        #expect(!fired)
    }
}
