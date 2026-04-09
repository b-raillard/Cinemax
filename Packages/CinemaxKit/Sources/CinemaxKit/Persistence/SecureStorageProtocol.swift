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
}

// MARK: - Conformance

extension KeychainService: SecureStorageProtocol {}
