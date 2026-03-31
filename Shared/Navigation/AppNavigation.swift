import SwiftUI
import CinemaxKit

@MainActor @Observable
final class AppState {
    var isAuthenticated = false
    var hasServer = false
    var serverURL: URL?
    var serverInfo: ServerInfo?
    var currentUserId: String?
    var accessToken: String?

    let apiClient = JellyfinAPIClient()
    let keychain = KeychainService()

    func restoreSession() async {
        guard let serverURL = keychain.getServerURL(),
              let session = keychain.getUserSession() else {
            return
        }

        self.serverURL = serverURL
        self.hasServer = true
        self.accessToken = session.accessToken
        self.currentUserId = session.userID
        self.isAuthenticated = true

        // Reconnect client with stored token
        apiClient.reconnect(url: serverURL, accessToken: session.accessToken)

        // Fetch server info without replacing the authenticated client
        do {
            let info = try await apiClient.fetchServerInfo()
            self.serverInfo = info
        } catch {
            // Server may be temporarily unreachable, keep stored state
        }
    }

    func logout() {
        keychain.clearAll()
        isAuthenticated = false
        hasServer = false
        serverURL = nil
        serverInfo = nil
        currentUserId = nil
        accessToken = nil
    }
}

struct AppNavigation: View {
    @State private var appState = AppState()
    @State private var themeManager = ThemeManager()
    @State private var loc = LocalizationManager()
    @State private var hasCheckedSession = false

    #if os(tvOS)
    @AppStorage("motionEffects") private var motionEffects: Bool = true
    #endif

    var body: some View {
        Group {
            if !hasCheckedSession {
                launchScreen
            } else if !appState.hasServer {
                ServerSetupScreen()
            } else if !appState.isAuthenticated {
                LoginScreen()
            } else {
                MainTabView()
            }
        }
        .environment(appState)
        .environment(themeManager)
        .environment(loc)
        #if os(tvOS)
        .environment(\.motionEffectsEnabled, motionEffects)
        #endif
        .preferredColorScheme(themeManager.colorScheme)
        .task {
            await appState.restoreSession()
            hasCheckedSession = true
        }
    }

    private var launchScreen: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            ProgressView()
                .tint(CinemaColor.onSurfaceVariant)
                .scaleEffect(1.5)
        }
    }
}
