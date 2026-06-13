import Foundation
import Observation
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "QuickConnect")

/// Drives the Quick Connect *authorize* sheet (Settings → Account) — the
/// signed-in counterpart to `LoginViewModel`'s initiate/poll loop. The user
/// types the six-character code another device is showing on its login screen;
/// approving it grants that device a session for the current user.
@MainActor @Observable
final class QuickConnectAuthorizeViewModel {
    /// Six-digit code the user types. Kept sanitized via `sanitize(_:)`.
    var code: String = ""
    var isSubmitting = false
    var errorMessage: String?
    /// Flips `true` on a successful authorization — the sheet swaps to its
    /// confirmation state and auto-dismisses.
    var didAuthorize = false

    static let codeLength = 6

    var canSubmit: Bool {
        code.count == Self.codeLength && !isSubmitting
    }

    /// Strips everything but digits and caps the length, so paste / autofill
    /// can't smuggle in letters or an over-long string. Bound to the field's
    /// setter so the displayed value is always a clean ≤6-digit run.
    func sanitize(_ raw: String) {
        code = String(raw.filter(\.isNumber).prefix(Self.codeLength))
    }

    func submit(using appState: AppState, loc: LocalizationManager) async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            let authorized = try await appState.apiClient.authorizeQuickConnect(code: code)
            if authorized {
                didAuthorize = true
            } else {
                // The server accepted the request but rejected the code itself
                // (unknown or already expired) — a clean `false`, not an error.
                errorMessage = loc.localized("quickConnect.authorize.invalidCode")
            }
        } catch {
            logger.error("Quick Connect authorize failed: \(error.localizedDescription, privacy: .public)")
            // A thrown error here is a transport/auth failure (a bad code comes
            // back as `false` above), so map it rather than blaming the code.
            errorMessage = loc.userFacingMessage(for: error)
        }
        isSubmitting = false
    }
}
