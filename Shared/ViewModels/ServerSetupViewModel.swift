import Foundation
import Observation
import CinemaxKit

@MainActor @Observable
final class ServerSetupViewModel {
    var serverURL: String = ""
    var isConnecting = false
    var errorMessage: String?
    var serverInfo: ServerInfo?

    func connect(using appState: AppState) async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter a server address."
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
            errorMessage = "Invalid URL format."
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
            errorMessage = "Unable to connect: \(error.localizedDescription)"
        }

        isConnecting = false
    }
}
