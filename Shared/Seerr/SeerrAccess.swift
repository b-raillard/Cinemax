import Foundation
import JellyfinAPI
import CinemaxKit

/// Who sees what of Seerr. Pure: every input is passed in, so view models and
/// views can call it from anywhere.
enum SeerrAccess {
    /// An account capped by age — on this device (`privacy.maxContentAge`) or by
    /// the server (`policy.maxParentalRating`) — gets nothing from Seerr.
    nonisolated static func isAgeCapped(deviceMaxAge: Int, policy: UserPolicy?) -> Bool {
        deviceMaxAge > 0 || policy?.maxParentalRating != nil
    }

    /// The browse surfaces (search section, Home rail): needs Pro, no cap, an
    /// enabled configuration with an address, and the network.
    nonisolated static func showsBrowse(
        proAllows: Bool, ageCapped: Bool, config: SeerrUserConfig?, isOnline: Bool
    ) -> Bool {
        guard proAllows, !ageCapped, isOnline, let config else { return false }
        return config.isEnabled && config.url != nil
    }

    /// The Settings category: an admin always (to set it up), anyone else only
    /// once Seerr is enabled for them; never for a capped account.
    nonisolated static func showsSettingsCategory(
        ageCapped: Bool, isAdmin: Bool, config: SeerrUserConfig?
    ) -> Bool {
        !ageCapped && (isAdmin || config?.isEnabled == true)
    }

    /// Why Jellyfin refused the account Seerr tried to sign in with: the device
    /// list first, then the active-session limit, else a generic refusal.
    nonisolated static func refusalFailure(policy: UserPolicy?) -> SeerrTestFailure {
        if policy?.enableAllDevices == false { return .jellyfinDevice }
        if (policy?.maxActiveSessions ?? 0) > 0 { return .jellyfinSessions }
        return .jellyfinRefused
    }
}

/// Why a Seerr connection failed. One enum so the connection test and every
/// « Se connecter à Seerr » entry show the same message for the same reason.
enum SeerrTestFailure: Equatable, Sendable {
    case unreachable, notSeerr, redirected, tooOld(String), notJellyfin, otherJellyfin
    case quickConnectOff, jellyfinDevice, jellyfinSessions, jellyfinRefused, keyRefused, notInSeerr

    private nonisolated var caseName: String {
        switch self {
        case .unreachable: "unreachable"
        case .notSeerr: "notSeerr"
        case .redirected: "redirected"
        case .tooOld: "tooOld"
        case .notJellyfin: "notJellyfin"
        case .otherJellyfin: "otherJellyfin"
        case .quickConnectOff: "quickConnectOff"
        case .jellyfinDevice: "jellyfinDevice"
        case .jellyfinSessions: "jellyfinSessions"
        case .jellyfinRefused: "jellyfinRefused"
        case .keyRefused: "keyRefused"
        case .notInSeerr: "notInSeerr"
        }
    }

    nonisolated var titleKey: String { "seerr.test.\(caseName).title" }
    nonisolated var fixKey: String { "seerr.test.\(caseName).fix" }
}
