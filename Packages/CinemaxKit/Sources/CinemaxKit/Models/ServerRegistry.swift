import Foundation

/// Outcome of an attempted server switch. Returned by `AppState.switchTo` so
/// the calling screen can toast / dismiss; every case is a decision the pure
/// `ServerRegistry.decideSwitch` reached, never a side effect it performed.
public enum SwitchDecision: Sendable, Equatable {
    /// `NetworkMonitor` says we're offline → toast, no switch, nothing mutated.
    case offline
    /// No stored token, or the server CONFIRMED the token is revoked →
    /// `LoginScreen` scoped to that server.
    case needsLogin
    /// The probe was `.indeterminate` (server unreachable / slow / non-401).
    /// Stay on the previous server and **keep the target's token** — the
    /// "never destroy on indeterminate" rule from `handlePossibleSessionExpiry`.
    case unreachable
    /// Token validated → commit the switch.
    case commit
}

/// Pure decision logic for the multi-server registry.
///
/// Deliberately free of Keychain, `JellyfinAPIClient` and `AppState`: every
/// function here is a total, side-effect-free transformation, which is what
/// makes the switch/logout/dedup semantics unit-testable. All the stateful
/// orchestration lives in `AppState`.
public enum ServerRegistry {

    /// The entry the app should consider active.
    ///
    /// Falls back to the most-recently-used entry when `activeId` is `nil` or
    /// stale (e.g. the active server was removed on another launch) so the app
    /// can never end up with a populated list and no active server.
    public static func activeEntry(in entries: [ServerEntry], activeId: String?) -> ServerEntry? {
        if let activeId, let match = entries.first(where: { $0.id == activeId }) { return match }
        return entries.max { $0.lastUsedAt < $1.lastUsedAt }
    }

    /// Display order: active first, then most-recently-used. Ties break on `id`
    /// so the order is total and the list never reshuffles between renders.
    public static func sorted(_ entries: [ServerEntry], activeId: String?) -> [ServerEntry] {
        entries.sorted { lhs, rhs in
            if lhs.id == activeId { return true }
            if rhs.id == activeId { return false }
            if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt }
            return lhs.id < rhs.id
        }
    }

    /// Inserts or updates `entry`, deduping on the NORMALIZED URL.
    ///
    /// An existing match is replaced in place, **preserving the stored id**
    /// (ids are referenced by `activeServerId` and by any in-flight UI) and
    /// keeping the newer `lastUsedAt` of the two, so the timestamp can only
    /// move forward. Field merging (e.g. carrying an already-discovered server
    /// name over a placeholder) is the caller's job — this stays a replace so
    /// its behavior is obvious at the call site.
    public static func upsert(_ entry: ServerEntry, into entries: [ServerEntry]) -> [ServerEntry] {
        let key = ServerURLNormalizer.dedupKey(entry.url)
        guard let index = entries.firstIndex(where: { ServerURLNormalizer.dedupKey($0.url) == key }) else {
            return entries + [entry]
        }
        var updated = entries
        let existing = updated[index]
        var merged = ServerEntry(
            id: existing.id,                                   // ids are stable across URL edits
            name: entry.name,
            url: entry.url,
            serverID: entry.serverID,
            accessToken: entry.accessToken,
            userId: entry.userId,
            username: entry.username,
            serverVersion: entry.serverVersion,
            lastUsedAt: entry.lastUsedAt
        )
        merged.lastUsedAt = max(existing.lastUsedAt, entry.lastUsedAt)
        updated[index] = merged
        return updated
    }

    /// Dedup probe for the add flow: is this URL (in any equivalent spelling)
    /// already registered?
    public static func contains(url: URL, in entries: [ServerEntry]) -> ServerEntry? {
        let key = ServerURLNormalizer.dedupKey(url)
        return entries.first { ServerURLNormalizer.dedupKey($0.url) == key }
    }

    /// The server to hop to after signing out of `id`: the most-recently-used
    /// OTHER entry that still holds a token. `nil` ⇒ nothing to hop to, the app
    /// falls back to `ServerSetupScreen`.
    public static func nextCandidate(after id: String, in entries: [ServerEntry]) -> ServerEntry? {
        entries
            .filter { $0.id != id && $0.hasSession }
            .max { $0.lastUsedAt < $1.lastUsedAt }
    }

    /// Switch decision, called twice by `AppState.switchTo`.
    ///
    /// - `validity == nil` is the **pre-flight** pass: it short-circuits the two
    ///   cases that must never reach the network (offline, no stored token) and
    ///   otherwise answers `.commit` meaning "proceed to validate".
    /// - `validity != nil` is the post-probe pass and maps the server's answer.
    ///
    /// `.indeterminate` deliberately maps to `.unreachable`, NOT `.needsLogin`:
    /// we cannot prove the token is bad, so it must survive.
    public static func decideSwitch(
        entry: ServerEntry,
        isOnline: Bool,
        validity: SessionValidity?
    ) -> SwitchDecision {
        guard isOnline else { return .offline }
        guard entry.hasSession else { return .needsLogin }
        switch validity {
        case .none, .some(.valid): return .commit
        case .some(.invalid): return .needsLogin
        case .some(.indeterminate): return .unreachable
        }
    }
}
