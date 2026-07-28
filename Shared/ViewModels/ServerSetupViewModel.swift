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
        // holding a usable session** is a no-op to add — the user wants the
        // servers list, not a second card for the same server (any equivalent
        // spelling matches, the probe runs on the normalized URL).
        //
        // The gate is `hasUsableSession` (token AND user id), i.e. exactly what
        // `AppState.applyActiveServer` will accept. Anything the app would send
        // back to a login screen must NOT be refused here: signing out of your
        // only server keeps its now-credential-less entry in the registry and
        // drops you on this screen, so a broader gate would refuse the user's
        // own server and lock them out of the app entirely. The escape hatch
        // below ("My servers") covers the other direction — the user can reach
        // an existing entry instead of retyping it.
        // `ServerRegistry.upsert` dedups on the normalized URL regardless, so
        // the permissive branch still cannot create a duplicate entry.
        if let existing = ServerRegistry.contains(url: url, in: appState.servers),
           existing.hasUsableSession {
            errorMessage = loc.localized("server.alreadyAdded")
            return
        }

        isConnecting = true
        errorMessage = nil

        do {
            let info = try await appState.apiClient.connectToServer(url: url)
            // Legacy-mirror discipline: while ADDING a server the mirror still
            // describes the currently-active one, and the three items must stay
            // coherent. Writing `server_url` here would leave a kill-the-app
            // window where the mirror pairs the NEW url with the OLD token /
            // user session — next launch would then reconnect to server B with
            // server A's credentials. During an add the mirror is written in
            // one go by `LoginViewModel.completeSession`; in first-run mode
            // there is no other session to contradict, so the historical
            // early write is kept (nothing reads it until a session lands).
            if !appState.isAddingServer {
                try appState.keychain.saveServerURL(url)
            }
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
