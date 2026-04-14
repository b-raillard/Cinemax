import Foundation
import Observation
import CinemaxKit

@MainActor @Observable
final class LoginViewModel {
    var username: String = ""
    var password: String = ""
    var isAuthenticating = false
    var errorMessage: String?
    var showSuccess = false

    func authenticate(using appState: AppState) async {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter your username."
            return
        }

        isAuthenticating = true
        errorMessage = nil

        do {
            let session = try await appState.apiClient.authenticate(
                username: username,
                password: password
            )
            try appState.keychain.saveAccessToken(session.accessToken)
            try appState.keychain.saveUserSession(session)

            appState.accessToken = session.accessToken
            appState.currentUserId = session.userID

            password = ""
            showSuccess = true

            try? await Task.sleep(for: .seconds(1))

            appState.isAuthenticated = true
        } catch {
            errorMessage = "Authentication failed: \(error.localizedDescription)"
        }

        isAuthenticating = false
    }
}
