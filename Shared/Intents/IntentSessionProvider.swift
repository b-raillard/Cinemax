import Foundation
import CinemaxKit
import OSLog

/// The credentials an intent needs to talk to the active Jellyfin server.
///
/// `serverId` rides along because entity identity is **composite**: a shortcut
/// saved against one server must not resolve against another. See
/// `MediaEntityID`.
struct IntentSessionContext: Sendable, Equatable {
    let serverId: String
    let serverURL: URL
    let accessToken: String
    let userId: String
}

/// A configured, ready-to-use client plus the context it was built from.
struct IntentSession: Sendable {
    let context: IntentSessionContext
    let api: any APIClientProtocol
}

/// Rebuilds a Jellyfin client from the Keychain **without the app's UI**.
///
/// App Intents resolve entities in the app's process but with no scene: Siri
/// matches a spoken title before deciding what to run, and the Shortcuts editor
/// browses items without ever presenting the app. `AppState.restoreSession` —
/// which is `@MainActor` and driven by SwiftUI's `.task` — has therefore not
/// necessarily run. This is the read path for that context.
///
/// Same discipline as `ExtensionSessionBridge` uses for the widget and Top
/// Shelf, but in-process, so it gets the whole of CinemaxKit rather than a
/// hand-rolled HTTP client.
enum IntentSessionProvider {

    private static let logger = Logger(subsystem: "com.cinemax", category: "Intents")

    /// The active server's credentials, or `nil` when there is nothing to act on.
    ///
    /// Reads the **registry entry**, not the legacy mirror trio, because the
    /// entry is the authoritative record and is the only place carrying the
    /// server id the composite entity identity needs.
    ///
    /// Returns `nil` — rather than falling back to the mirror — when no active
    /// server id is stored. That state means the one-shot multi-server
    /// migration has not run yet, i.e. the app has never completed a launch on
    /// this version; refusing cleanly is honest, and minting an id here would
    /// create one that later disagrees with the registry.
    static func resolveContext(keychain: some SecureStorageProtocol) -> IntentSessionContext? {
        guard let activeId = keychain.getActiveServerId() else { return nil }
        guard let entry = ServerRegistry.activeEntry(in: keychain.getServers(), activeId: activeId),
              entry.id == activeId
        else { return nil }
        // `hasUsableSession` is exactly what `applyActiveServer` accepts: a
        // token AND a non-empty user id. A logged-out entry keeps its card in
        // the servers list, and must not read as actionable here.
        guard entry.hasUsableSession,
              let token = entry.accessToken,
              let userId = entry.userId
        else { return nil }

        return IntentSessionContext(
            serverId: entry.id,
            serverURL: entry.url,
            accessToken: token,
            userId: userId
        )
    }

    /// The parental-controls ceiling to apply to a headless client.
    ///
    /// Read via `object(forKey:)` so the default-unrestricted semantics survive
    /// a fresh install (`integer(forKey:)` would also return 0 here, but only by
    /// coincidence — this keeps the intent explicit and matches how the rest of
    /// the app reads its defaults).
    static func contentRatingLimit(defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: SettingsKey.privacyMaxContentAge) as? Int
            ?? SettingsKey.Default.privacyMaxContentAge
    }

    /// A client pointed at the active server, with the rating ceiling applied.
    ///
    /// **The ceiling is not optional here.** Without it an intent would surface
    /// titles the app itself hides, making Siri a way around parental controls.
    static func makeSession(
        keychain: some SecureStorageProtocol = KeychainService(),
        defaults: UserDefaults = .standard
    ) -> IntentSession? {
        guard let context = resolveContext(keychain: keychain) else {
            logger.debug("No usable session for an intent — refusing to resolve.")
            return nil
        }
        let api = JellyfinAPIClient()
        api.reconnect(url: context.serverURL, accessToken: context.accessToken)
        api.applyContentRatingLimit(maxAge: contentRatingLimit(defaults: defaults))
        return IntentSession(context: context, api: api)
    }
}
