import Foundation
import Testing
import JellyfinAPI
@testable import CinemaxKit
@testable import Cinemax

private func policy(maxRating: Int? = nil, allDevices: Bool? = nil, sessions: Int? = nil) -> UserPolicy {
    var policy = UserPolicy(authenticationProviderID: "", passwordResetProviderID: "")
    policy.maxParentalRating = maxRating
    policy.enableAllDevices = allDevices
    policy.maxActiveSessions = sessions
    return policy
}

private let seerrURL = URL(string: "https://seerr.example.com")

@Suite("Seerr access")
struct SeerrAccessTests {

    @Test("a device age cap hides Seerr")
    func deviceCapHides() {
        #expect(SeerrAccess.isAgeCapped(deviceMaxAge: 12, policy: nil))
    }

    @Test("a server parental rating hides Seerr")
    func serverCapHides() {
        #expect(SeerrAccess.isAgeCapped(deviceMaxAge: 0, policy: policy(maxRating: 10)))
    }

    @Test("no cap anywhere is not capped")
    func uncapped() {
        #expect(!SeerrAccess.isAgeCapped(deviceMaxAge: 0, policy: nil))
        #expect(!SeerrAccess.isAgeCapped(deviceMaxAge: 0, policy: policy()))
    }

    @Test("browse needs Pro, no cap, an enabled config with an address, and the network")
    func browseNeedsEverything() {
        let good = SeerrUserConfig(isEnabled: true, url: seerrURL)
        func shows(pro: Bool = true, capped: Bool = false, config: SeerrUserConfig? = good, online: Bool = true) -> Bool {
            SeerrAccess.showsBrowse(proAllows: pro, ageCapped: capped, config: config, isOnline: online)
        }
        #expect(shows())
        #expect(!shows(pro: false))
        #expect(!shows(capped: true))
        #expect(!shows(config: SeerrUserConfig(isEnabled: false, url: seerrURL)))
        #expect(!shows(config: SeerrUserConfig(isEnabled: true, url: nil)))
        #expect(!shows(config: nil))
        #expect(!shows(online: false))
    }

