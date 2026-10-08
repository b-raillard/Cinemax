import Foundation
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

    @Test("iOS chains server → Quick Connect → iPhone Duo → personalize; tvOS skips the Duo page")
    func pageChain() {
        let ios = OnboardingPage.sequence(includesDuo: true)
        let tv = OnboardingPage.sequence(includesDuo: false)
        #expect(ios == [.server, .quickConnect, .duo, .personalize])
        #expect(tv == [.server, .quickConnect, .personalize])
        #expect(OnboardingPage.server.previous(in: ios) == nil)
        #expect(OnboardingPage.quickConnect.next(in: ios) == .duo)
        #expect(OnboardingPage.duo.next(in: ios) == .personalize)
        #expect(OnboardingPage.personalize.previous(in: ios) == .duo)
        #expect(OnboardingPage.quickConnect.next(in: tv) == .personalize)
        #expect(OnboardingPage.personalize.previous(in: tv) == .quickConnect)
        #expect(OnboardingPage.personalize.next(in: ios) == nil)
        #expect(OnboardingPage.personalize.next(in: tv) == nil)
    }

    @Test("the platform's own sequence: the Duo page exists on iOS only")
    func platformSequence() {
        #if os(tvOS)
        #expect(OnboardingPage.pages == [.server, .quickConnect, .personalize])
        #else
        #expect(OnboardingPage.pages == [.server, .quickConnect, .duo, .personalize])
        #endif
        #expect(OnboardingPage.personalize.isLast)
        #expect(!OnboardingPage.server.isLast)
    }

    @Test("the Duo page speaks to an iPhone Duo's owner; elsewhere it announces the support")
    func duoTextKey() {
        #expect(OnboardingPage.duo.textKey(onDuo: true) == "duo.onDuo")
        #expect(OnboardingPage.duo.textKey(onDuo: false) == "duo")
        #expect(OnboardingPage.server.textKey(onDuo: true) == "server")
        #expect(OnboardingPage.personalize.textKey(onDuo: false) == "personalize")
    }

    @Test("both Duo texts exist in every language")
    func duoStringsLocalized() {
        for code in AppLanguage.supported {
            let bundle = Bundle.localizedBundle(for: code)
            for key in ["onboarding.duo.title", "onboarding.duo.body", "onboarding.duo.onDuo.title", "onboarding.duo.onDuo.body"] {
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key, "\(code) \(key)")
            }
        }
    }

    @Test("tvOS Menu: back a page past the first; on the first, suspend at first run and dismiss the replay")
    func menuButton() {
        #expect(OnboardingExit.decide(page: .quickConnect, isReplay: false) == .previousPage)
        #expect(OnboardingExit.decide(page: .personalize, isReplay: true) == .previousPage)
        #expect(OnboardingExit.decide(page: .server, isReplay: false) == .systemDefault)
        #expect(OnboardingExit.decide(page: .server, isReplay: true) == .dismiss)
    }
}
