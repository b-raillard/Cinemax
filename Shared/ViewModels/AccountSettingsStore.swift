import Foundation

/// The settings that follow an ACCOUNT rather than the device (multi-account):
/// the age cap, the accent colour and light / dark.
struct AccountSettingsSnapshot: Codable, Equatable, Sendable {
    var maxContentAge: Int
    var accentColor: String
    var darkMode: Bool
}

/// Per-account snapshots of `AccountSettingsSnapshot`, swapped on an account
/// switch.
///
/// **The global keys stay the CURRENT value** (`privacy.maxContentAge`,
/// `accentColor`, `darkMode`): `PlaylistCard`, the widget and Top Shelf, the
/// intents and `VLCStreamPresenter` all read them raw, and none of them needs
/// to know accounts exist. A switch saves the current values under the account
/// being left and writes the target's back into the global keys. An account
/// with no snapshot yet INHERITS the current values — so an account added from
/// a device restricted to 10 years stays at 10 years, never « no limit ».
///
/// Stored as one JSON dictionary `[accountKey: snapshot]` under
/// `SettingsKey.accountSettings`. The age cap is written into the global key
/// here; the appearance is re-applied by `AppNavigation` through
/// `ThemeManager`'s setters (a raw defaults write would not re-render).
enum AccountSettingsStore {
    static func current(defaults: UserDefaults) -> AccountSettingsSnapshot {
        AccountSettingsSnapshot(
            maxContentAge: defaults.integer(forKey: SettingsKey.privacyMaxContentAge),
            accentColor: defaults.string(forKey: SettingsKey.accentColor) ?? SettingsKey.Default.accentColor,
            darkMode: defaults.object(forKey: SettingsKey.darkMode) as? Bool ?? SettingsKey.Default.darkMode
        )
    }

    static func load(for accountKey: String, defaults: UserDefaults) -> AccountSettingsSnapshot? {
        all(defaults: defaults)[accountKey]
    }

    static func save(_ snapshot: AccountSettingsSnapshot, for accountKey: String, defaults: UserDefaults) {
        var map = all(defaults: defaults)
        map[accountKey] = snapshot
        write(map, defaults: defaults)
    }

    /// Leaves `oldKey` for `newKey`: saves the current values under `oldKey`
    /// (when there is one), then writes `newKey`'s age cap into the global key.
    /// Returns `newKey`'s snapshot, `nil` when it has none (it inherits).
    @discardableResult
    static func swap(from oldKey: String?, to newKey: String, defaults: UserDefaults) -> AccountSettingsSnapshot? {
        guard oldKey != newKey else { return nil }
        if let oldKey { save(current(defaults: defaults), for: oldKey, defaults: defaults) }
        guard let target = load(for: newKey, defaults: defaults) else { return nil }
        defaults.set(target.maxContentAge, forKey: SettingsKey.privacyMaxContentAge)
        return target
    }

    /// Whether age cap `candidate` lets more through than `current`. `0` means
    /// « no limit », the most permissive of all.
    static func isLessRestrictive(_ candidate: Int, than current: Int) -> Bool {
        let rank = { (age: Int) in age <= 0 ? Int.max : age }
        return rank(candidate) > rank(current)
    }

    /// The cap `accountKey` would open with: its own, or — never seen — the
    /// current one (it inherits).
    static func ageCap(for accountKey: String, defaults: UserDefaults) -> Int {
        load(for: accountKey, defaults: defaults)?.maxContentAge
            ?? defaults.integer(forKey: SettingsKey.privacyMaxContentAge)
    }

    static func remove(accountKey: String, defaults: UserDefaults) {
        var map = all(defaults: defaults)
        guard map.removeValue(forKey: accountKey) != nil else { return }
        write(map, defaults: defaults)
    }

    static func removeServer(serverId: String, defaults: UserDefaults) {
        let map = all(defaults: defaults)
        let kept = map.filter { !$0.key.hasPrefix(serverId + "|") }
        if kept.count != map.count { write(kept, defaults: defaults) }
    }

    private static func all(defaults: UserDefaults) -> [String: AccountSettingsSnapshot] {
        guard let data = defaults.data(forKey: SettingsKey.accountSettings),
              let map = try? JSONDecoder().decode([String: AccountSettingsSnapshot].self, from: data) else { return [:] }
        return map
    }

    private static func write(_ map: [String: AccountSettingsSnapshot], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: SettingsKey.accountSettings)
    }
}
