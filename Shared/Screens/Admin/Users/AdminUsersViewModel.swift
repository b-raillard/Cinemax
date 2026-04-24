#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminUsersViewModel {
    var users: [UserDto] = []
    var isLoading = false
    var errorMessage: String?
    var showCreateUser = false
    var newUserName: String = ""
    var newUserPassword: String = ""
    var isCreating = false
    var createErrorMessage: String?

    var isEmpty: Bool {
        !isLoading && errorMessage == nil && users.isEmpty
    }

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = true
        errorMessage = nil
        do {
            users = try await apiClient.getUsers().sorted { ($0.name ?? "") < ($1.name ?? "") }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Creates a user and appends to the local list optimistically — avoids a
    /// second round-trip just to see the new row. Callers still tap into the
    /// detail screen for policy/library configuration.
    func createUser(using apiClient: any APIClientProtocol) async -> Bool {
        let name = newUserName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        isCreating = true
        createErrorMessage = nil
        defer { isCreating = false }
        do {
            let created = try await apiClient.createUserByName(
                name: name,
                password: newUserPassword.isEmpty ? nil : newUserPassword
            )
            users.append(created)
            users.sort { ($0.name ?? "") < ($1.name ?? "") }
            newUserName = ""
            newUserPassword = ""
            return true
        } catch {
            createErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Drops a deleted user from the local list — called by the detail screen
    /// after a successful delete to avoid a race with the grid's next reload.
    func removeLocally(userId: String) {
        users.removeAll { $0.id == userId }
    }
}
#endif
