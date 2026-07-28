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
/// Shelf) through the **shared Keychain access group** — the app *publishes*
/// a snapshot on every session change (login, restore, user switch, logout)
/// and the extensions only ever read. The token is never written in
/// plaintext, so it can't be lifted from the App Group container or a device
/// backup.
///
/// The extensions deliberately don't link CinemaxKit (widget memory budgets
/// are tight) — they re-declare the Keychain service/account/group literals
/// and the same JSON shape. Keep `KeychainService.serviceName` /
/// `sharedSessionAccount` / `sharedAccessGroupSuffix` and `Session`'s coding
/// keys in sync with `Widgets/` and `TopShelf/` if they ever change.
///
/// `appGroupId` / `sessionKey` survive only to name the *legacy* plaintext
/// App Group copy that `publish` scrubs on upgraded installs — nothing reads
/// them any more.
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
        // Runs on BOTH paths (publish + clear) and *before* the skip
        // early-return below, so an upgraded install's leftover plaintext copy
        // is deleted even when the session itself hasn't changed.
        scrubLegacyDefaultsCopy()
        let keychain = KeychainService()
        let existingKeychainData = keychain.readSharedSession()
        if let serverURL, let accessToken, !accessToken.isEmpty, let userId, !userId.isEmpty {
            let session = Session(serverURL: serverURL, accessToken: accessToken, userId: userId)
            guard !isCurrent(session: session, keychainData: existingKeychainData) else {
                logger.debug("ExtensionBridge ▸ session unchanged, skipped")
                return
            }
            // Sole store: the shared, device-only Keychain group — the token
            // is never written in plaintext nor included in device backups.
            if let data = try? JSONEncoder().encode(session) { keychain.saveSharedSession(data) }
            logger.info("ExtensionBridge ▸ session published host=\(serverURL.host() ?? "?", privacy: .public)")
        } else {
            guard !isCurrent(session: nil, keychainData: existingKeychainData) else {
                logger.debug("ExtensionBridge ▸ session unchanged, skipped")
                return
            }
            keychain.deleteSharedSession()
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

    /// Deletes the legacy plaintext App Group copy of the session that 1.0.3
    /// through 1.0.6 dual-wrote. That write is gone (the token now lives only
    /// in the shared Keychain group), but installs upgrading from those builds
    /// still carry the cleartext blob in the App Group container — and in
    /// their backups — until something removes it.
    ///
    /// Presence-guarded on purpose: the steady state costs one
    /// `object(forKey:)` read and never a write, so calling this ahead of
    /// `publish`'s skip early-return doesn't defeat that optimisation. A
    /// missing App Group suite only skips the scrub — it must never abort the
    /// Keychain publish, which doesn't depend on the App Group at all.
    private static func scrubLegacyDefaultsCopy() {
        guard let defaults = UserDefaults(suiteName: appGroupId) else {
            logger.error("ExtensionBridge ▸ App Group suite unavailable — entitlement missing?")
            return
        }
        guard defaults.object(forKey: sessionKey) != nil else { return }
        defaults.removeObject(forKey: sessionKey)
        logger.info("ExtensionBridge ▸ legacy plaintext session copy scrubbed")
    }

    /// Pure equivalence decision: is `session` (nil ⇒ the "clear" intent)
    /// already what's stored in the shared Keychain, so `publish` can skip the
    /// write + WidgetCenter/Top Shelf poke entirely? Compares decoded
    /// `Session` values field-wise (never raw `Data` bytes — JSON key order
    /// isn't guaranteed stable), and treats a corrupt/undecodable stored blob
    /// as "changed" so a bad read never suppresses a legitimate publish.
    /// The legacy plaintext copy is deliberately NOT an input — it's scrubbed
    /// unconditionally by `scrubLegacyDefaultsCopy()`, never republished.
    /// Internal + testable via `@testable import`.
    static func isCurrent(session: Session?, keychainData: Data?) -> Bool {
        guard let session else {
            // Clearing: only current if the store is already empty — a stale
            // leftover still needs the clear to run.
            return keychainData == nil
        }
        guard let keychainData,
              let storedKeychainSession = try? JSONDecoder().decode(Session.self, from: keychainData) else {
            return false
        }
        return storedKeychainSession == session
    }
}
