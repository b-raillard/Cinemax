#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminApiKeysViewModel {
    var keys: [AuthenticationInfo] = []
    var isLoading = false
    var errorMessage: String?

    // Security-sensitive transient state.
    //
    // `revealedKeyIds` is intentionally a Set<Int> tied to `AuthenticationInfo.id`
    // — NOT the token itself — so the token value never appears as a dictionary
    // key, identifier, or hash input. The reveal state is also purely
    // in-memory and drops on view dismiss.
    var revealedKeyIds: Set<Int> = []

    var showCreateSheet = false
    var newAppName: String = ""
    var isCreating = false
    var createErrorMessage: String?

    /// Freshly created key — shown in a dedicated modal so the user can
    /// copy it before it visually joins the rest of the list. Still revealable
    /// later since Jellyfin returns tokens in `getKeys`, but we surface it
    /// once with a clear "copy now" prompt to encourage safe handling.
    var freshlyCreatedKey: AuthenticationInfo?

    var pendingRevoke: AuthenticationInfo?

    var isEmpty: Bool {
        !isLoading && errorMessage == nil && keys.isEmpty
    }

    // MARK: - Load

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = keys.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await apiClient.getApiKeys()
            // Filter revoked keys defensively — the server typically omits
            // them but we don't want to render stale entries if it doesn't.
            keys = fetched
                .filter { $0.dateRevoked == nil && ($0.isActive ?? true) }
                .sorted { ($0.dateCreated ?? .distantPast) > ($1.dateCreated ?? .distantPast) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Create

    /// Creates a key, refetches, and identifies the new one by subtracting
    /// the previous id set — avoids relying on dateCreated ordering in case
    /// two keys share a timestamp (unlikely but easy to defend against).
    func createKey(using apiClient: any APIClientProtocol) async -> Bool {
        let name = newAppName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        isCreating = true
        createErrorMessage = nil
        defer { isCreating = false }

        let previousIds = Set(keys.compactMap { $0.id })
        do {
            try await apiClient.createApiKey(app: name)
            await load(using: apiClient)
            freshlyCreatedKey = keys.first { id in
                guard let newId = id.id else { return false }
                return !previousIds.contains(newId)
            }
            newAppName = ""
            return true
        } catch {
            createErrorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Reveal toggle

    func isRevealed(_ key: AuthenticationInfo) -> Bool {
        guard let id = key.id else { return false }
        return revealedKeyIds.contains(id)
    }

    func toggleReveal(_ key: AuthenticationInfo) {
        guard let id = key.id else { return }
        if revealedKeyIds.contains(id) {
            revealedKeyIds.remove(id)
        } else {
            revealedKeyIds.insert(id)
        }
    }

    /// Clears all revealed states. Called by the screen on disappear so
    /// tokens aren't left displayed if the user navigates back and forth.
    func hideAll() {
        revealedKeyIds.removeAll()
    }

    // MARK: - Revoke

    func revoke(_ key: AuthenticationInfo, using apiClient: any APIClientProtocol) async -> Bool {
        guard let token = key.accessToken else { return false }
        do {
            try await apiClient.revokeApiKey(key: token)
            keys.removeAll { $0.id == key.id }
            // If we had this key revealed, drop its reveal state.
            if let id = key.id { revealedKeyIds.remove(id) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Helpers

    /// Masked presentation: first 4 + last 4 chars of the token, with dots
    /// in between. For short tokens (<16 chars, shouldn't happen but defensive)
    /// just shows dots — never the full value.
    func maskedDisplay(for key: AuthenticationInfo) -> String {
        guard let token = key.accessToken, token.count >= 16 else {
            return String(repeating: "•", count: 12)
        }
        let prefix = token.prefix(4)
        let suffix = token.suffix(4)
        return "\(prefix)••••••••\(suffix)"
    }
}
#endif
