import Foundation
import JellyfinAPI

/// Outcome of an authoritative session re-check (`ServerAPI.validateSession`).
///
/// Drives the "confirm before logout" flow in `AppState`: only `.invalid`
/// (a server-confirmed revoked/expired token) tears the session down. A
/// transient network failure is `.indeterminate` and MUST keep the user
/// signed in — turning the box off and on must never disconnect the user.
public enum SessionValidity: Sendable, Equatable {
    /// 2xx — the token is still good.
    case valid
    /// Authoritative 401 — the token is genuinely revoked/expired.
    case invalid
    /// Network error / timeout / non-401 — cannot prove anything; keep session.
    case indeterminate
}

extension JellyfinAPIClient {
    /// Silently re-validates the current token against `GET /Users/Me`. Network
    /// app↔server only — no UI, no user interaction. Deliberately does NOT call
    /// `notifyIfUnauthorized` (it would re-enter the expiry flow that called us).
    public func validateSession() async -> SessionValidity {
        guard let client = getClient() else { return .indeterminate }
        do {
            _ = try await client.send(Paths.getCurrentUser)
            return .valid
        } catch {
            // Reuse the SAME precise classifier as the lazy-recovery path so
            // detection stays single-source-of-truth.
            return Self.isUnauthorized(error) ? .invalid : .indeterminate
        }
    }
}

// MARK: - Self-service account

public extension JellyfinAPIClient {
    /// Changes the signed-in user's own password.
    ///
    /// Sends `currentPw` alongside `newPw`: the server is entitled to demand
    /// proof of identity for a self-service change, and the admin reset path
    /// (`AdminAPI.updateUserPassword`) that omits it is a privilege boundary
    /// this must not borrow.
    func changeOwnPassword(userId: String, currentPassword: String, newPassword: String) async throws {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let body = UpdateUserPassword(currentPw: currentPassword, newPw: newPassword)
            _ = try await client.send(Paths.updateUserPassword(userID: userId, body))
        } catch {
            // Deliberately NOT `notifyIfUnauthorized`: a 401 here means the
            // CURRENT PASSWORD was wrong, not that the session expired. Routing
            // it to the session-expiry coordinator would log the user out for
            // mistyping their own password.
            throw error
        }
    }

    /// The server's known languages, for the preference pickers.
    ///
    /// Entries without a two-letter code are dropped: that code is exactly what
    /// `UserConfiguration` stores, so an entry that has none could be shown but
    /// never saved.
    func getCultures() async throws -> [ServerCulture] {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let response = try await client.send(Paths.getCultures)
            let cultures: [ServerCulture] = response.value.compactMap { culture -> ServerCulture? in
                guard let code = culture.twoLetterISOLanguageName, !code.isEmpty else { return nil }
                return ServerCulture(code: code, displayName: culture.displayName ?? code)
            }
            // The server returns several entries per language (regional
            // variants share a two-letter code); collapse them so the picker
            // does not list "French" three times.
            var unique: [ServerCulture] = []
            for culture in cultures where !unique.contains(where: { $0.code == culture.code }) {
                unique.append(culture)
            }
            return unique.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    func getUserConfiguration(userId: String) async throws -> UserPlaybackPreferences {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let user = try await client.send(Paths.getUserByID(userID: userId)).value
            let config = user.configuration
            return UserPlaybackPreferences(
                audioLanguage: config?.audioLanguagePreference,
                subtitleLanguage: config?.subtitleLanguagePreference,
                subtitleMode: config?.subtitleMode
                    .flatMap { UserPlaybackPreferences.SubtitleMode(rawValue: $0.rawValue) } ?? .defaultTrack
            )
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// Read-modify-write, deliberately: the server holds a dozen fields this app
    /// never shows, and posting a configuration built from scratch would reset
    /// every one of them to its default.
    func updateUserConfiguration(userId: String, preferences: UserPlaybackPreferences) async throws {
        do {
            guard let client = getClient() else { throw JellyfinError.notConnected }
            let user = try await client.send(Paths.getUserByID(userID: userId)).value
            var config = user.configuration ?? UserConfiguration()
            // Empty string, not nil, clears a preference server-side.
            config.audioLanguagePreference = preferences.audioLanguage ?? ""
            config.subtitleLanguagePreference = preferences.subtitleLanguage ?? ""
            config.subtitleMode = SubtitlePlaybackMode(rawValue: preferences.subtitleMode.rawValue)
            _ = try await client.send(Paths.updateUserConfiguration(userID: userId, config))
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }
}
