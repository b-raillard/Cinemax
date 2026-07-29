import Foundation

/// Identity of a library item as seen by Siri and Shortcuts: **(server, item)**,
/// never the Jellyfin item id alone.
///
/// A saved shortcut outlives the state it was built in — the user may add a
/// server, switch to it, or log out and back in before replaying it. Carrying
/// the server means `MediaItemQuery` can refuse a stale identity outright
/// instead of resolving it against whichever server happens to be active, which
/// would quietly play the wrong thing.
///
/// The raw form is what App Intents persists, so it is treated as long-lived,
/// user-reachable data: parsing is strict and the item component is checked
/// against the same shape rule as a deep link (`AppState.isValidItemId`).
struct MediaEntityID: Hashable, Sendable {

    /// Neither component can contain this: server ids are locally minted UUID
    /// strings, item ids are hex or dashed GUIDs.
    private static let separator: Character = "|"

    let serverId: String
    let itemId: String

    init(serverId: String, itemId: String) {
        self.serverId = serverId
        self.itemId = itemId
    }

    /// Parses a persisted identity, rejecting anything malformed rather than
    /// guessing. A corrupted or hand-edited shortcut must fail, not resolve.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let server = String(parts[0])
        let item = String(parts[1])
        guard !server.isEmpty, AppState.isValidItemId(item) else { return nil }
        self.serverId = server
        self.itemId = item
    }

    var rawValue: String { "\(serverId)\(Self.separator)\(itemId)" }

    /// Whether this identity may be resolved against `serverId`.
    ///
    /// The guard the composite id exists for — checked before any lookup, so a
    /// shortcut built on one server can never reach an item on another.
    func belongs(to serverId: String) -> Bool { self.serverId == serverId }
}
