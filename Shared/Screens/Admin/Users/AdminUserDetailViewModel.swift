#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Tabs mirroring the Jellyfin web admin user detail view.
enum AdminUserDetailTab: String, CaseIterable, Identifiable, Hashable {
    case profile
    case access
    case parental
    case password

    var id: String { rawValue }
}

@MainActor @Observable
final class AdminUserDetailViewModel {
    /// Edited working copy — compared against `originalUser` to decide `isDirty`.
    var editedUser: UserDto
    /// Snapshot taken at load time. Restored by `discard()`.
    private var originalUser: UserDto

    /// All media folders on the server. Populated async; the Access tab uses
    /// this to render the per-library grant checklist.
    var allMediaFolders: [BaseItemDto] = []
    var mediaFoldersLoaded: Bool = false
    var mediaFoldersError: String?

    // Password tab is saved on a distinct endpoint — tracked independently so
    // a policy save can't silently drop an un-submitted password change (and
    // vice versa).
    var newPassword: String = ""
    var confirmPassword: String = ""
    var resetPasswordAtNextLogin: Bool = false

    var selectedTab: AdminUserDetailTab = .profile
    var isSaving = false
    var isChangingPassword = false
    var isDeleting = false
    var errorMessage: String?
    var showDeleteConfirm = false
    var showResetPasswordConfirm = false

    init(user: UserDto) {
        self.editedUser = user
        self.originalUser = user
    }

    var userId: String? { editedUser.id ?? originalUser.id }

    /// Dirty if profile or policy has been mutated. Password tab is tracked
    /// separately via `passwordsMatch` / `canChangePassword`.
    var isDirty: Bool {
        editedUser != originalUser
    }

    var passwordsMatch: Bool {
        !newPassword.isEmpty && newPassword == confirmPassword
    }

    var canChangePassword: Bool {
        passwordsMatch && !isChangingPassword
    }

    /// Whether the user being edited is the signed-in admin. Locks down
    /// self-destructive affordances (delete, demote).
    func isSelf(currentUserId: String?) -> Bool {
        editedUser.id == currentUserId && editedUser.id != nil
    }

    // MARK: - Load

    func loadMediaFolders(using apiClient: any APIClientProtocol) async {
        do {
            let folders = try await apiClient.getMediaFolders()
            allMediaFolders = folders
            mediaFoldersError = nil
        } catch {
            mediaFoldersError = error.localizedDescription
        }
        mediaFoldersLoaded = true
    }

    // MARK: - Save

    /// Saves profile + policy atomically. If either half fails the UI surfaces
    /// the error but we don't roll back the server — `reload()` will re-sync
    /// if the caller triggers it. This matches Jellyfin web's behavior.
    func save(using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = editedUser.id else {
            errorMessage = "Missing user id"
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await apiClient.updateUser(id: id, user: editedUser)
            if let policy = editedUser.policy {
                try await apiClient.updateUserPolicy(id: id, policy: policy)
            }
            originalUser = editedUser
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Password

    func changePassword(using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = editedUser.id, passwordsMatch else { return false }
        isChangingPassword = true
        errorMessage = nil
        defer { isChangingPassword = false }
        do {
            try await apiClient.updateUserPassword(
                id: id,
                newPassword: newPassword,
                resetPassword: false
            )
            newPassword = ""
            confirmPassword = ""
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Clears the user's password outright. They'll be prompted to set a new
    /// one on their next login. Distinct from `changePassword` since the
    /// server uses the `resetPassword: true` flag to signal intent.
    func resetPassword(using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = editedUser.id else { return false }
        isChangingPassword = true
        errorMessage = nil
        defer { isChangingPassword = false }
        do {
            try await apiClient.updateUserPassword(
                id: id,
                newPassword: "",
                resetPassword: true
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Delete

    func deleteUser(using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = editedUser.id else { return false }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await apiClient.deleteUser(id: id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Helpers for policy editing

    /// Toggles a folder's presence in `policy.enabledFolders`. Used by the
    /// Access tab. Creates the array if nil.
    func toggleFolder(_ folderId: String) {
        var policy = editedUser.policy ?? UserPolicy(authenticationProviderID: "", enableCollectionManagement: false, enableLyricManagement: false, enableSubtitleManagement: false, passwordResetProviderID: "")
        var enabled = policy.enabledFolders ?? []
        if let idx = enabled.firstIndex(of: folderId) {
            enabled.remove(at: idx)
        } else {
            enabled.append(folderId)
        }
        policy.enabledFolders = enabled
        editedUser.policy = policy
    }

    func isFolderEnabled(_ folderId: String) -> Bool {
        editedUser.policy?.enabledFolders?.contains(folderId) ?? false
    }
}
#endif
