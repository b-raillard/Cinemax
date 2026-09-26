#if os(iOS)
import Foundation
import Observation
import CinemaxKit
import JellyfinAPI

@MainActor @Observable
final class AdminApiKeysViewModel {
    var keys: [AuthenticationInfo] = []
    /// Starts TRUE: the screen's `.task` loads on first appearance, and a
    /// `false` start drew the « Aucun… » empty state for a frame before the
    /// spinner replaced it.
    var isLoading = true
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

    func load(using apiClient: any AdminAPI, loc: LocalizationManager) async {
        isLoading = keys.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            keys = Self.listable(try await apiClient.getApiKeys())
            // `listable` renumbers the keys, so a reveal state from the
            // previous list could now point at a different key.
            revealedKeyIds.removeAll()
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
        }
    }

    /// Turns the server's answer into what the list can show and address.
    ///
    /// Jellyfin builds every API key from three fields only (`AppName`,
    /// `AccessToken`, `DateCreated` — `AuthenticationManager.GetApiKeys`, 10.9
    /// through 12.0), so the rest of `AuthenticationInfo` arrives at its C#
    /// default: **`IsActive` is `false` and `Id` is `0` on EVERY key.** Filtering
    /// on `isActive` therefore dropped the whole list (the screen always read
    /// « Aucune clé API »), and keying the rows on `id` would have made every
    /// key the same row — revealing one would reveal them all. So `isActive` is
    /// ignored (a revoked key is deleted server-side, not flagged) and each key
    /// is given a LOCAL id: its position in this list, which `ForEach`, the
    /// reveal set and the revoke path all key on. The token itself is never
    /// used as an identifier.
    static func listable(_ fetched: [AuthenticationInfo]) -> [AuthenticationInfo] {
        fetched
            .filter { $0.dateRevoked == nil && !($0.accessToken ?? "").isEmpty }
            .sorted {
                let lhs = $0.dateCreated ?? .distantPast
                let rhs = $1.dateCreated ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                return ($0.appName ?? "") < ($1.appName ?? "")
            }
            .enumerated()
            .map { index, key in
                var key = key
                key.id = index
                return key
            }
    }

    // MARK: - Create

    /// Creates a key, refetches, and identifies the new one as the token that
    /// was not there before — the server hands out no usable id (see
    /// `listable`). Compared in memory only, never stored or hashed.
    func createKey(using apiClient: any AdminAPI, loc: LocalizationManager) async -> Bool {
        let name = newAppName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        isCreating = true
        createErrorMessage = nil
        defer { isCreating = false }

        let previousTokens = keys.compactMap(\.accessToken)
        do {
            try await apiClient.createApiKey(app: name)
            await load(using: apiClient, loc: loc)
            freshlyCreatedKey = keys.first { key in
                guard let token = key.accessToken else { return false }
                return !previousTokens.contains(token)
            }
            newAppName = ""
            return true
        } catch {
            createErrorMessage = loc.userFacingMessage(for: error)
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

    func revoke(_ key: AuthenticationInfo, using apiClient: any AdminAPI, loc: LocalizationManager) async -> Bool {
        guard let token = key.accessToken else { return false }
        do {
            try await apiClient.revokeApiKey(key: token)
            keys.removeAll { $0.id == key.id }
            // If we had this key revealed, drop its reveal state.
            if let id = key.id { revealedKeyIds.remove(id) }
            return true
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
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
