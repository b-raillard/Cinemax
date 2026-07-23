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

    /// Re-entrancy guard for the confirm-before-logout cycle. MainActor-confined
    /// (no lock needed) — every trigger hops to MainActor before reading it, so
    /// concurrent 401s / a foreground revalidation collapse into one probe.
    private var sessionRevalidationInFlight = false

    /// Reachability probe injected from the view layer (`NetworkMonitor.isOnline`).
    /// Wired once in `AppNavigation.task`. Defaults to `true` so unit tests that
    /// don't set it still exercise the validate path. Never log out while this
    /// reports offline — turning the box off/on must not disconnect the user.
    var isOnlineProvider: @MainActor () -> Bool = { true }

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

        // The items just read back successfully, so it's safe to upgrade them
        // to the cold-boot-readable accessibility class (idempotent, one-shot).
        keychain.migrateAccessibilityIfNeeded()

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
        // Single hook covering all three session-establishing paths (login,
        // user switch, restore): hand the session to the widget / Top Shelf
        // extensions via the App Group.
        ExtensionSessionBridge.publish(serverURL: serverURL, accessToken: accessToken, userId: currentUserId)
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

    /// Item id from a `cinemax://item/{id}` deep link (widget tap / Top Shelf
    /// selection). Consumed by `HomeScreen`, which pushes the detail screen
    /// and clears it; `MainTabView` switches to the Home tab when it appears.
    var pendingDeepLinkItemId: String?
    /// Tab id from a `cinemax://home` deep link (widget "See all" tile).
    /// Consumed by `MainTabView`, which switches tabs and clears it.
    var pendingDeepLinkTabId: String?

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "cinemax" else { return }
        switch url.host() {
        case "item":
            let id = url.lastPathComponent
            // Defense-in-depth: only dispatch a well-formed Jellyfin item id
            // (32-char undashed hex OR a canonical dashed GUID) so a malformed
            // deep link can't drive a lookup with attacker-controlled path text.
            guard Self.isValidItemId(id) else { return }
            pendingDeepLinkItemId = id
        case "home":
            pendingDeepLinkTabId = "home"
        default:
            break
        }
    }

    /// Accepts the two Jellyfin item-id forms only: a 32-character undashed hex
    /// string (`a1b2…`) or a canonical dashed GUID (`UUID(uuidString:)`).
    /// Everything else is rejected.
    static func isValidItemId(_ id: String) -> Bool {
        if id.count == 32, id.allSatisfy(\.isHexDigit) { return true }
        return UUID(uuidString: id) != nil
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
        ExtensionSessionBridge.publish(serverURL: nil, accessToken: nil, userId: nil)
        isAuthenticated = false
        hasServer = false
        serverURL = nil
        serverInfo = nil
        currentUserId = nil
        accessToken = nil
        currentUser = nil
        isAdministrator = false
    }

    /// Confirm-before-logout. A single ambiguous 401 from a hot path (or a
    /// cold-wake socket) no longer tears the session down: we silently re-check
    /// the token against the server (`validateSession` → `GET /Users/Me`) with a
    /// small bounded retry, and only `logout()` on a server-CONFIRMED `.invalid`.
    /// This is a pure app↔server network check — no popup, no user question.
    ///
    /// Invoked from the lazy `.cinemaxSessionExpired` notification AND the
    /// foreground re-validation (scenePhase `.active` after a long background).
    /// Debounced so concurrent triggers collapse into one probe.
    func handlePossibleSessionExpiry() async {
        guard isAuthenticated else { return }
        guard !sessionRevalidationInFlight else { return }
        sessionRevalidationInFlight = true
        defer { sessionRevalidationInFlight = false }

        // Offline → never log out. We can't prove the token is bad, and the
        // user has every right to turn their box/network off.
        guard isOnlineProvider() else { return }

        // A cold-wake network stack often needs a beat: retry briefly before
        // trusting an `.indeterminate`. 3 attempts at 0 / 0.4s / 0.8s.
        let backoffMs: [UInt64] = [0, 400, 800]
        for (attempt, delay) in backoffMs.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
            guard isAuthenticated, isOnlineProvider() else { return }
            switch await apiClient.validateSession() {
            case .valid:
                // Token still good — the 401 was spurious (cold-wake socket,
                // race). Opportunistically refresh the user + extension session.
                await refreshCurrentUser()
                return
            case .invalid:
                // Server-confirmed revocation — the one correct logout path.
                logout()
                NotificationCenter.default.post(name: .cinemaxSessionConfirmedInvalid, object: nil)
                return
            case .indeterminate:
                if attempt == backoffMs.count - 1 { return }   // out of retries → keep session
                continue
            }
        }
    }
}

