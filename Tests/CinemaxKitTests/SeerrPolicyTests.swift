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
}
