import Foundation
import Security

public struct KeychainService: Sendable {
    private static let serviceName = "com.cinemax.jellyfin"

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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(saveQuery as CFDictionary, nil)
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
