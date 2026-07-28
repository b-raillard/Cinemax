import Foundation

/// One registered Jellyfin server in the multi-server registry.
///
/// Persisted as a JSON array in the app-private Keychain (`servers` account —
/// see `KeychainService`), alongside a pointer to the active entry
/// (`active_server_id`).
///
/// - `id` is a **locally minted** UUID string, not Jellyfin's server id: it
///   stays stable when the user edits the URL of an already-registered server,
///   and it exists even before we've ever talked to the server (`serverID` is
///   only known after a successful `connectToServer` / ping).
/// - `url` is always the **normalized** form (`ServerURLNormalizer`), because
///   dedup ("is this server already registered?") compares normalized URLs.
/// - `accessToken == nil` means "registered but signed out" — the card stays in
///   the list, ready for a re-login. It is never a reason to drop the entry.
public struct ServerEntry: Codable, Sendable, Equatable, Identifiable {
    /// Display name used until the server tells us its real one.
    public static let fallbackName = "Jellyfin Server"

    /// Locally minted, stable across URL edits. Never Jellyfin's server id.
    public let id: String
    /// `ServerInfo.name`, or `fallbackName` before the server has been reached.
    public var name: String
    /// Normalized server URL (`ServerURLNormalizer.normalize`).
    public var url: URL
    /// Jellyfin's own server id (`UserSession.serverID` / `ServerInfo.serverID`).
    public var serverID: String?
    /// `nil` ⇒ entry present but signed out.
    public var accessToken: String?
    public var userId: String?
    public var username: String?
    public var serverVersion: String?
    public var lastUsedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String = ServerEntry.fallbackName,
        url: URL,
        serverID: String? = nil,
        accessToken: String? = nil,
        userId: String? = nil,
        username: String? = nil,
        serverVersion: String? = nil,
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.serverID = serverID
        self.accessToken = accessToken
        self.userId = userId
        self.username = username
        self.serverVersion = serverVersion
        self.lastUsedAt = lastUsedAt
    }

    /// `true` when the entry carries a usable token (an empty string counts as
    /// signed out — a truncated Keychain read must never look like a session).
    public var hasSession: Bool {
        guard let accessToken else { return false }
        return !accessToken.isEmpty
    }

    /// Pure builder for the one-shot single-server → registry migration.
    ///
    /// Split out of `KeychainService.migrateToMultiServerIfNeeded()` so the
    /// decision is unit-testable without a real Keychain (and so every
    /// `SecureStorageProtocol` conformer migrates identically). Returns `nil`
    /// when there is nothing to migrate (fresh install: no stored server URL).
    /// The name is left at `fallbackName` on purpose — the first
    /// `fetchServerInfo` / reachability ping fills in the real one.
    public static func migrated(
        serverURL: URL?,
        session: UserSession?,
        accessToken: String?
    ) -> ServerEntry? {
        guard let serverURL else { return nil }
        return ServerEntry(
            name: fallbackName,
            url: ServerURLNormalizer.normalize(serverURL) ?? serverURL,
            serverID: session?.serverID,
            accessToken: session?.accessToken ?? accessToken,
            userId: session?.userID,
            username: session?.username,
            serverVersion: nil
        )
    }
}
