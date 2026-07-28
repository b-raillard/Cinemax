import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cinemax", category: "Storage")

/// Abstraction over KeychainService enabling mock injection for testing.
public protocol SecureStorageProtocol: Sendable {
    func saveAccessToken(_ token: String) throws
    func getAccessToken() -> String?
    func deleteAccessToken()

    func saveServerURL(_ url: URL) throws
    func getServerURL() -> URL?
    func deleteServerURL()

    func saveUserSession(_ session: UserSession) throws
    func getUserSession() -> UserSession?
    func deleteUserSession()

    /// Clears the ACTIVE session mirror only — never the multi-server registry.
    /// See the RULE on `KeychainService`.
    func clearAll()

    // MARK: - Multi-server registry

    // Declared WITHOUT default implementations on purpose: the compiler must
    // flag any conformer (i.e. the test `MockKeychain`) that forgets to back
    // the registry, since a silently-empty registry looks exactly like a fresh
    // install and would mask a broken migration.
    func getServers() -> [ServerEntry]
    func saveServers(_ entries: [ServerEntry]) throws
    func getActiveServerId() -> String?
    func saveActiveServerId(_ id: String?)

    /// Upgrades stored items to a cold-boot-readable accessibility class.
    /// Default no-op so mocks need no change.
    func migrateAccessibilityIfNeeded()
}

public extension SecureStorageProtocol {
    func migrateAccessibilityIfNeeded() {}

    /// Seeds the multi-server registry from the legacy single-server items.
    ///
    /// **RULE — this lives in the protocol extension and MUST NOT be overridden
    /// by a conformer.** It only needs protocol members, so `KeychainService`
    /// and the test `MockKeychain` run the exact same code — a per-conformer
    /// copy would mean the migration tests exercise the mock's re-implementation
    /// rather than production behavior.
    ///
    /// One-shot, idempotent and **non-destructive**: the legacy trio survives
    /// untouched (see the RULE on `KeychainService`). Idempotence is keyed on
    /// "the list is non-empty", never a flag — a locked Keychain at first launch
    /// simply retries next launch instead of latching against an empty store.
    func migrateToMultiServerIfNeeded() {
        guard getServers().isEmpty else { return }              // already migrated
        guard let entry = ServerEntry.migrated(
            serverURL: getServerURL(),                          // nil ⇒ fresh install / no server
            session: getUserSession(),
            accessToken: getAccessToken()
        ) else { return }
        do {
            try saveServers([entry])
        } catch {
            // Next launch retries: the guard above still sees an empty list.
            logger.error("Multi-server migration failed to save the registry: \(error.localizedDescription, privacy: .public)")
            return
        }
        saveActiveServerId(entry.id)
    }
}

// MARK: - Conformance

extension KeychainService: SecureStorageProtocol {}
