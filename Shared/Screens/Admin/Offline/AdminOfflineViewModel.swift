#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Admin → "Fonction hors ligne". Edits each user's
/// `UserPolicy.enableContentDownloading` — the native Jellyfin "Allow media
/// downloads" policy, so the Jellyfin web dashboard stays in sync with what
/// this screen shows. Jellyfin's server-side default is ON for every account
/// (not configurable without a plugin), hence the bulk enable/disable
/// helpers. Explicit save per the admin-editor rule — only *changed* values
/// are sent.
@MainActor @Observable
final class AdminOfflineViewModel {
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    /// Users sorted by display name; drives the per-user rows.
    var users: [UserDto] = []
    /// Edited per-user flags keyed by user id. Compared against
    /// `originalPerUser` for dirty tracking and minimal policy writes.
    var perUser: [String: Bool] = [:]
    private var originalPerUser: [String: Bool] = [:]

    var isDirty: Bool { perUser != originalPerUser }

    /// Drives the empty state (loaded, no error, no users). Mirrors
    /// `AdminUsersViewModel.isEmpty` so an empty result renders a proper empty
    /// state instead of a blank screen — the previous `hasLoaded` conflated
    /// "load finished" with "has users", which left an unhandled black-screen
    /// hole whenever `getUsers()` came back empty.
    var isEmpty: Bool { !isLoading && errorMessage == nil && users.isEmpty }

    func load(using apiClient: any APIClientProtocol, loc: LocalizationManager) async {
        isLoading = true
        errorMessage = nil
        do {
            let fetchedUsers = try await apiClient.getUsers()
            users = fetchedUsers.sorted {
                ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
            }
            var flags: [String: Bool] = [:]
            for user in fetchedUsers {
                guard let id = user.id else { continue }
                // `?? true` mirrors Jellyfin's policy default.
                flags[id] = user.policy?.enableContentDownloading ?? true
            }
            perUser = flags
            originalPerUser = flags
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
        }
        isLoading = false
    }

    func toggleUser(_ userId: String) {
        perUser[userId] = !(perUser[userId] ?? true)
    }

    /// Bulk edit (local only — still goes through explicit save). The
    /// pragmatic answer to Jellyfin's on-by-default policy: one tap to turn
    /// the feature off for everyone, then re-enable selected accounts.
    func setAll(_ enabled: Bool) {
        for key in perUser.keys {
            perUser[key] = enabled
        }
    }

    /// Saves only what changed. Originals advance per successful write, so a
    /// mid-loop failure leaves the already-saved rows clean and only the
    /// still-failing edits dirty for retry.
    func save(using apiClient: any APIClientProtocol, loc: LocalizationManager) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            for user in users {
                guard let id = user.id,
                      let newValue = perUser[id],
                      newValue != originalPerUser[id] else { continue }
                // Full-policy write (the endpoint replaces the policy). Blank
                // provider ids on a nil policy keep server defaults — same
                // convention as `AdminUserDetailScreen.setPolicy`.
                var policy = user.policy ?? UserPolicy(
                    authenticationProviderID: "",
                    passwordResetProviderID: ""
                )
                policy.enableContentDownloading = newValue
                try await apiClient.updateUserPolicy(id: id, policy: policy)
                originalPerUser[id] = newValue
            }
            return true
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
            return false
        }
    }
}
#endif
