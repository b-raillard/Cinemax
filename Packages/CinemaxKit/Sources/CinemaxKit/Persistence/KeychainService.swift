import Foundation
import Security

public struct KeychainService: Sendable {
    /// Keychain service name for every stored item. `internal` (not `private`)
    /// so the extension-contract test can lock it — the extensions
    /// (`JellyfinLite` / `ContentProvider`) re-declare this literal and can't
    /// link CinemaxKit, so the test is the only guard against drift.
    static let serviceName = "com.cinemax.jellyfin"

    /// Accessibility class for every item we store.
    ///
    /// `AfterFirstUnlock…` (not `WhenUnlocked…`): on a tvOS cold boot the app
    /// can relaunch into `restoreSession()` *before* the keychain finishes
    /// coming up under `WhenUnlocked`, so `getUserSession()` reads back empty
    /// and the user appears logged out. `AfterFirstUnlock` keeps items readable
    /// for the rest of the boot cycle once the device has unlocked once — which
    /// is exactly the wake-from-standby window where the spurious disconnect
    /// happened. `ThisDeviceOnly` is preserved (never synced to iCloud).
    /// Computed (not stored) so the non-`Sendable` `CFString` global isn't
    /// captured in a `static let` — which Swift 6 rejects as not concurrency-safe.
    private static var itemAccessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    /// One-shot flag so the accessibility migration re-saves stored items only once.
    private static let accessibilityMigratedKey = "keychain.accessibility.afterFirstUnlock.migrated"

    /// Session fallback for the device id: if the keychain is locked at first
    /// launch the `SecItemAdd` below fails, and without this every call would
    /// mint a fresh UUID and fragment device identity. Lock-guarded so the
    /// static accessor stays Sendable-safe.
    private static let deviceIDLock = NSLock()
    nonisolated(unsafe) private static var cachedDeviceID: String?

    public init() {}

    // MARK: - Access Token

    public func saveAccessToken(_ token: String) throws {
        try save(data: Data(token.utf8), for: "access_token")
    }

    public func getAccessToken() -> String? {
        guard let data = getData(for: "access_token") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteAccessToken() {
        delete(for: "access_token")
    }

    // MARK: - Server URL

    public func saveServerURL(_ url: URL) throws {
        try save(data: Data(url.absoluteString.utf8), for: "server_url")
    }

    public func getServerURL() -> URL? {
        guard let data = getData(for: "server_url"),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: string)
    }

    public func deleteServerURL() {
        delete(for: "server_url")
    }

    // MARK: - User Session

    public func saveUserSession(_ session: UserSession) throws {
        let data = try JSONEncoder().encode(session)
        try save(data: data, for: "user_session")
    }

    public func getUserSession() -> UserSession? {
        guard let data = getData(for: "user_session") else { return nil }
        return try? JSONDecoder().decode(UserSession.self, from: data)
    }

    public func deleteUserSession() {
        delete(for: "user_session")
    }

    // MARK: - Shared extension session (Keychain access group)

    /// Account name of the single shared item the extensions read. Mirrors the
    /// literal hardcoded in the widget (`JellyfinLite`) and Top Shelf
    /// (`ContentProvider`), which can't link CinemaxKit — kept in sync via the
    /// extension-contract test. `internal` for the same test-locking reason.
    static let sharedSessionAccount = "extension_session"

    /// Suffix of the shared Keychain access group (the part after the team
    /// prefix). Mirrors the `keychain-access-groups` entitlement value
    /// (`$(AppIdentifierPrefix)com.cinemax.shared`) and the suffix the
    /// extensions re-declare — locked by the extension-contract test.
    static let sharedAccessGroupSuffix = "com.cinemax.shared"

