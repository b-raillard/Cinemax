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
/// - `displayNameOverride` / `sortIndex` are **user-owned**: written only by
///   `AppState.renameServer` / `AppState.reorderServers`, never by anything
///   that learns about the server (login, switch, reachability ping). That is
///   why `ServerRegistry.upsert` carries them over from the stored entry instead
///   of taking the incoming one's — see the RULE there.
///
/// Every field added after the first shipped registry MUST be optional: the
/// synthesized `Decodable` reads an absent optional as `nil`, which is what
/// lets a registry already sitting in the Keychain decode unchanged. A
/// non-optional addition would fail the whole `[ServerEntry]` decode, and
/// `KeychainService.getServers()` answers that with `[]` — every registered
/// server silently gone.
public struct ServerEntry: Codable, Sendable, Equatable, Identifiable {
    /// Display name used until the server tells us its real one.
    public static let fallbackName = "Jellyfin Server"

    /// Upper bound on a user-given name. Long enough for any real label, short
    /// enough that a pasted paragraph can't blow out a row or a toast.
    public static let maxDisplayNameLength = 60

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
    /// The user's own label for this server, local to this device. `nil` ⇒ show
    /// the server's `name` (and follow it when the server renames itself).
    public var displayNameOverride: String?
    /// Manual position in the servers list. `nil` ⇒ the entry has never been
    /// placed by hand and sorts by the automatic rule — see `ServerRegistry.sorted`.
    public var sortIndex: Int?

    public init(
        id: String = UUID().uuidString,
        name: String = ServerEntry.fallbackName,
        url: URL,
        serverID: String? = nil,
        accessToken: String? = nil,
        userId: String? = nil,
        username: String? = nil,
        serverVersion: String? = nil,
        lastUsedAt: Date = Date(),
        displayNameOverride: String? = nil,
        sortIndex: Int? = nil
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
        self.displayNameOverride = displayNameOverride
        self.sortIndex = sortIndex
    }

    /// What every surface prints for this server: the user's label when they
    /// gave one, else the name the server reports.
    public var displayName: String {
        if let override = displayNameOverride, !override.isEmpty { return override }
        return name
    }

    /// Normalizes raw rename input into the value `displayNameOverride` stores.
    ///
    /// Whitespace is trimmed and the result capped at `maxDisplayNameLength`.
    /// Both "nothing" and "exactly the server's own name" map to `nil` — i.e.
    /// "no override" — so clearing the field restores the server's name, and a
    /// label that merely restates it keeps following the server if it is
    /// renamed server-side later.
    public static func normalizedDisplayNameOverride(_ raw: String?, serverName: String) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let capped = String(trimmed.prefix(maxDisplayNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped == serverName ? nil : capped
    }

    /// `true` when the entry carries a usable token (an empty string counts as
    /// signed out — a truncated Keychain read must never look like a session).
    public var hasSession: Bool {
        guard let accessToken else { return false }
        return !accessToken.isEmpty
    }

    /// `true` when the entry can actually be *applied* as the active server.
    ///
    /// Mirrors `AppState.applyActiveServer`'s guard exactly: a session needs
    /// BOTH a token and a user id. A token-without-user entry is reachable (a
    /// migrated install whose `access_token` survived but whose `user_session`
    /// didn't) and the app routes it to a fresh login instead of applying it —
    /// so any UI that asks "is this server already signed in?" must ask THIS,
    /// not `hasSession`, or it will refuse an action the app can't complete.
    public var hasUsableSession: Bool {
        guard hasSession, let userId else { return false }
        return !userId.isEmpty
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
