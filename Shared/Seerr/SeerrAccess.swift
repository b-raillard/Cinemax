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

    /// An HTTPS Jellyfin with a plain-HTTP Seerr (owner, 2026-11-07): the
    /// session is then never renewed silently — a man-in-the-middle on the
    /// unencrypted Seerr could have Jellyfin approve a Quick Connect code it
    /// started — only by the visible « Se connecter à Seerr ». Any other pair,
    /// or a scheme unknown on either side, is not a downgrade.
    nonisolated static func downgradesFromHTTPS(jellyfin: URL?, seerr: URL?) -> Bool {
        jellyfin?.scheme?.lowercased() == "https" && seerr?.scheme?.lowercased() == "http"
    }

    /// What a failed one-gesture sign-in tells the user — the connection
    /// test's message for the same reason, wherever the sign-in was started
    /// (the test, « Se connecter à Seerr »). `nil` = nothing to say (cancelled:
    /// the account changed, or the sign-in no longer applies).
    nonisolated static func signInFailure(_ error: SeerrSignInError, policy: UserPolicy?) -> SeerrTestFailure? {
        switch error {
        case .cancelled: nil
        case .otherJellyfin: .otherJellyfin
        case .jellyfinRefused: refusalFailure(policy: policy)
        case .notImported: .notInSeerr
        case .seerr(.redirected): .redirected
        case .seerr(.notSeerr): .notSeerr
        case .timedOut, .seerr: .unreachable
        }
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
