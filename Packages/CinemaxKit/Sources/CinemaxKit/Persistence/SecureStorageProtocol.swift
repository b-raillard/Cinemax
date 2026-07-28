import Foundation

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

    /// Seeds the registry from the legacy single-server items. Idempotent and
    /// non-destructive. Default no-op so mocks need no change.
    func migrateToMultiServerIfNeeded()
}

public extension SecureStorageProtocol {
    func migrateAccessibilityIfNeeded() {}
    func migrateToMultiServerIfNeeded() {}
}

// MARK: - Conformance

extension KeychainService: SecureStorageProtocol {}
