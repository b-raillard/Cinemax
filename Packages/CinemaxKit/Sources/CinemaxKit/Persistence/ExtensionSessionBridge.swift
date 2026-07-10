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

    public struct Session: Codable, Sendable {
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
        if let serverURL, let accessToken, !accessToken.isEmpty, let userId, !userId.isEmpty {
            let session = Session(serverURL: serverURL, accessToken: accessToken, userId: userId)
            let data = try? JSONEncoder().encode(session)
            // Sole store: the shared, device-only Keychain group — the token is
            // never written in plaintext nor included in device backups. Both
            // extensions (`JellyfinLite.readSession`, `ContentProvider.readSession`)
            // read the Keychain first, so no UserDefaults copy is needed.
            if let data { keychain.saveSharedSession(data) }
            // Migration cleanup: actively remove any plaintext token a prior app
            // version left in the App Group suite (the token used to be
            // dual-written here). Without this, a legacy plaintext copy would
            // linger in backups until the next logout. See CLAUDE.md.
            defaults.removeObject(forKey: sessionKey)
            logger.info("ExtensionBridge ▸ session published host=\(serverURL.host() ?? "?", privacy: .public)")
        } else {
            keychain.deleteSharedSession()
            defaults.removeObject(forKey: sessionKey)
            logger.info("ExtensionBridge ▸ session cleared")
        }
        // Writing the snapshot is not enough — the extensions render from
        // their own cached timelines/content. Without an explicit poke the
        // widget keeps its pre-login "sign in" entry for up to its 30-min
        // refresh window after the user logs in (and a stale shelf lingers
        // after logout).
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        #if canImport(TVServices)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    public static func read() -> Session? {
        // Primary: the shared, device-only Keychain group `publish` writes to.
        if let data = KeychainService().readSharedSession(),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            return session
        }
        // Fallback: a legacy plaintext App Group copy from before the Keychain
        // migration (no longer written; kept only to read any lingering value).
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
}