    @Test("the settings category shows for an admin even when Seerr is disabled")
    func settingsForAdminEvenDisabled() {
        #expect(SeerrAccess.showsSettingsCategory(ageCapped: false, isAdmin: true, config: nil))
        #expect(SeerrAccess.showsSettingsCategory(ageCapped: false, isAdmin: false,
                                                  config: SeerrUserConfig(isEnabled: true, url: seerrURL)))
        #expect(!SeerrAccess.showsSettingsCategory(ageCapped: false, isAdmin: false,
                                                   config: SeerrUserConfig(isEnabled: false, url: nil)))
    }

    @Test("an age-capped account never sees the category, admin or not")
    func settingsHiddenWhenCapped() {
        #expect(!SeerrAccess.showsSettingsCategory(ageCapped: true, isAdmin: true, config: nil))
    }

    @Test("a refusal blames the device list first, then the session limit, else generic")
    func refusalPicksDeviceFirst() {
        #expect(SeerrAccess.refusalFailure(policy: policy(allDevices: false, sessions: 1)) == .jellyfinDevice)
        #expect(SeerrAccess.refusalFailure(policy: policy(allDevices: true, sessions: 1)) == .jellyfinSessions)
        #expect(SeerrAccess.refusalFailure(policy: policy(allDevices: true, sessions: 0)) == .jellyfinRefused)
        #expect(SeerrAccess.refusalFailure(policy: nil) == .jellyfinRefused)
    }

    @Test("every test failure has its own non-empty title and fix keys")
    func failureKeysAreDistinct() {
        let all: [SeerrTestFailure] = [
            .unreachable, .notSeerr, .redirected, .tooOld("3.0"), .notJellyfin, .otherJellyfin,
            .quickConnectOff, .jellyfinDevice, .jellyfinSessions, .jellyfinRefused, .keyRefused, .notInSeerr,
        ]
        let keys = all.flatMap { [$0.titleKey, $0.fixKey] }
        #expect(keys.allSatisfy { !$0.isEmpty })
        #expect(Set(keys).count == keys.count)
        #expect(SeerrTestFailure.tooOld("3.0").titleKey == "seerr.test.tooOld.title")
        #expect(SeerrTestFailure.tooOld("2.0").fixKey == "seerr.test.tooOld.fix")
    }

    /// The same reason gives the same message wherever a connection fails —
    /// the test, and « Se connecter à Seerr » in Settings.
    @Test("a failed sign-in reads as the connection test's failure")
    func signInFailureMapping() {
        #expect(SeerrAccess.signInFailure(.cancelled, policy: nil) == nil)
        #expect(SeerrAccess.signInFailure(.otherJellyfin, policy: nil) == .otherJellyfin)
        #expect(SeerrAccess.signInFailure(.jellyfinRefused, policy: policy(allDevices: false)) == .jellyfinDevice)
        #expect(SeerrAccess.signInFailure(.jellyfinRefused, policy: policy(allDevices: true, sessions: 2)) == .jellyfinSessions)
        #expect(SeerrAccess.signInFailure(.jellyfinRefused, policy: nil) == .jellyfinRefused)
        #expect(SeerrAccess.signInFailure(.notImported, policy: nil) == .notInSeerr)
        #expect(SeerrAccess.signInFailure(.timedOut, policy: nil) == .unreachable)
        #expect(SeerrAccess.signInFailure(.seerr(.unreachable), policy: nil) == .unreachable)
        #expect(SeerrAccess.signInFailure(.seerr(.redirected), policy: nil) == .redirected)
        #expect(SeerrAccess.signInFailure(.seerr(.notSeerr), policy: nil) == .notSeerr)
        #expect(SeerrAccess.signInFailure(.seerr(.forbidden), policy: nil) == .unreachable)
    }

    /// Every Seerr sentence the app can print exists in fr / en / de (the
    /// parity script only compares the languages with each other).
    @Test("every Seerr string exists in every language")
    func stringsExistInEveryLanguage() {
        let failures: [SeerrTestFailure] = [
            .unreachable, .notSeerr, .redirected, .tooOld("3.0"), .notJellyfin, .otherJellyfin,
            .quickConnectOff, .jellyfinDevice, .jellyfinSessions, .jellyfinRefused, .keyRefused, .notInSeerr,
        ]
        let fixed = [
            "settings.requests",
            "pro.feature.requests.title", "pro.feature.requests.detail", "pro.feature.requests.row",
            "seerr.test.ok.version", "seerr.test.ok.server", "seerr.test.ok.quickConnect", "seerr.test.ok.account",
            "seerr.test.ok.role.admin", "seerr.test.ok.role.autoApprove", "seerr.test.ok.role.manage",
            "seerr.test.ok.role.request", "seerr.test.warning.cannotManage",
            "seerr.activation.refused.capped", "seerr.activation.noAddress",
            "seerr.activation.failed.enable", "seerr.activation.failed.disable",
            "seerr.activation.summary.enabled", "seerr.activation.summary.refused", "seerr.activation.summary.failed",
            "seerr.activation.summary.disableFailed", "seerr.activation.summary.addressFailed",
            "seerr.settings.section.connection", "seerr.settings.section.configuration", "seerr.settings.section.device",
            "seerr.settings.connectedAs", "seerr.settings.deviceKeyProfile", "seerr.settings.signIn",
            "seerr.settings.signOut", "seerr.settings.connection.noAddress", "seerr.settings.connection.unavailable",
            "seerr.settings.address", "seerr.settings.address.placeholder", "seerr.settings.test",
            "seerr.settings.test.accountNote", "seerr.settings.whoCanRequest",
            "seerr.settings.line.ageCapped", "seerr.settings.line.linked", "seerr.settings.line.linkedAutoApprove",
            "seerr.settings.line.willBeCreated", "seerr.settings.line.mustBeAdded", "seerr.settings.line.unknown",
            "seerr.settings.enableAll", "seerr.settings.disableAll", "seerr.settings.disableAll.confirm",
            "seerr.settings.disableAll.done", "seerr.settings.footnote",
            "seerr.settings.key", "seerr.settings.key.explanation", "seerr.settings.key.save",
            "seerr.settings.key.saved", "seerr.settings.key.otherAddress", "seerr.settings.key.remove", "seerr.settings.key.savedToast",
            "seerr.settings.key.removedToast", "seerr.settings.unavailable",
        ]
        let keys = fixed + failures.flatMap { [$0.titleKey, $0.fixKey] }
            + fixed.filter { $0.hasPrefix("seerr.activation.summary.") }.map { $0 + ".one" }
        for language in AppLanguage.supported {
            let bundle = Bundle.localizedBundle(for: language)
            for key in keys {
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key, "\(language): \(key)")
            }
        }
    }
}
