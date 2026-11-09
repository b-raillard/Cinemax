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

/// The card on top of an administrator's Réglages → Demandes summary (layout
/// A, owner 2026-11-09): the connection, and the one action that helps. Pure.
enum SeerrSummaryCard: Equatable {
    /// No address yet: a welcome card and « Configurer Seerr », nothing else.
    case setup
    /// Account mode without a live session: « Se connecter à Seerr ».
    case signIn
    /// Seerr not answering, or not known yet: « Réessayer ».
    case unavailable
    /// Key mode, Seerr has no user for this account or refuses the key: what
    /// to fix, with no action (the fix is in Seerr).
    case failure(SeerrTestFailure)
    case connected(SeerrUser, usesDeviceKey: Bool)

    static func of(url: URL?, connection: SeerrSession.Connection, usesDeviceKey: Bool) -> Self {
        guard url != nil else { return .setup }
        switch connection {
        case .connected(let user): return .connected(user, usesDeviceKey: usesDeviceKey)
        case .notConnected: return .signIn
        case .notLinked: return .failure(.notInSeerr)
        case .keyRefused: return .failure(.keyRefused)
        case .unavailable: return .unavailable
        }
    }

    /// The request rows (« À valider », « Mes demandes ») under the card:
    /// open when connected, greyed with this reason while Seerr cannot be
    /// read yet — `nil` there means they are left out (no address, or a
    /// failure the card explains).
    var lockedReasonKey: String? {
        switch self {
        case .signIn: "seerr.hub.locked.signIn"
        case .unavailable: "seerr.hub.locked.unavailable"
        case .setup, .failure, .connected: nil
        }
    }

    var showsRequestRows: Bool {
        switch self {
        case .signIn, .unavailable, .connected: true
        case .setup, .failure: false
        }
    }

    /// « Administration » (who may request, the Seerr server): every card
    /// but the welcome one, whose button opens the server page itself.
    var showsAdministration: Bool { self != .setup }
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
