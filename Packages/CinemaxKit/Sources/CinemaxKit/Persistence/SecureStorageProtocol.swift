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

    func clearAll()

    /// Upgrades stored items to a cold-boot-readable accessibility class.
    /// Default no-op so mocks need no change.
    func migrateAccessibilityIfNeeded()
}

public extension SecureStorageProtocol {
    func migrateAccessibilityIfNeeded() {}
}

// MARK: - Conformance

extension KeychainService: SecureStorageProtocol {}
