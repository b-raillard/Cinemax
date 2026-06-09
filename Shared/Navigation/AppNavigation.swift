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
    // Documented exemption from the "@Observable properties must NOT carry
    // didSet" RULE: that rule targets persistence side effects on collections
    // of Codable value types (lost re-renders). This didSet only re-derives a
    // sibling stored property from a scalar URL — no persistence, no
    // observation-delivery dependency.
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

        // Wire lazy session-expiry recovery. The callback is `@Sendable` and
        // called from whatever actor the failing API call ran on, so it can
        // NOT capture `self` (a `@MainActor`-isolated reference). Bridge
        // through `NotificationCenter` — `AppNavigation` listens on MainActor
        // and runs `logout()` + the toast.
        apiClient.setOnUnauthorized {
            NotificationCenter.default.post(name: .cinemaxSessionExpired, object: nil)
        }
    }

    // Stored so it is only rebuilt when serverURL changes, not on every access.
    var imageBuilder = ImageURLBuilder(serverURL: AppState.placeholderServerURL)

    var imageServerURL: URL { serverURL ?? Self.placeholderServerURL }

    /// Hydrates auth state from the keychain. Network probes (server info,
    /// admin flag) are dispatched in the background so the UI doesn't wait
    /// on them — important when the user launches the app offline, where
    /// each probe would otherwise eat a request timeout before the launch
    /// screen disappears.
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

        // Non-blocking: kick the server-info + admin-policy fetches behind the
        // launch transition. They populate `serverInfo` / `isAdministrator`
        // when (and if) they succeed; failures are non-fatal and leave the
        // user authenticated with last-known values.
        Task { [weak self] in
            guard let self else { return }
            if let info = try? await self.apiClient.fetchServerInfo() {
                self.serverInfo = info
            }
            await self.refreshCurrentUser()
        }
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

    /// Users eligible for the quick-switch surfaces (`UserSwitchSheet` grid +
    /// tvOS Settings profile section). Single source of the visibility rule:
    /// `getUsers()` is admin-only (guaranteed 401 for regular accounts — skip
    /// it), accounts flagged "Hide from login screens" are filtered out, and
    /// when the filtered admin list is empty we fall through to
    /// `getPublicUsers()` rather than showing a misleading empty state.
    func fetchSwitchableUsers() async -> [UserDto] {
        if isAdministrator,
           let fetched = try? await apiClient.getUsers() {
            // The signed-in user stays visible even when their own account is
            // flagged hidden (admins commonly hide their account from login
            // screens — their profile tile must not vanish from Settings).
            let visible = fetched.filter { $0.policy?.isHidden != true || $0.id == currentUserId }
            if !visible.isEmpty { return visible }
        }
        return (try? await apiClient.getPublicUsers()) ?? []
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
    @State private var network = NetworkMonitor()
    @State private var menuConfig = MenuConfigStore()
    @State private var settingsNav = SettingsNavCoordinator()
    #if os(iOS)
    @State private var downloads = DownloadManager()
    #endif
    @State private var hasCheckedSession = false
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(SettingsKey.motionEffects) private var motionEffects: Bool = SettingsKey.Default.motionEffects

    /// SwiftUI may recreate the root `AppNavigation` struct on scene events;
    /// guard the one-time `ImagePipeline.shared` replacement so we don't throw
    /// away the in-memory `ImageCache` (and orphan in-flight decodes) on every
    /// recreation.
    ///
    /// The in-memory cost limit is bumped from Nuke's ~100 MB default to 256 MB
    /// because tvOS 4K backdrops decode to 4–8 MB each — the default evicts
    /// mid-render when scrolling library / detail screens.
    private static let configurePipeline: Void = {
        var config = ImagePipeline.Configuration.withDataCache(
            name: "com.cinemax.images",
            sizeLimit: 500 * 1024 * 1024 // 500 MB disk cache
        )
        let memoryCache = ImageCache()
        memoryCache.costLimit = 256 * 1024 * 1024 // 256 MB decoded images
        config.imageCache = memoryCache
        ImagePipeline.shared = ImagePipeline(configuration: config)
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
        .environment(network)
        .environment(menuConfig)
        .environment(settingsNav)
        #if os(iOS)
        .environment(downloads)
        #endif
        .environment(\.motionEffectsEnabled, motionEffects)
        // Respect the user's OS Dynamic Type setting while capping at a size
        // that won't collapse layouts (hero titles, tab bar). The app also has
        // its own `uiScale` in Settings > Interface > Font Size for finer control.
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .preferredColorScheme(themeManager.colorScheme)
        .task {
            await appState.restoreSession()
            hasCheckedSession = true
            menuConfig.attach(apiClient: appState.apiClient, userId: appState.currentUserId)
            // Pre-load views if the user is in library mode so the tabs
            // render with library names from first frame after launch.
            if menuConfig.mode == .custom && menuConfig.customKind == .library {
                await menuConfig.refreshAvailableViews()
            }
            #if os(iOS)
            downloads.attach(apiClient: appState.apiClient, userId: appState.currentUserId)
            #endif
            // Decide once, in the background, whether this server needs the
            // loopback stream proxy (dual-stack host with a black-holed IPv6
            // that libVLC would stall on). Non-blocking; cached for the session.
            StreamTransportPolicy.shared.configure(serverURL: appState.serverURL)
        }
        .onChange(of: appState.currentUserId) { oldId, newId in
            menuConfig.attach(apiClient: appState.apiClient, userId: newId)
            // Skip the cold-launch transition (`nil → some`) — `.task`
            // already owns that case and would otherwise double-fire the
            // refresh. Only refresh on a *genuine* user switch.
            if let oldId, oldId != newId,
               menuConfig.mode == .custom && menuConfig.customKind == .library {
                Task { await menuConfig.refreshAvailableViews() }
            }
            #if os(iOS)
            // Re-attach when the active user changes (login, quick switch).
            // The manager caches `userId` for queued-task negotiation, so it
            // needs to know about the swap.
            downloads.attach(apiClient: appState.apiClient, userId: newId)
            #endif
        }
        .onChange(of: appState.serverURL) { old, new in
            // Library view IDs are server-scoped. Invalidate the cached menu
            // entries only when switching to a *different* concrete server
            // (both sides non-nil and not equal). Plain logouts (URL → nil)
            // keep the cache so re-logging into the same server preserves
            // the user's custom tab arrangement.
            if let old, let new, old != new {
                menuConfig.invalidateViews()
            }
            // Re-decide stream transport for the new server (or clear on logout).
            StreamTransportPolicy.shared.configure(serverURL: new)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                NotificationCenter.default.post(name: .cinemaxDidEnterBackground, object: nil)
            } else if newPhase == .active {
                // Network conditions may have changed while backgrounded —
                // re-evaluate whether the proxy is needed for this server.
                StreamTransportPolicy.shared.refresh()
            }
        }
        .onChange(of: network.isOnline) { _, online in
            // Connectivity flipped (e.g. Wi-Fi ⇄ cellular) — IPv6 reachability
            // is per-network, so re-run the transport probe.
            if online { StreamTransportPolicy.shared.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxSessionExpired)) { _ in
            // Lazy 401 recovery — fired by any API call that surfaces an HTTP
            // 401 (token expired, revoked, or password reset elsewhere).
            // Idempotent: `logout()` is safe to call repeatedly. The toast
            // queue replaces older messages, so concurrent fires collapse to
            // a single visible "session expired" pill.
            guard appState.isAuthenticated else { return }
            appState.logout()
            toasts.error(loc.localized("session.expired"))
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
    /// Posted by the API client when any session-scoped call returns HTTP 401.
    /// `AppNavigation` observes this on MainActor and runs the logout + toast.
    /// Cross-actor bridge: the API callback runs from a non-MainActor context
    /// and cannot capture MainActor state directly.
    static let cinemaxSessionExpired = Notification.Name("cinemaxSessionExpired")
}

private extension AppNavigation {
    var launchScreen: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            LoadingStateView()
        }
    }
}
