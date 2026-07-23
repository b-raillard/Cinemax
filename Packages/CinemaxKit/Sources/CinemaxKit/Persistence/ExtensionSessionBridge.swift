import Foundation
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(TVServices)
import TVServices
#endif

private let logger = Logger(subsystem: "com.cinemax", category: "ExtensionBridge")

/// Hands the Jellyfin session to the app extensions (iOS widget, tvOS Top
/// Shelf) through the shared App Group. Extensions can't read the app's
/// keychain items, and reworking the keychain into a shared access group
/// would orphan existing installs' items — so the app *publishes* a snapshot
/// here on every session change (login, restore, user switch, logout) and the
/// extensions only ever read.
///
/// The extensions deliberately don't link CinemaxKit (widget memory budgets
/// are tight) — they re-declare the suite/key constants and the same JSON
/// shape. Keep `appGroupId`, `sessionKey`, and `Session`'s coding keys in
/// sync with `Widgets/` and `TopShelf/` if they ever change.
public enum ExtensionSessionBridge {
    public static let appGroupId = "group.com.cinemax.shared"
    public static let sessionKey = "extension.session"

    public struct Session: Codable, Sendable, Equatable {
        public let serverURL: URL
        public let accessToken: String
        public let userId: String

        public init(serverURL: URL, accessToken: String, userId: String) {
            self.serverURL = serverURL
            self.accessToken = accessToken
            self.userId = userId
        }
    }

    /// Publishes the current session, or clears it when any part is nil
    /// (logout / disconnect).
    public static func publish(serverURL: URL?, accessToken: String?, userId: String?) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else {
            logger.error("ExtensionBridge ▸ App Group suite unavailable — entitlement missing?")
            return
        }
        let keychain = KeychainService()
        let existingKeychainData = keychain.readSharedSession()
        let existingDefaultsData = defaults.data(forKey: sessionKey)
        if let serverURL, let accessToken, !accessToken.isEmpty, let userId, !userId.isEmpty {
            let session = Session(serverURL: serverURL, accessToken: accessToken, userId: userId)
            guard !isCurrent(session: session, keychainData: existingKeychainData, defaultsData: existingDefaultsData) else {
                logger.debug("ExtensionBridge ▸ session unchanged, skipped")
                return
            }
            let data = try? JSONEncoder().encode(session)
            // Primary store: the shared, device-only Keychain group — the token
            // is never written in plaintext nor included in device backups.
            if let data { keychain.saveSharedSession(data) }
            // Transitional dual-write: keep the App Group UserDefaults copy for
            // one release so an extension binary that predates the Keychain
            // migration still finds a session, and as a fallback if the shared
            // Keychain group can't be resolved. TODO(next release): drop this
            // plaintext write once both extensions read from the Keychain.
            defaults.set(data, forKey: sessionKey)
            logger.info("ExtensionBridge ▸ session published host=\(serverURL.host() ?? "?", privacy: .public)")
        } else {
            guard !isCurrent(session: nil, keychainData: existingKeychainData, defaultsData: existingDefaultsData) else {
                logger.debug("ExtensionBridge ▸ session unchanged, skipped")
                return
            }
            keychain.deleteSharedSession()
            defaults.removeObject(forKey: sessionKey)
            logger.info("ExtensionBridge ▸ session cleared")
        }
        // Writing the snapshot is not enough — the extensions render from
        // their own cached timelines/content. Without an explicit poke the
        // widget keeps its pre-login "sign in" entry for up to its 30-min
        // refresh window after the user logs in (and a stale shelf lingers
        // after logout). Only reached when a write above actually happened.
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        #if canImport(TVServices)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    /// Pure equivalence decision: is `session` (nil ⇒ the "clear" intent)
    /// already what's stored in BOTH the Keychain and the transitional
    /// UserDefaults copy, so `publish` can skip the write + WidgetCenter/Top
    /// Shelf poke entirely? Compares decoded `Session` values field-wise
    /// (never raw `Data` bytes — JSON key order isn't guaranteed stable), and
    /// treats a corrupt/undecodable stored blob as "changed" so a bad read
    /// never suppresses a legitimate publish. Internal + testable via
    /// `@testable import`.
    static func isCurrent(session: Session?, keychainData: Data?, defaultsData: Data?) -> Bool {
        guard let session else {
            // Clearing: only current if both stores are already empty — a
            // stale leftover in either one still needs the clear to run.
            return keychainData == nil && defaultsData == nil
        }
        guard let keychainData,
              let storedKeychainSession = try? JSONDecoder().decode(Session.self, from: keychainData) else {
            return false
        }
        guard let defaultsData,
              let storedDefaultsSession = try? JSONDecoder().decode(Session.self, from: defaultsData) else {
            return false
        }
        return storedKeychainSession == session && storedDefaultsSession == session
    }
}