struct AppNavigation: View {
    /// SwiftUI may recreate the root `AppNavigation` struct on scene events,
    /// and every recreation re-evaluates the `@State` initial-value
    /// expressions — then discards the results (`@State` keeps the first
    /// instance). For these three stores that's not just wasted work:
    /// `NetworkMonitor` starts a long-lived `NWPathMonitor` (a throwaway
    /// second one would leak a system-level path monitor), `MenuConfigStore`
    /// synchronously reads + decodes the persisted menu entries on the main
    /// thread, and `AppState` owns the shared API client + auth state. Guarded
    /// statics make the initial values process-singletons (same rationale as
    /// `configurePipeline`). The cheap stores (`ThemeManager`, etc.) stay
    /// inline — rebuilding them costs nothing.
    private static let sharedAppState = AppState()
    private static let sharedNetworkMonitor = NetworkMonitor()
    private static let sharedMenuConfig = MenuConfigStore()

    @State private var appState = AppNavigation.sharedAppState
    @State private var themeManager = ThemeManager()
    @State private var loc = LocalizationManager()
    @State private var toasts = ToastCenter()
    @State private var network = AppNavigation.sharedNetworkMonitor
    @State private var menuConfig = AppNavigation.sharedMenuConfig
    @State private var settingsNav = SettingsNavCoordinator()
    @State private var hasCheckedSession = false
    /// When the app last entered the background — drives Part E foreground
    /// re-validation (only after a long gap, e.g. overnight standby).
    @State private var lastBackgroundedAt: Date?
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