    /// Full identifier of the shared Keychain access group
    /// (`<TeamPrefix>com.cinemax.shared`), resolved from the `AppIdentifierPrefix`
    /// Info.plist key injected at sign time. `nil` in an unsigned / prefix-less
    /// context — callers then skip the shared Keychain and the legacy App Group
    /// UserDefaults copy still covers the extensions.
    public static var sharedAccessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty else { return nil }
        return prefix + sharedAccessGroupSuffix
    }

    /// Writes the extension session blob into the shared, device-only Keychain
    /// group so the widget / Top Shelf read it instead of plaintext App Group
    /// UserDefaults. Scoped to the shared group via an explicit
    /// `kSecAttrAccessGroup` so it never disturbs the app-private session items.
    /// No-op when the shared group can't be resolved.
    public func saveSharedSession(_ data: Data) {
        guard let group = Self.sharedAccessGroup else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.sharedSessionAccount,
            kSecAttrAccessGroup as String: group
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = Self.itemAccessibility
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Reads the shared session blob back (used by the round-trip test; the
    /// extensions read it inline since they can't link this module).
    public func readSharedSession() -> Data? {
        guard let group = Self.sharedAccessGroup else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.sharedSessionAccount,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func deleteSharedSession() {
        guard let group = Self.sharedAccessGroup else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.sharedSessionAccount,
            kSecAttrAccessGroup as String: group
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Accessibility migration

    /// Re-saves already-stored items under the new `AfterFirstUnlock`
    /// accessibility class. Idempotent (UserDefaults flag) and lossless:
    /// `save()` is delete-then-add, and we only re-write items that read back
    /// successfully *this* launch — so a re-save can never erase a value we
    /// still have. Call after a confirmed-readable restore. The flag is set
    /// only when every re-save succeeds, so a partial failure retries next launch.
    public func migrateAccessibilityIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.accessibilityMigratedKey) else { return }
        var allSucceeded = true
        if let token = getAccessToken() {
            do { try saveAccessToken(token) } catch { allSucceeded = false }
        }
        if let session = getUserSession() {
            do { try saveUserSession(session) } catch { allSucceeded = false }
        }
        if let url = getServerURL() {
            do { try saveServerURL(url) } catch { allSucceeded = false }
        }
        Self.migrateDeviceIDAccessibility()   // best-effort; has its own in-memory fallback
        if allSucceeded {
            UserDefaults.standard.set(true, forKey: Self.accessibilityMigratedKey)
        }
    }

    /// Rewrites the persistent device id under the new accessibility class.
    /// Best-effort: failures are tolerated because `cachedDeviceID` already
    /// keeps the id stable within a run even if the keychain read/write fails.
    private static func migrateDeviceIDAccessibility() {
        let account = "device_id"
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: itemAccessibility
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    // MARK: - Clear All

    public func clearAll() {
        deleteAccessToken()
        deleteServerURL()
        deleteUserSession()
        // Device ID intentionally preserved — identifies the device across sessions
    }

    // MARK: - Device ID (static — persists for the lifetime of the app install)

    /// Returns the persistent device identifier, creating and storing it on first call.
    /// Migrates from UserDefaults if a legacy value exists.
    public static func getOrCreateDeviceID() -> String {
        let account = "device_id"
        // Return the session-cached id if a prior call already resolved one
        // (covers the keychain-locked first-launch case).
        deviceIDLock.lock()
        if let cached = cachedDeviceID {
            deviceIDLock.unlock()
            return cached
        }
        deviceIDLock.unlock()
        // Try Keychain first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let id = String(data: data, encoding: .utf8) {
            deviceIDLock.lock()
            cachedDeviceID = id
            deviceIDLock.unlock()
            return id
        }

        // Migrate from UserDefaults or create a new identifier
        let id: String
        if let legacy = UserDefaults.standard.string(forKey: "cinemax_device_id") {
            id = legacy
            UserDefaults.standard.removeObject(forKey: "cinemax_device_id")
        } else {
            id = UUID().uuidString
        }

        let saveQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(id.utf8),
            kSecAttrAccessible as String: itemAccessibility
        ]
        // Cache for the session regardless: if the add fails (keychain locked
        // at first launch) we still want a stable id for this run instead of a
        // new UUID on every call.
        deviceIDLock.lock()
        cachedDeviceID = id
        deviceIDLock.unlock()
        let status = SecItemAdd(saveQuery as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            // Persisted-store write failed; the session cache above keeps the
            // id stable until the next launch retries.
            assertionFailure("Keychain device-id write failed: \(status)")
        }
        return id
    }

    // MARK: - Private

    private func save(data: Data, for key: String) throws {
        delete(for: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.itemAccessibility
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func getData(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum KeychainError: LocalizedError, Sendable {
    case saveFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            "Failed to save to Keychain (status: \(status))"
        }
    }
}
