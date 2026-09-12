import Testing
@testable import Cinemax

/// Who ever sees the first-run onboarding. The whole feature rests on this
/// truth table: a wrong answer either hides the introduction from the one
/// person it exists for, or puts three pages in front of someone who has used
/// the app for a year.
@Suite("Onboarding policy")
struct OnboardingPolicyTests {

    @Test("a genuine first run — nothing registered, never seen — shows it")
    func firstRunShows() {
        #expect(OnboardingPolicy.shouldShow(
            seen: false, hasRegisteredServer: false, hasServer: false, isAddingServer: false
        ))
    }

    @Test("once seen, never again")
    func seenHides() {
        #expect(!OnboardingPolicy.shouldShow(
            seen: true, hasRegisteredServer: false, hasServer: false, isAddingServer: false
        ))
    }

    @Test("any registered server means an existing install — an upgrade, or a logout from the only server")
    func registeredServerHides() {
        #expect(!OnboardingPolicy.shouldShow(
            seen: false, hasRegisteredServer: true, hasServer: false, isAddingServer: false
        ))
    }

    @Test("a mirrored server (migration failed, legacy trio still there) hides it too")
    func legacyServerHides() {
        #expect(!OnboardingPolicy.shouldShow(
            seen: false, hasRegisteredServer: false, hasServer: true, isAddingServer: false
        ))
    }

    @Test("adding a server from Réglages never shows it, whatever else is true")
    func addingServerHides() {
        #expect(!OnboardingPolicy.shouldShow(
            seen: false, hasRegisteredServer: false, hasServer: false, isAddingServer: true
        ))
        #expect(!OnboardingPolicy.shouldShow(
            seen: false, hasRegisteredServer: true, hasServer: false, isAddingServer: true
        ))
    }

    @Test("a launch that finds a server latches the flag; a bare install does not")
    func stampOnLaunch() {
        #expect(OnboardingPolicy.shouldStampSeen(hasRegisteredServer: true, hasServer: false))
        #expect(OnboardingPolicy.shouldStampSeen(hasRegisteredServer: false, hasServer: true))
        #expect(!OnboardingPolicy.shouldStampSeen(hasRegisteredServer: false, hasServer: false))
    }

    @Test("pages chain server → Quick Connect → personalize, bounded at both ends")
    func pageChain() {
        #expect(OnboardingPage.allCases == [.server, .quickConnect, .personalize])
        #expect(OnboardingPage.server.previous == nil)
        #expect(OnboardingPage.server.next == .quickConnect)
        #expect(OnboardingPage.quickConnect.next == .personalize)
        #expect(OnboardingPage.personalize.next == nil)
        #expect(OnboardingPage.personalize.isLast)
        #expect(!OnboardingPage.server.isLast)
    }

    @Test("tvOS Menu: back a page past the first; on the first, suspend at first run and dismiss the replay")
    func menuButton() {
        #expect(OnboardingExit.decide(page: .quickConnect, isReplay: false) == .previousPage)
        #expect(OnboardingExit.decide(page: .personalize, isReplay: true) == .previousPage)
        #expect(OnboardingExit.decide(page: .server, isReplay: false) == .systemDefault)
        #expect(OnboardingExit.decide(page: .server, isReplay: true) == .dismiss)
    }
}