    #if os(iOS)
    /// One-shot cleanup for installs that used the removed (1.0.5, App Review
    /// 5.2.3) offline-downloads feature — the media tree can hold multiple GB
    /// and no UI remains to clear it. Cheap existence check; safe to re-run.
    private static func purgeLegacyDownloads() {
        UserDefaults.standard.removeObject(forKey: "downloads.userFlagCache")
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first else { return }
            let legacyRoot = appSupport.appendingPathComponent("Cinemax/Downloads",
                                                               isDirectory: true)
            if fm.fileExists(atPath: legacyRoot.path) {
                try? fm.removeItem(at: legacyRoot)
            }
        }
    }
    #endif

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
        .environment(\.motionEffectsEnabled, motionEffects)
        // Respect the user's OS Dynamic Type setting while capping at a size
        // that won't collapse layouts (hero titles, tab bar). The app also has
        // its own `uiScale` in Settings > Interface > Font Size for finer control.
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .preferredColorScheme(themeManager.colorScheme)
        // Widget / Top Shelf deep links (cinemax://item/{id}). Routed through
        // AppState — MainTabView switches to Home, HomeScreen pushes detail.
        .onOpenURL { url in
            appState.handleDeepLink(url)
        }
        .task {
            // Let the confirm-before-logout coordinator see real connectivity
            // (captured weakly so the closure can't extend NetworkMonitor's life).
            appState.isOnlineProvider = { [weak network] in network?.isOnline ?? true }
            await appState.restoreSession()
            hasCheckedSession = true
            menuConfig.attach(apiClient: appState.apiClient, userId: appState.currentUserId)
            // Pre-load views if the user is in library mode so the tabs
            // render with library names from first frame after launch.
            if menuConfig.mode == .custom && menuConfig.customKind == .library {
                await menuConfig.refreshAvailableViews()
            }
            #if os(iOS)
            // One-shot cleanup for installs that used the removed offline-
            // downloads feature — purge the (potentially multi-GB) media tree
            // that no longer has any UI to clear it.
            Self.purgeLegacyDownloads()
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
                lastBackgroundedAt = Date()
                NotificationCenter.default.post(name: .cinemaxDidEnterBackground, object: nil)
            } else if newPhase == .active {
                // Network conditions may have changed while backgrounded —
                // re-evaluate whether the proxy is needed for this server.
                StreamTransportPolicy.shared.refresh()
                // Part E — proactive re-validation after a MEANINGFUL background
                // gap (overnight standby is the bug; ignore quick app-switcher
                // peeks). Reuses the same coordinator: it gates on connectivity,
                // debounces against a concurrent lazy-401 cycle, refreshes the
                // user on `.valid`, and only logs out on a confirmed `.invalid`.
                if appState.isAuthenticated,
                   let since = lastBackgroundedAt,
                   Date().timeIntervalSince(since) > 60 {
                    lastBackgroundedAt = nil
                    Task { await appState.handlePossibleSessionExpiry() }
                }
            }
        }
        .onChange(of: network.isOnline) { _, online in
            // Connectivity flipped (e.g. Wi-Fi ⇄ cellular) — IPv6 reachability
            // is per-network, so re-run the transport probe.
            if online {
                StreamTransportPolicy.shared.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxSessionExpired)) { _ in
            // Lazy 401 recovery — fired by any API call that surfaces an HTTP
            // 401. We do NOT log out immediately: a single ambiguous 401 (cold
            // wake, transient server hiccup) would wrongly disconnect a user
            // whose token is still valid. Instead, silently re-validate against
            // the server first; logout happens only on a confirmed `.invalid`
            // (which posts `.cinemaxSessionConfirmedInvalid` below).
            guard appState.isAuthenticated else { return }
            Task { await appState.handlePossibleSessionExpiry() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxSessionConfirmedInvalid)) { _ in
            // The session was authoritatively confirmed invalid — `logout()`
            // already ran inside the coordinator. Surface the toast here (only
            // on the View, which owns `toasts`/`loc`). The queue collapses
            // concurrent fires to a single visible pill.
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
    /// Posted by `AppState.handlePossibleSessionExpiry` ONLY when the server
    /// authoritatively confirms the token is revoked/expired. `logout()` has
    /// already run; `AppNavigation` surfaces the "session expired" toast.
    static let cinemaxSessionConfirmedInvalid = Notification.Name("cinemaxSessionConfirmedInvalid")
    /// Tier-1 refresh: catalogue *content* changed or the cache was cleared —
    /// a FULL reload is warranted. Fired by Settings → Server "Refresh
    /// Catalogue", the parental-controls rating limit, and Admin metadata /
    /// identify / delete flows. Home + every mounted Library tab full-reload,
    /// deferred until next visible for hidden screens.
    static let cinemaxShouldRefreshCatalogue = Notification.Name("cinemaxShouldRefreshCatalogue")
    /// Tier-2 refresh: ONE item's watched / resume-position userData changed via
    /// a per-item toggle (card context menu, detail / episode / season watched
    /// toggle, Continue Watching menu, "clear Continue Watching"). The lighter
    /// sibling of `cinemaxShouldRefreshCatalogue`: Home refreshes only its
    /// userData rails (resume / next-up / favorites), never the genre fan-out;
    /// Library tabs reload only while visible (so an unwatched-only filter
    /// reflects the toggle) and defer otherwise. Favorite hearts stay on the
    /// separate `.cinemaxFavoritesChanged` fast path (cards carry no heart badge).
    static let cinemaxItemUserDataChanged = Notification.Name("cinemaxItemUserDataChanged")
    /// Posted after a favorite heart toggle succeeds. Home observes it and
    /// refreshes just its Favorites row (the full-reload notification above
    /// would re-shuffle genre rows and clear caches — overkill for a heart).
    static let cinemaxFavoritesChanged = Notification.Name("cinemaxFavoritesChanged")
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
