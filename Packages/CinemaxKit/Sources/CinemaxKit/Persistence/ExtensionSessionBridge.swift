import Foundation

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
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        if let serverURL, let accessToken, !accessToken.isEmpty, let userId, !userId.isEmpty {
            let session = Session(serverURL: serverURL, accessToken: accessToken, userId: userId)
            defaults.set(try? JSONEncoder().encode(session), forKey: sessionKey)
        } else {
            defaults.removeObject(forKey: sessionKey)
        }
    }

    public static func read() -> Session? {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
}
