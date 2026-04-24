import SwiftUI
import CinemaxKit
import Nuke
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AppState {
    /// Placeholder used before a real server is configured. `URL(string:)` is Optional
    /// so a force unwrap here would crash on a malformed literal — a static URL built
    /// from components is infallible and keeps the rest of the code crash-free.
    static let placeholderServerURL: URL = {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    var isAuthenticated = false
    var hasServer = false
    var serverURL: URL? {
        didSet { imageBuilder = ImageURLBuilder(serverURL: serverURL ?? Self.placeholderServerURL) }
    }
    var serverInfo: ServerInfo?
    var currentUserId: String?
    var accessToken: String?

    /// Full `UserDto` for the signed-in user. Hydrated by `refreshCurrentUser()`
    /// after session restore / login / user switch. Screens that need the
    /// policy or primary image tag read from here rather than re-fetching.
    var currentUser: UserDto?

    /// Cached admin flag — single source of truth for gating admin surfaces
    /// (Settings categories, "Edit metadata" button on MediaDetail). Always
    /// kept in sync with `currentUser?.policy?.isAdministrator`. Derived so
    /// that non-admins never *see* admin UI in the first place; the server
    /// still enforces authorization on every endpoint.
    private(set) var isAdministrator: Bool = false

    let apiClient: any APIClientProtocol
    let keychain: any SecureStorageProtocol

    init(
        apiClient: any APIClientProtocol = JellyfinAPIClient(),
        keychain: any SecureStorageProtocol = KeychainService()
    ) {
        self.apiClient = apiClient
        self.keychain = keychain
    }

    // Stored so it is only rebuilt when serverURL changes, not on every access.
    var imageBuilder = ImageURLBuilder(serverURL: AppState.placeholderServerURL)

    var imageServerURL: URL { serverURL ?? Self.placeholderServerURL }

    func restoreSession() async {
        guard let serverURL = keychain.getServerURL(),
              let session = keychain.getUserSession() else {
            return
        }

        self.serverURL = serverURL   // triggers imageBuilder didSet
        self.hasServer = true
        self.accessToken = session.accessToken
        self.currentUserId = session.userID
        self.isAuthenticated = true

        // Reconnect client with stored token
        apiClient.reconnect(url: serverURL, accessToken: session.accessToken)
        // Re-apply the user's Privacy & Security content-rating cap, since a
        // `reconnect` rebuilds the Jellyfin client and resets its in-memory state.
        let storedAge = UserDefaults.standard.integer(forKey: SettingsKey.privacyMaxContentAge)
        apiClient.applyContentRatingLimit(maxAge: storedAge)

        // Fetch server info without replacing the authenticated client
        do {
            let info = try await apiClient.fetchServerInfo()
            self.serverInfo = info
        } catch {
            // Server may be temporarily unreachable, keep stored state
        }

        await refreshCurrentUser()
    }

    /// Refreshes `currentUser` + `isAdministrator` from the server. Call on
    /// login success, user switch, and session restore. Failures leave the
    /// cached values untouched (we prefer a stale admin flag over kicking a
    /// real admin out of the admin UI during a blip). `isAdministrator` only
    /// flips to `false` on an explicit successful fetch that says so, or on
    /// logout.
    func refreshCurrentUser() async {
        guard let id = currentUserId else {
            currentUser = nil
            isAdministrator = false
            return
        }
        do {
            let user = try await apiClient.getUserByID(id: id)
            currentUser = user
            isAdministrator = user.policy?.isAdministrator ?? false
        } catch {
            // Network blip — keep last-known values.
        }
    }

    /// Returns the user from `LoginScreen` to `ServerSetupScreen` so they can pick a different
    /// server. Only clears server-side state — auth state is already empty at that point in
    /// the flow, so there's nothing user-related to wipe.
    func disconnectServer() {
        keychain.deleteServerURL()
        hasServer = false
        serverURL = nil
        serverInfo = nil
    }

    func logout() {
        keychain.clearAll()
        isAuthenticated = false
        hasServer = false
        serverURL = nil
        serverInfo = nil
        currentUserId = nil
        accessToken = nil
        currentUser = nil
        isAdministrator = false
    }
}

struct AppNavigation: View {
    @State private var appState = AppState()
    @State private var themeManager = ThemeManager()
    @State private var loc = LocalizationManager()
    @State private var toasts = ToastCenter()
    @State private var hasCheckedSession = false
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(SettingsKey.motionEffects) private var motionEffects: Bool = SettingsKey.Default.motionEffects

    /// SwiftUI may recreate the root `AppNavigation` struct on scene events;
    /// guard the one-time `ImagePipeline.shared` replacement so we don't throw
    /// away the in-memory `ImageCache` (and orphan in-flight decodes) on every
    /// recreation.
    private static let configurePipeline: Void = {
        ImagePipeline.shared = ImagePipeline(configuration: .withDataCache(
            name: "com.cinemax.images",
            sizeLimit: 500 * 1024 * 1024 // 500 MB disk cache
        ))
    }()

    init() {
        _ = Self.configurePipeline
    }

    var body: some View {
        ZStack {
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

            // Toasts overlay the entire app chrome (above tab bar / modals).
            ToastOverlay()
                .allowsHitTesting(toasts.current != nil)
        }
        .environment(appState)
        .environment(themeManager)
        .environment(loc)
        .environment(toasts)
        .environment(\.motionEffectsEnabled, motionEffects)
        // Respect the user's OS Dynamic Type setting while capping at a size
        // that won't collapse layouts (hero titles, tab bar). The app also has
        // its own `uiScale` in Settings > Interface > Font Size for finer control.
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .preferredColorScheme(themeManager.colorScheme)
        .task {
            await appState.restoreSession()
            hasCheckedSession = true
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                NotificationCenter.default.post(name: .cinemaxDidEnterBackground, object: nil)
            }
        }
        .onChange(of: motionEffects) { _, _ in
            // Restart/stop the rainbow accent animation task when the user
            // toggles Motion Effects — the task otherwise only re-checks the
            // flag on each tick.
            themeManager.motionEffectsDidChange()
        }
    }

}

extension Notification.Name {
    static let cinemaxDidEnterBackground = Notification.Name("cinemaxDidEnterBackground")
    /// Posted when the user taps "Refresh Catalogue" in Settings → Server.
    /// Home and Library observe this and reload their content (cache-busted).
    static let cinemaxShouldRefreshCatalogue = Notification.Name("cinemaxShouldRefreshCatalogue")
}

private extension AppNavigation {
    var launchScreen: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            LoadingStateView()
        }
    }
}
