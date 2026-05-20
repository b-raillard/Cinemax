import Foundation
import Observation
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "ServerSetup")

@MainActor @Observable
final class ServerSetupViewModel {
    var serverURL: String = ""
    var isConnecting = false
    var errorMessage: String?
    var serverInfo: ServerInfo?

    func connect(using appState: AppState, loc: LocalizationManager) async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = loc.localized("server.addressRequired")
            return
        }

        // Prepend https:// if no scheme
        var urlString = trimmed
        if !urlString.contains("://") {
            urlString = "https://\(urlString)"
        }

        guard let url = URL(string: urlString),
              let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = loc.localized("server.invalidURL")
            return
        }

        isConnecting = true
        errorMessage = nil

        do {
            let info = try await appState.apiClient.connectToServer(url: url)
            try appState.keychain.saveServerURL(url)
            serverInfo = info
            appState.serverURL = url
            appState.serverInfo = info
            appState.hasServer = true
        } catch {
            logger.error("Server connect failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = loc.localized("server.connectFailed")
        }

        isConnecting = false
    }
}
