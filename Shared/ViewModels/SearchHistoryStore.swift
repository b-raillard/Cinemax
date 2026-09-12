import Foundation

/// Recent-search history, one list per registered server
/// (`search.recentQueries.<serverId>`).
///
/// History was a single global list until servers could be registered side by
/// side, and a global list leaks: queries typed against one server's library
/// resurfaced as chips on another's — a different household, a different
/// account, possibly a different person entirely. The id is the registry's
/// locally minted `ServerEntry.id`, the same key `MenuProfile` uses, so two
/// accounts on ONE server share a list (as they share a menu).
///
/// Pure over an injected `UserDefaults`, so the keying and the migration are
/// testable against a throwaway suite.
///
/// **RULE — the legacy global list migrates ONCE into the first server that
/// activates, and the migration is keyed on a MARKER, not on "nothing stored
/// yet".** `MenuProfile` can key on emptiness because its profiles share one
/// dictionary that nothing ever empties. Here each server owns a separate key,
/// and clearing one (« Effacer », removing a server) deletes it — so
/// "no per-server key exists" can become true again later, and an
/// emptiness-keyed migration would then re-import the old global list into
/// whichever server happened to be active: the very cross-server leak this
/// type exists to close. The marker (`searchRecentQueriesMigratedTo`, which
/// records the inheriting server) is set before anything is copied, so the
/// migration runs at most once whatever follows. It stays **non-destructive**:
/// the legacy key is never deleted by the migration, and an existing
/// per-server list is never overwritten.
///
/// While no server is active (`serverId == nil`) every read and write falls
/// back to the legacy key — the same degrade as `MenuConfigStore` with no
/// profile. Unreachable on the healthy path: Search is only reachable signed in.
enum SearchHistoryStore {
    /// How many queries a list keeps.
    static let maxEntries = 8

    /// The key a server's list lives under; `nil` ⇒ the legacy global key.
    static func key(forServer serverId: String?) -> String {
        guard let serverId, !serverId.isEmpty else { return SettingsKey.searchRecentQueries }
        return SettingsKey.searchRecentQueries(serverId: serverId)
    }

    static func load(serverId: String?, defaults: UserDefaults = .standard) -> [String] {
        guard let data = defaults.data(forKey: key(forServer: serverId)),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [String], serverId: String?, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key(forServer: serverId))
    }

    /// Forgets ONE server's list (« Effacer » on the search screen, or the
    /// server leaving the registry).
    static func clear(serverId: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(forServer: serverId))
    }

    /// Forgets EVERY list — the legacy global one and every server's, including
    /// servers no longer in the registry. Called when the user turns history
    /// capture off in Privacy & Security: that switch is a privacy promise, so
    /// it must not leave queries behind under the servers the user isn't
    /// looking at right now.
    static func clearAll(defaults: UserDefaults = .standard) {
        let prefix = SettingsKey.searchRecentQueries + "."
        defaults.removeObject(forKey: SettingsKey.searchRecentQueries)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// One-shot, idempotent, non-destructive copy of the legacy global list
    /// into `serverId` — see the RULE in the type header. Returns `true` only
    /// when something was actually copied.
    @discardableResult
    static func migrateLegacyIfNeeded(into serverId: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let serverId, !serverId.isEmpty else { return false }
        guard defaults.object(forKey: SettingsKey.searchRecentQueriesMigratedTo) == nil else { return false }
        // Marker first: whatever the outcome below, this never runs again.
        defaults.set(serverId, forKey: SettingsKey.searchRecentQueriesMigratedTo)
        let legacy = load(serverId: nil, defaults: defaults)
        guard !legacy.isEmpty else { return false }
        // Never overwrite a list the server already has.
        guard defaults.object(forKey: key(forServer: serverId)) == nil else { return false }
        save(legacy, serverId: serverId, defaults: defaults)
        return true
    }

    /// `query` moved to the front of `list`, de-duplicated case-insensitively
    /// and capped at `maxEntries`.
    static func recording(_ query: String, into list: [String]) -> [String] {
        var updated = list.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        updated.insert(query, at: 0)
        return Array(updated.prefix(maxEntries))
    }
}
