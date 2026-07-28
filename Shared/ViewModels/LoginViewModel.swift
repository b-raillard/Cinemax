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

    /// Consecutive failed polls tolerated before the flow gives up. At the ~3 s
    /// cadence that is ~15 s of *continuous* failure — long enough to ride out a
    /// Wi-Fi blip on an Apple TV (this flow's primary platform, where the code is
    /// on screen and the user is waiting on another device) without leaving a
    /// genuinely unreachable server polling forever. Any successful poll resets it.
    ///
    /// `nonisolated` (Sendable `Int`) so `@Sendable` closures — the test mock's
    /// poll handler — can read it without crossing the main actor; see the
    /// documented escape hatch in CLAUDE.md.
    nonisolated static let quickConnectFailureBudget = 5

    /// Poll cadence. Stored rather than a constant purely so tests can shrink it;
    /// every production path uses the 3 s default.
    var quickConnectPollInterval: Duration = .seconds(3)

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
        let pollInterval = quickConnectPollInterval
        quickConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await appState.apiClient.initiateQuickConnect()
                self.quickConnectCode = request.code

                // Poll ~every 3s until authorized or cancelled. The server
                // expires unapproved requests on its own; we stop on cancel.
                //
                // A transient poll failure must NOT end the flow: the code stays
                // on screen, so an exited Task looks identical to "waiting" while
                // approval can never complete. Each poll catches its own error and
                // keeps going until `quickConnectFailureBudget` CONSECUTIVE
                // failures — only then does it rethrow into the terminal state.
                var consecutiveFailures = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: pollInterval)
                    if Task.isCancelled { return }
                    let authorized: Bool
                    do {
                        authorized = try await appState.apiClient.quickConnectAuthorized(secret: request.secret)
                    } catch is CancellationError {
                        return
                    } catch {
                        consecutiveFailures += 1
                        logger.error("Quick Connect poll failed (\(consecutiveFailures, privacy: .public)/\(Self.quickConnectFailureBudget, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                        if consecutiveFailures >= Self.quickConnectFailureBudget { throw error }
                        continue   // re-checks Task.isCancelled at the loop head
                    }
                    consecutiveFailures = 0
                    guard authorized else { continue }

                    let session = try await appState.apiClient.authenticateWithQuickConnect(secret: request.secret)
                    await self.completeSession(session, using: appState)
                    return
                }
            } catch is CancellationError {
                // User dismissed the sheet — nothing to surface.
            } catch {
                // A cancelled URLSession surfaces as `URLError.cancelled`, not
                // `CancellationError` — never surface an error the user caused by
                // dismissing the sheet.
                guard !Task.isCancelled else { return }
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
