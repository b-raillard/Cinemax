import Foundation
import Observation
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Auth")

@MainActor @Observable
final class LoginViewModel {
    var username: String = ""
    var password: String = ""
    var isAuthenticating = false
    var errorMessage: String?
    var showSuccess = false

    // MARK: - Quick Connect

    /// `true` once we've confirmed the server has Quick Connect enabled — the
    /// affordance stays hidden until then so we never offer a dead flow.
    var quickConnectEnabled = false
    /// Non-nil while a Quick Connect request is in flight; drives the sheet.
    var quickConnectCode: String?
    var quickConnectError: String?
    private var quickConnectTask: Task<Void, Never>?

    /// Probes Quick Connect availability once when the login screen appears.
    /// Silent on failure — a missing/old server just keeps the button hidden.
    func checkQuickConnect(using appState: AppState) async {
        quickConnectEnabled = (try? await appState.apiClient.isQuickConnectEnabled()) ?? false
    }

    /// Initiates a Quick Connect request and polls until the user approves the
    /// code from another signed-in session, then completes the session exactly
    /// like the password path.
    func startQuickConnect(using appState: AppState, loc: LocalizationManager) {
        quickConnectError = nil
        quickConnectTask?.cancel()
        quickConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await appState.apiClient.initiateQuickConnect()
                self.quickConnectCode = request.code

                // Poll ~every 3s until authorized or cancelled. The server
                // expires unapproved requests on its own; we stop on cancel.
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3))
                    if Task.isCancelled { return }
                    let authorized = try await appState.apiClient.quickConnectAuthorized(secret: request.secret)
                    guard authorized else { continue }

                    let session = try await appState.apiClient.authenticateWithQuickConnect(secret: request.secret)
                    await self.completeSession(session, using: appState)
                    return
                }
            } catch is CancellationError {
                // User dismissed the sheet — nothing to surface.
            } catch {
                logger.error("Quick Connect failed: \(error.localizedDescription, privacy: .public)")
                self.quickConnectError = loc.userFacingMessage(for: error)
            }
        }
    }

    func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnectCode = nil
        quickConnectError = nil
    }

    /// Shared post-authentication wiring used by both the password and Quick
    /// Connect paths: persist the session, hydrate the user, flip authenticated.
    private func completeSession(_ session: UserSession, using appState: AppState) async {
        do {
            try appState.keychain.saveAccessToken(session.accessToken)
            try appState.keychain.saveUserSession(session)
        } catch {
            logger.error("Saving session failed: \(error.localizedDescription, privacy: .public)")
        }
        appState.accessToken = session.accessToken
        appState.currentUserId = session.userID
        password = ""
        quickConnectCode = nil
        showSuccess = true
        await appState.refreshCurrentUser()
        // Brief dwell so the success animation reads before navigating away.
        // Skipped entirely when Motion Effects is off; capped at 0.4s otherwise
        // (was a fixed 1s that made every sign-in feel sluggish).
        let motionEffects = UserDefaults.standard.object(forKey: SettingsKey.motionEffects) as? Bool
            ?? SettingsKey.Default.motionEffects
        if motionEffects {
            try? await Task.sleep(for: .milliseconds(400))
        }
        appState.isAuthenticated = true
    }

    func authenticate(using appState: AppState, loc: LocalizationManager) async {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = loc.localized("login.usernameRequired")
            return
        }

        isAuthenticating = true
        errorMessage = nil

        do {
            let session = try await appState.apiClient.authenticate(
                username: username,
                password: password
            )
            // Hydrate admin flag + full user before flipping isAuthenticated,
            // so Settings (and the admin "Edit metadata" button on MediaDetail)
            // renders correctly from first paint instead of flashing non-admin
            // UI and then swapping.
            await completeSession(session, using: appState)
        } catch {
            logger.error("Authentication failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = loc.userFacingMessage(for: error)
        }

        isAuthenticating = false
    }
}
