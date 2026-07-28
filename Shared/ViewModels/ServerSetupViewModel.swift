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

        // Single source of truth for the canonical spelling of a server URL:
        // the same normalizer the registry dedups on, so the URL we connect to
        // and the URL we store as a `ServerEntry` can never disagree. It keeps
        // the historical behavior of this screen (prepend `https://` when no
        // scheme is typed, reject anything that isn't a usable http(s) URL) and
        // additionally drops the default port / trailing slash / query.
        guard let url = ServerURLNormalizer.normalize(trimmed) else {
            errorMessage = loc.localized("server.invalidURL")
            return
        }

        // Dedup, before any network call: a URL already registered **and still
        // holding a session** is a no-op to add — the user wants the servers
        // list, not a second card for the same server (any equivalent spelling
        // matches, the probe runs on the normalized URL).
        //
        // A registered-but-SIGNED-OUT entry is deliberately let through: that
        // is precisely the re-login path. Signing out of your only server keeps
        // its now-tokenless entry in the registry and drops you here, so
        // rejecting it would lock the user out of the app entirely.
        // `ServerRegistry.upsert` dedups on the normalized URL either way, so
        // no duplicate entry can be created by the permissive branch.
        if let existing = ServerRegistry.contains(url: url, in: appState.servers), existing.hasSession {
            errorMessage = loc.localized("server.alreadyAdded")
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
