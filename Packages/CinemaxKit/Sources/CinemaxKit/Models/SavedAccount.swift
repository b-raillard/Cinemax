import Foundation

/// One Jellyfin account remembered on this device for a server — what lets a
/// household switch between its members without retyping a password.
///
/// Lives in `ServerEntry.savedAccounts`. The entry's own `accessToken` /
/// `userId` / `username` triple stays "the ACTIVE account of this server", so
/// every reader written before multi-account keeps working unchanged; this list
/// is the set the switcher offers. See `ServerRegistry.accounts(of:)`.
///
/// Several tokens for different users coexist on our single global `device_id`:
/// Jellyfin only revokes the SAME user's earlier tokens for a device when a new
/// one is issued (`SessionManager.GetAuthorizationToken` filters on DeviceId AND
/// UserId — read in 10.9.11, 10.10.7, 10.11.0 and master).
public struct SavedAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: String { userId }
    public var userId: String
    public var username: String
    public var accessToken: String
    public var lastUsedAt: Date

    public init(userId: String, username: String, accessToken: String, lastUsedAt: Date) {
        self.userId = userId
        self.username = username
        self.accessToken = accessToken
        self.lastUsedAt = lastUsedAt
    }
}
