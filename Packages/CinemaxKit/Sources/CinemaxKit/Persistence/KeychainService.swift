import Foundation
import Security
import os

private let keychainLog = Logger(subsystem: "com.cinemax", category: "Keychain")

/// App-private Keychain storage.
///
/// **RULE — the legacy trio (`server_url` / `user_session` / `access_token`) is
/// a derived MIRROR of the active `ServerEntry`, never an independent source of
/// truth.** Multi-server added two items (`servers`, `active_server_id`) but did
/// NOT change how the rest of the app reads a session: `getServerURL()` /
/// `getAccessToken()` / `getUserSession()` still return the legacy trio verbatim,
/// so `AppState.restoreSession`, `LoginViewModel.completeSession`,
/// `SettingsScreen` and `ExtensionSessionBridge` are untouched by the feature.
/// Exactly one function rewrites that mirror — `AppState.applyActiveServer` —
/// and `migrateToMultiServerIfNeeded()` seeds the registry *from* it. Consequences:
/// - `clearAll()` clears ONLY the legacy trio. Wiping `servers` there would nuke
///   every other registered server on a plain logout.
/// - The migration is purely additive: it never deletes a legacy item, so even a
///   total migration failure preserves today's exact single-server behavior.
///
/// `device_id` stays global across servers (one device identity per install).
///
/// **RULE — "app-private" means the app's OWN access group, and it has to be
/// first in `keychain-access-groups`.** Items written without an explicit
/// `kSecAttrAccessGroup` land in the FIRST group of that entitlement, and until
/// 2026-09-22 the only group listed was the shared extension one — so every
/// token of every registered server, the parental-lock verifier and the
/// certificate pins were readable by the widget and the Top Shelf. The app's
/// own group (`$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`) now leads
/// the list on both app targets, and `migrateToPrivateAccessGroupIfNeeded()`
/// moves the items already stored in the shared group. Only
/// `extension_session` belongs there, and it always names the group explicitly.
///
/// **RULE — writes are UPDATE-then-ADD, never delete-then-add.** A failed add
/// after a delete lost the value for good: the token (a silent logout next
/// launch), the whole server registry, or the parental lock — which then read
/// as "no lock", i.e. open.
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

    // MARK: - Multi-server registry

    /// Account holding the JSON-encoded `[ServerEntry]` list.
    static let serversAccount = "servers"
    /// Account holding the active entry's id (UTF-8), or absent when none.
    static let activeServerIdAccount = "active_server_id"

    /// The registered servers. A decode failure returns `[]` — which also
    /// re-arms `migrateToMultiServerIfNeeded()` off the still-present legacy
    /// trio, so the ACTIVE server comes back instead of stranding the user;
    /// the other servers of that blob are lost with it. Logged, because it
    /// used to be silent. (No copy is set aside: it would be a second store of
    /// every server's token that nothing ever reads back.)
    public func getServers() -> [ServerEntry] {
        guard let data = getData(for: Self.serversAccount) else { return [] }
        do {
            return try JSONDecoder().decode([ServerEntry].self, from: data)
        } catch {
            keychainLog.fault("Server registry unreadable (\(data.count) bytes): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Single item, written in place (see `save`), so a partial write can't
    /// leave a half-updated list.
    public func saveServers(_ entries: [ServerEntry]) throws {
        try save(data: JSONEncoder().encode(entries), for: Self.serversAccount)
    }

    public func getActiveServerId() -> String? {
        guard let data = getData(for: Self.activeServerIdAccount),
              let id = String(data: data, encoding: .utf8),
              !id.isEmpty else { return nil }
        return id
    }

    /// `nil` (or empty) removes the pointer — used when the last server is
    /// signed out and the app falls back to `ServerSetupScreen`.
    public func saveActiveServerId(_ id: String?) {
        guard let id, !id.isEmpty else {
            delete(for: Self.activeServerIdAccount)
            return
        }
        do {
            try save(data: Data(id.utf8), for: Self.activeServerIdAccount)
        } catch {
            keychainLog.error("Saving the active server id failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // The single-server → registry migration deliberately lives in the
    // `SecureStorageProtocol` extension, NOT here: it needs only protocol
    // members, and a copy on each conformer would let the test mock's version
    // drift from the one that actually ships. See the RULE there.

    // MARK: - Explicitly trusted server certificates

    /// Account holding `[trustKey: sha256HexFingerprint]`.
    static let trustedCertificatesAccount = "trusted_certificates"

    /// Leaf certificates the user explicitly approved, keyed by `host:port`
    /// (`ServerCertificateTrust.trustKey`).
    ///
    /// **Keyed by HOST, not by `ServerEntry`, and that is a deliberate deviation
    /// from the issue that proposed the field on the entry.** The approval has
    /// to happen on `ServerSetupScreen`, BEFORE any entry exists — you cannot
    /// reach the server to sign in until its certificate is accepted, and the
    /// entry is only created by a successful login. `host:port` is also exactly
    /// what a TLS challenge hands the delegate, so no resolution step can
    /// disagree with the lookup.
    ///
    /// App-private: the extensions read their own copy of the session blob and
    /// are not covered by this item.
    public func getTrustedCertificates() -> [String: String] {
        guard let data = getData(for: Self.trustedCertificatesAccount) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Written whole, in place (see `save`), so a partial write cannot leave
    /// half a pin map.
    public func saveTrustedCertificates(_ pins: [String: String]) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        do {
            try save(data: data, for: Self.trustedCertificatesAccount)
        } catch {
            keychainLog.error("Saving certificate pins failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Parental-controls lock

    /// Account holding the JSON `ParentalLockCredential`.
    static let parentalLockAccount = "parental_lock"

    /// The enrolled parental-controls lock, or `nil` when none is set.
    ///
    /// **App-private, and deliberately NOT in the shared extension group**: the
    /// widget and Top Shelf have nothing to unlock, and handing them a verifier
    /// would only widen where it can be read from.
    ///
    /// A decode failure returns `nil`, i.e. "no lock". That is fail-OPEN, and it
    /// is the right way round here: the alternative strands the parent in a
    /// screen they can never unlock because a blob became unreadable, while the
    /// thing this protects is a content filter, not a credential. The Keychain
    /// item is written whole and in place (see `save`), so neither a partial
    /// write nor a failed one can produce that state in the first place.
    public func getParentalLock() -> ParentalLockCredential? {
        guard let data = getData(for: Self.parentalLockAccount) else { return nil }
        return try? JSONDecoder().decode(ParentalLockCredential.self, from: data)
    }

    /// Persists the credential, counters included — `ParentalLockPolicy.verify`
    /// returns the updated value precisely so the back-off survives a force-quit.
    public func saveParentalLock(_ credential: ParentalLockCredential) throws {
        try save(data: JSONEncoder().encode(credential), for: Self.parentalLockAccount)
    }

    /// Removes the lock. Reached only from behind an unlocked gate.
    public func deleteParentalLock() {
        delete(for: Self.parentalLockAccount)
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
    /// context — callers then skip the shared Keychain (the extensions then have
    /// no session to read).
    public static var sharedAccessGroup: String? {
        guard let prefix = appIdentifierPrefix else { return nil }
        return prefix + sharedAccessGroupSuffix
    }

    /// The app's OWN access group (`<TeamPrefix><bundle id>`), first in its
    /// `keychain-access-groups` so it is where group-less writes land. `nil`
    /// in an unsigned / prefix-less context.
    static var privateAccessGroup: String? {
        guard let prefix = appIdentifierPrefix,
              let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else { return nil }
        return prefix + bundleId
    }

    private static var appIdentifierPrefix: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty, !prefix.hasPrefix("$(") else { return nil }
        return prefix
    }

    /// Writes the extension session blob into the shared, device-only Keychain
    /// group so the widget / Top Shelf read it instead of plaintext App Group
    /// UserDefaults. Scoped to the shared group via an explicit
    /// `kSecAttrAccessGroup` so it never disturbs the app-private session items.
    /// No-op when the shared group can't be resolved.
    /// `true` once the item holds `data`. The caller must not treat the
    /// session as published otherwise (see `ExtensionSessionBridge.publish`).
    @discardableResult
    public func saveSharedSession(_ data: Data) -> Bool {
        guard let group = Self.sharedAccessGroup else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.sharedSessionAccount,
            kSecAttrAccessGroup as String: group
        ]
        let status = Self.upsert(query: base, data: data)
        if status != errSecSuccess {
            keychainLog.error("Shared session write failed (status \(status))")
        }
        return status == errSecSuccess
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

    /// `true` once no shared session remains — deleted now, or already absent.
    @discardableResult
    public func deleteSharedSession() -> Bool {
        guard let group = Self.sharedAccessGroup else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.sharedSessionAccount,
            kSecAttrAccessGroup as String: group
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            keychainLog.error("Shared session delete failed (status \(status))")
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private access-group migration

    /// Every app-private account — everything this type stores except
    /// `extension_session`.
    static let privateAccounts = [
        "access_token", "server_url", "user_session", "device_id",
        serversAccount, activeServerIdAccount, trustedCertificatesAccount,
        parentalLockAccount,
    ]

    private static let privateGroupMigratedKey = "keychain.privateAccessGroup.migrated"

    /// Moves the app-private items out of the shared extension group, where
    /// every build before 2026-09-22 wrote them (see the type's RULE).
    ///
    /// `SecItemUpdate` on `kSecAttrAccessGroup` MOVES an item — nothing is
    /// deleted, nothing is re-added — so a failure leaves the item exactly where
    /// it was and still readable (reads name no group, so they search them all).
    /// One-shot via a flag set only when every move succeeded; a partial failure
    /// (a locked Keychain, a profile missing the new group) retries next launch.
    public func migrateToPrivateAccessGroupIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.privateGroupMigratedKey),
              let shared = Self.sharedAccessGroup,
              let privateGroup = Self.privateAccessGroup else { return }
        var allSucceeded = true
        for account in Self.privateAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.serviceName,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: shared
            ]
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecAttrAccessGroup as String: privateGroup] as CFDictionary
            )
            switch status {
            case errSecSuccess, errSecItemNotFound:
                continue
            case errSecDuplicateItem:
                // A private copy already exists and is the one group-less
                // writes update: the shared one is the stale leftover. If it
                // cannot be removed it stays readable by the extensions, so the
                // migration must run again rather than latch.
                let deleted = SecItemDelete(query as CFDictionary)
                if deleted != errSecSuccess && deleted != errSecItemNotFound {
                    allSucceeded = false
                    keychainLog.error("Removing the shared copy of \(account, privacy: .public) failed (status \(deleted))")
                }
            default:
                allSucceeded = false
                keychainLog.error("Moving \(account, privacy: .public) to the private group failed (status \(status))")
            }
        }
        if allSucceeded {
            UserDefaults.standard.set(true, forKey: Self.privateGroupMigratedKey)
        }
    }

    // MARK: - Accessibility migration

    /// Re-saves already-stored items under the new `AfterFirstUnlock`
    /// accessibility class. Idempotent (UserDefaults flag) and lossless:
    /// `save()` updates in place, and we only re-write items that read back
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

    /// Moves the persistent device id to the new accessibility class, in place
    /// (the old delete-then-add could lose it and fragment the device identity).
    /// Best-effort: `cachedDeviceID` keeps the id stable within a run anyway.
    private static func migrateDeviceIDAccessibility() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "device_id"
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecAttrAccessible as String: itemAccessibility] as CFDictionary
        )
        if status != errSecSuccess && status != errSecItemNotFound {
            keychainLog.error("device-id accessibility update failed (status \(status))")
        }
    }

    // MARK: - Clear All

    /// Clears the ACTIVE session mirror only.
    ///
    /// **Deliberately scoped to the legacy trio**: `servers` /
    /// `active_server_id` must survive a plain logout, otherwise signing out of
    /// one server would silently delete every other registered server.
    /// `AppState.logout(reason:)` is what strips the token from the active
    /// `ServerEntry` (keeping the entry itself, tokenless).
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

        // No Keychain item yet — mint one. There used to be a migration from a
        // `UserDefaults["cinemax_device_id"]` default here; git history shows no
        // build ever WROTE that key (only this read and its removal, present
        // since the initial commit), so the branch was unreachable and was
        // deleted on 2026-09-10.
        let id = UUID().uuidString

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
            // Persisted-store write failed; the session cache above keeps the id
            // stable until the next launch retries. This must NOT trap: a keychain
            // write can legitimately fail (locked keychain at first unlock, or an
            // unsigned/entitlement-less build such as CI's CODE_SIGNING_ALLOWED=NO
            // test host → errSecMissingEntitlement -34018). A signed production
            // build never hits it; an `assertionFailure` here turned that tolerated
            // condition into a crash.
            keychainLog.error("device-id keychain write failed (status \(status)); using session-cached id")
        }
        return id
    }

    // MARK: - Private

    private func save(data: Data, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key
        ]
        let status = Self.upsert(query: query, data: data)
        guard status == errSecSuccess else {
            keychainLog.error("Keychain write of \(key, privacy: .public) failed (status \(status))")
            throw KeychainError.saveFailed(status)
        }
    }

    /// Writes `data` into the item `query` identifies: UPDATE in place when it
    /// exists, ADD otherwise. Never delete-then-add — a failed add after the
    /// delete would lose the value (see the type's RULE). The update also moves
    /// the item to the current accessibility class.
    private static func upsert(query: [String: Any], data: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: itemAccessibility
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add.merge(attributes) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil)
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
