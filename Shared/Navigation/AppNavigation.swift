import SwiftUI
import CinemaxKit
import Nuke
import OSLog
import JellyfinAPI

// `AppState` lives in `AppState.swift` (extracted 2026-09-22, audit Q8).

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
    ///
    /// `sharedAppState` is deliberately not `private`: an App Intent runs
    /// outside the view hierarchy and has no environment to read from, so it
    /// reaches this instance directly to post its pending navigation. Any other
    /// access point would be a *second* `AppState` — a separate API client and
    /// auth state that the UI would never observe.
    static let sharedAppState = AppState()
    private static let sharedNetworkMonitor = NetworkMonitor()
    private static let sharedMenuConfig = MenuConfigStore()
    /// Owns the inbound remote-control socket. A process singleton for the same
    /// reason as the three above — scene-event struct recreation must not open a
    /// second `/socket` connection, which the server would treat as the same
    /// session and feed duplicate commands.
    private static let sharedRemoteControl = RemoteControlListener()
    /// Owns the parental-controls lock. A process singleton for two reasons:
    /// it reads the Keychain at `init` (a synchronous `securityd` XPC hop on the
    /// main actor, the same cost that puts `MenuConfigStore` in this set), and
    /// its `isUnlocked` flag is session state — a scene-event recreation would
    /// either re-open a gate the parent had closed or drop an unlock they are
    /// mid-way through using. See the RULE on `ParentalLockController`.
    private static let sharedParentalLock = ParentalLockController()

    @State private var appState = AppNavigation.sharedAppState
    @State private var themeManager = ThemeManager()
    @State private var loc = LocalizationManager()
    @State private var toasts = ToastCenter()
    @State private var network = AppNavigation.sharedNetworkMonitor
    @State private var menuConfig = AppNavigation.sharedMenuConfig
    @State private var parentalLock = AppNavigation.sharedParentalLock
    /// Read straight off the static rather than through `@State`: nothing here
    /// observes it (it publishes into `AppState` / `ToastCenter` instead), so a
    /// property wrapper would only add semantics without a purpose.
    private var remoteControl: RemoteControlListener { Self.sharedRemoteControl }
    @State private var playlistPresenter = AddToPlaylistPresenter()
    @State private var cardActions = CardActionPresenter()
    @State private var settingsNav = SettingsNavCoordinator()
    @State private var hasCheckedSession = false
    /// Deliberately NOT one of the process singletons above: it holds two
    /// `UserDefaults` reads and a throttled network hop, so a scene-event
    /// recreation costs nothing — and the standing offer is re-derived from
    /// the stored release rather than held in memory.
    @State private var updateChecker = AppUpdateChecker()
    /// The « Quoi de neuf » pages this launch owes the user; empty when it owes
    /// none. Filled once by the `.task` below, cleared by `finishWhatsNew()`.
    @State private var whatsNewPages: [WhatsNewPage] = []
    /// Empty string = never stamped. See the key's own note: absent is NOT
    /// "first run" — it is also every install upgrading from a build that
    /// predates the reel, which is exactly who it exists for.
    @AppStorage(SettingsKey.whatsNewLastSeenVersion) private var whatsNewLastSeen: String = ""
    /// When the app last entered the background — drives Part E foreground
    /// re-validation (only after a long gap, e.g. overnight standby).
    @State private var lastBackgroundedAt: Date?
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(SettingsKey.motionEffects) private var motionEffects: Bool = SettingsKey.Default.motionEffects
    /// The system's Reduce Motion. Combined with the app toggle into the ONE
    /// value the whole tree reads (`\.motionEffectsEnabled`), so turning it on in
    /// iOS / tvOS Settings stops the hero carousel, the Ken Burns drift and every
    /// pulse without touching the app's own switch.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Drives `RemoteControlListener`. Read here rather than inside the listener
    /// so flipping the toggle in Settings re-runs `onChange` and withdraws (or
    /// re-publishes) the capability declaration immediately.
    @AppStorage(SettingsKey.remoteControlEnabled) private var remoteControlEnabled: Bool = SettingsKey.Default.remoteControlEnabled
    /// Whether the first-run introduction has been finished, skipped, or made
    /// moot by a launch that already knew a server. Read ONLY through
    /// `OnboardingPolicy` — see its two decisions.
    @AppStorage(SettingsKey.onboardingSeen) private var onboardingSeen: Bool = SettingsKey.Default.onboardingSeen

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
        // Posters and backdrops come from the same server as everything else, so
        // they need the same explicit certificate approval — otherwise a
        // self-signed server would sign in and browse with every image blank.
        // The existing `DataLoader` is MUTATED, never replaced: `withDataCache`
        // above already configured its session (notably `urlCache`), and a fresh
        // `DataLoader()` would silently restore Nuke's default HTTP cache on top
        // of the 500 MB data cache. Nuke's own documentation prescribes exactly
        // this line for handling authentication challenges.
        (config.dataLoader as? DataLoader)?.delegate = ServerTrustDelegate.shared
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
    /// MetricKit subscription, once per process for the same reason as
    /// `configurePipeline`: scene events recreate this struct. iOS only — every
    /// MetricKit class is `API_UNAVAILABLE(tvos)`. See `MetricKitSubscriber`.
    private static let registerMetricKit: Void = {
        MetricKitSubscriber.register()
    }()
    #endif

    init() {
        _ = Self.configurePipeline
        #if os(iOS)
        _ = Self.registerMetricKit
        #endif
    }

    /// Records that this build's « Quoi de neuf » has been seen, and closes it.
    /// ONE writer for both exits — the reel finishing and the cover being
    /// dismissed — so the two can never disagree about the stamp.
    private func finishWhatsNew() {
        if let stamp = WhatsNewPolicy.stamp(installed: AppUpdateChecker.installedVersion) {
            whatsNewLastSeen = stamp
        }
        whatsNewPages = []
    }

    var body: some View {
        ZStack {
            Group {
                if !hasCheckedSession {
                    launchScreen
                } else if OnboardingPolicy.shouldShow(
                    seen: onboardingSeen,
                    hasRegisteredServer: !appState.servers.isEmpty,
                    hasServer: appState.hasServer,
                    isAddingServer: appState.isAddingServer
                ) {
                    // Deliberately BELOW the session check and ABOVE the
                    // no-server branch: before `hasCheckedSession` it would
                    // flash over a session still being restored on every cold
                    // launch, and after `ServerSetupScreen` it could never show.
                    // `OnboardingPolicy` owns who qualifies — an upgrade, a
                    // logout from the only server and an add from Réglages all
                    // resolve to false there.
                    OnboardingScreen(isReplay: false) { onboardingSeen = true }
                } else if !appState.hasServer {
                    ServerSetupScreen()
                } else if !appState.isAuthenticated {
                    // Keyed on the target server so retargeting the pre-auth
                    // flow at a DIFFERENT server (Servers sheet → "add", or
                    // "Change server" from the login screen) rebuilds the view
                    // instead of reusing it. `LoginViewModel` is owned by
                    // `LoginScreen`'s own `@State`, so a new identity is what
                    // discards the previous server's typed username/password,
                    // its stale error message and its Quick Connect code — and
                    // it re-fires `.task { checkQuickConnect }`, which is the
                    // only thing that re-probes whether THIS server has Quick
                    // Connect enabled (otherwise the CTA keeps the old
                    // server's answer).
                    LoginScreen()
                        .id(appState.serverURL)
                } else {
                    MainTabView()
                }
            }
        }
        // Toasts live in their OWN window above this one: an overlay here drew
        // underneath every sheet, cover and the player — see `ToastWindowHost`.
        .background(ToastWindowHost(toasts: toasts, loc: loc, themeManager: themeManager))
        .environment(appState)
        .environment(themeManager)
        .environment(loc)
        // SwiftUI's own formatting (`Text(date, style:)`, number and list
        // interpolations) follows the APP's language, not the device's.
        .environment(\.locale, loc.locale)
        .environment(toasts)
        .environment(network)
        .environment(menuConfig)
        .environment(settingsNav)
        .environment(parentalLock)
        .environment(playlistPresenter)
        // "Add to a playlist" is raised from poster context menus inside lazy
        // grids, where a presentation attached to the cell dies when it scrolls
        // out. Hosting it once at the root also lets every grid, the search
        // results and the detail screen share one sheet with no plumbing.
        .modifier(AddToPlaylistPresentation(
            request: $playlistPresenter.request,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toasts
        ))
        .environment(cardActions)
        // Same reason as the playlist sheet: playback is launched from context
        // menus inside lazy grids, where a presentation attached to the cell
        // dies with it. Nothing to host here on tvOS — the menu calls
        // `VideoPlayerCoordinator` directly.
        #if os(iOS)
        .modifier(CardPlaybackPresentation(
            request: $cardActions.playback,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toasts
        ))
        #endif
        // "Play on…" is now also raised from context menus, so the sheet is
        // hosted here rather than by the detail screen. The modifier already
        // takes a binding: this is a relocation, not a rewrite.
        .modifier(RemotePlayPresentation(
            sheet: $cardActions.remotePlay,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toasts
        ))
        .environment(\.motionEffectsEnabled, MotionEffects.isEnabled(
            appToggle: motionEffects,
            systemReduceMotion: systemReduceMotion
        ))
        // No Dynamic Type cap here, deliberately: a ROOT cap shrank every screen
        // — the reading ones included — for the three largest accessibility
        // sizes, i.e. exactly the users who asked for bigger text. The surfaces
        // whose layout genuinely cannot follow cap THEMSELVES through
        // `.layoutBoundDynamicType()` (heroes, cards, the tab bar, the player
        // host); see `CinemaDynamicType`. The app's own `uiScale`
        // (Settings > Interface > Font Size) still multiplies on top.
        .preferredColorScheme(themeManager.colorScheme)
        // « Une nouvelle version est disponible ». Hosted at the root like every
        // other app-wide presentation, so it survives whichever branch is on
        // screen. It can only ever speak once `AppUpdateChecker.refresh()` has
        // run, which is gated on the session check below.
        .modifier(AppUpdatePresentation(checker: updateChecker, loc: loc))
        // « Quoi de neuf » — the first launch on a new version. A sheet on
        // iOS (closable from its top button or a swipe down, both of which
        // stamp the version like the last page does), a full-screen cover on
        // tvOS — see `whatsNewPresentation`. Gated on being signed in, so an
        // upgrade that lands on the login
        // screen shows it once the user is actually in the app rather than
        // over the sign-in form. The environment is re-injected by hand: a
        // presentation is its own context and does not carry injected
        // `@Observable` objects down with it (same reason `onboardingSheet`
        // does it).
        .whatsNewPresentation(isPresented: Binding(
            get: { !whatsNewPages.isEmpty && appState.isAuthenticated },
            set: { presented in
                guard !presented else { return }
                finishWhatsNew()
            }
        )) {
            WhatsNewScreen(pages: whatsNewPages) { finishWhatsNew() }
                .environment(themeManager)
                .environment(loc)
                .environment(\.motionEffectsEnabled, MotionEffects.isEnabled(
                    appToggle: motionEffects,
                    systemReduceMotion: systemReduceMotion
                ))
        }
        // Widget / Top Shelf deep links (cinemax://item/{id}). Routed through
        // AppState — MainTabView switches to Home, HomeScreen pushes detail.
        .onOpenURL { url in
            appState.handleDeepLink(url)
        }
        // A language change rebuilds the HTTP client with the new
        // `Accept-Language` and drops the response cache — its keys carry no
        // language, so a cached season list would otherwise keep serving the
        // previous locale's track titles for its TTL.
        .onChange(of: loc.languageCode) { _, code in
            appState.apiClient.setPreferredLanguage(code)
        }
        .task {
            // Let the confirm-before-logout coordinator see real connectivity.
            // Captured strongly: `NetworkMonitor` and `AppState` are both process
            // singletons, so there is no lifetime to protect — and a `weak`
            // capture here was ineffective anyway, the enclosing `.task` already
            // holding `network` strongly (Swift 6.4 warns about exactly that).
            appState.isOnlineProvider = { [network] in network.isOnline }
            // The language rides every request as `Accept-Language` (Jellyfin
            // 12.0 localizes the media-stream titles the track pickers print
            // from it; 10.x ignores it). Recorded BEFORE `restoreSession` builds
            // the client, so the first authenticated request already carries
            // it; `onChange(of: loc.languageCode)` below keeps it current.
            appState.apiClient.setPreferredLanguage(loc.languageCode)
            await appState.restoreSession()
            // An install that already knows a server is not a first run whatever
            // the flag says — it upgraded from a version without onboarding.
            // Latching here is what keeps that user out for good: without it,
            // deleting their last server from the list would empty the registry
            // and the gate above would greet them as a newcomer.
            if OnboardingPolicy.shouldStampSeen(
                hasRegisteredServer: !appState.servers.isEmpty,
                hasServer: appState.hasServer
            ) {
                onboardingSeen = true
            }
            hasCheckedSession = true
            // Baseline attach so the menu editor has an API client even with
            // no session. The library-mode view refresh is NOT triggered here:
            // `onChange(of: appState.currentUserId)` below owns it for every
            // session-establishing transition (restore, fresh login, user
            // switch) — `restoreSession` has already set `currentUserId` by
            // now, so the cold-restore case fires through that observer.
            menuConfig.attach(apiClient: appState.apiClient, userId: appState.currentUserId)
            // Load the restored server's menu profile in the SAME main-actor
            // slice as `hasCheckedSession = true` above — there is no `await`
            // between the two, so SwiftUI coalesces them into one render and
            // `MainTabView` never paints a menu the user hasn't configured.
            // RULE: keep it that way. Inserting an `await` between them makes
            // the tab bar visible before its profile is loaded.
            // `restoreSession` has already hydrated the registry, so both the
            // active id and the known ids are available here.
            menuConfig.activate(serverId: appState.activeServerId,
                                knownServerIds: Set(appState.servers.map(\.id)))
            // Search history is per-server too: the first server that activates
            // after the upgrade inherits the old global list, once.
            SearchHistoryStore.migrateLegacyIfNeeded(into: appState.activeServerId)
            // Ask the App Store whether a newer build exists. In its own Task so
            // it can never delay the launch it rides on: the lookup is a network
            // round-trip to Apple, and NOTHING downstream waits for its answer.
            // Deliberately placed AFTER `hasCheckedSession = true` — an alert
            // over the launch screen would interrupt a session still being
            // restored. `AppUpdatePolicy` owns every rule about whether it
            // speaks at all, and its answer to any uncertainty is silence.
            Task { await updateChecker.refresh() }
            // « Quoi de neuf » — decided here, in the same main-actor slice as
            // the onboarding stamp above, because the two answer ONE question
            // between them and must never both speak. `isFirstRun` is computed
            // from the very inputs the branch in `body` reads, so the screen
            // the user is about to see and the decision taken here cannot
            // disagree. Note `onboardingSeen` has already been latched above
            // for an upgraded install, which is what makes that user « not a
            // first run » and therefore the audience for the reel.
            let installedVersion = AppUpdateChecker.installedVersion
            let isFirstRun = OnboardingPolicy.shouldShow(
                seen: onboardingSeen,
                hasRegisteredServer: !appState.servers.isEmpty,
                hasServer: appState.hasServer,
                isAddingServer: appState.isAddingServer
            )
            switch WhatsNewPolicy.decide(
                lastSeenVersion: whatsNewLastSeen.isEmpty ? nil : whatsNewLastSeen,
                installed: installedVersion,
                isFirstRun: isFirstRun
            ) {
            case .nothing:
                break
            case .stampOnly:
                // A genuine first run, or a version shipping no pages at all.
                // Moving the stamp is what stops the NEXT version's launch
                // handing the user everything accumulated since — including
                // announcements for a version they started on.
                if let stamp = WhatsNewPolicy.stamp(installed: installedVersion) {
                    whatsNewLastSeen = stamp
                }
            case .show(let pages):
                whatsNewPages = pages
            }
            // A joined group learns WHAT to watch only from the socket's
            // `PlayQueue` update — `GET /SyncPlay/List` carries no item. Route
            // it through the same in-process pair an App Intent and a remote
            // « Lire sur… » use, so a session join inherits the full fidelity of
            // a tap: series → next-up, resume position, version pick, prev/next.
            //
            // RULE — this MUST stay outside `#if os(iOS)`. It sat inside that
            // block, between two genuinely iOS-only chores, and the Apple TV is
            // the device Watch Together exists for: measured on 2026-09-05, a
            // tvOS join received the `PlayQueue` frame (`CINEMAX-SYNCPLAY ▸
            // PlayQueue : item=… entrée=…`), had nowhere to hand it, and left
            // the viewer on Accueil with the card merely flipping to « Vous y
            // êtes » — a feature that looks wired and does nothing. Exactly the
            // failure `MediaDetailScreen.consumeIntentPlaybackRequest()` carries
            // its own cross-platform RULE about.
            //
            // The position is carried, NOT discarded. `{ itemId, _ in … }` was
            // the whole of defect D2: the group's `startPositionTicks` reached
            // this closure and died here, so the request fell through to the
            // fiche's own resume resolution — the JOINING account's. Measured
            // 2026-09-06: group at 3:39, joiner opened at 12:33 on the end
            // credits, gap never corrected. See `SyncPlayJoinStart`.
            SyncPlayController.shared.onQueueChanged = { itemId, startTicks in
                guard AppState.isValidItemId(itemId) else { return }
                appState.pendingIntentPlaybackItemId = itemId
                appState.pendingIntentPlaybackStartTicks = startTicks
                appState.pendingDeepLinkItemId = itemId
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
            // The diagnostics channel's ONLY injection point. The player holds a
            // narrowed API slice and cannot reach a server-wide route — see the
            // RULE on `DiagnosticsUploader.client`. One assignment is enough:
            // `AppState.apiClient` is the same instance for the process's life,
            // `reconnect` repointing it in place rather than replacing it.
            DiagnosticsUploader.client = appState.apiClient
            // Advertise this device as a remote-control target and start
            // listening. Idempotent — `apply` no-ops when nothing changed, so
            // the observers below can call it freely.
            remoteControl.apply(appState: appState, toasts: toasts, loc: loc, enabled: remoteControlEnabled)
        }
        // RULE — DECLARATION ORDER IS LOAD-BEARING: `activeServerId` must be
        // observed BEFORE `currentUserId`. A server switch mutates both (and
        // `serverURL`) in one transaction, and SwiftUI delivers
        // same-transaction `onChange` handlers in declaration order. This one
        // swaps the menu profile; the `currentUserId` one below is the single
        // owner of `refreshAvailableViews()`, which merges the fetched
        // libraries into `libraryEntries` and persists them. Refreshing before
        // the swap would merge the NEW server's libraries into the PREVIOUS
        // server's profile and save them there. Do not reorder these, and do
        // not add a second refresh owner.
        .onChange(of: appState.activeServerId) { _, newId in
            // Menu configuration is per-server (mode, kind, order, enabled
            // flags, cached views). Nothing to invalidate on a switch — the
            // target server's own profile is loaded wholesale.
            menuConfig.activate(serverId: newId,
                                knownServerIds: Set(appState.servers.map(\.id)))
            // No-op once the legacy search history has found its server.
            SearchHistoryStore.migrateLegacyIfNeeded(into: newId)
        }
        .onChange(of: appState.serverURL) { _, new in
            // Re-decide stream transport for the new server (or clear on logout).
            StreamTransportPolicy.shared.configure(serverURL: new)
            // The "Play on…" poll result is per-server (a different server has
            // different — possibly zero — controllable sessions). A stale
            // non-zero count from the server we just left would keep the entry
            // visible against the new one's sessions, and a stale zero would
            // hide it after switching to a server that DOES have a target;
            // both read as fresh even though neither is. Back to "unknown"
            // until a real probe runs again (`MediaDetailViewModel.loadRemoteTargets`).
            cardActions.knownRemoteTargetCount = nil
        }
        .onChange(of: appState.currentUserId) { oldId, newId in
            menuConfig.attach(apiClient: appState.apiClient, userId: newId)
            // Single owner of the library-mode view refresh: fires on EVERY
            // transition that establishes or changes the signed-in user —
            // cold-launch session restore (`restoreSession` sets the id from
            // inside `.task`), fresh login (`completeSession`), and user
            // switch. The fresh-login case is load-bearing: a server the user
            // has never signed into carries no cached views, and `.task` ran
            // pre-login with a nil userId, so skipping `nil → some` here meant
            // nothing ever fetched the views — the tab bar resolved to zero
            // tabs and the app came up as a black screen until the next full
            // relaunch.
            if newId != nil, oldId != newId,
               menuConfig.mode == .custom && menuConfig.customKind == .library {
                Task { await menuConfig.refreshAvailableViews() }
            }
            // A Watch Together group belongs to the session that opened it. On
            // a logout / user switch the hub rebuilds its socket for whoever is
            // signed in now, and a still-subscribed controller would apply the
            // NEW session's transport commands to a group on the OLD one.
            SyncPlayController.shared.sessionDidEnd()
            // Capabilities are per-session, so a login / user switch has to
            // re-declare them; a logout tears the socket down (`apply` sees
            // `isAuthenticated == false`).
            remoteControl.apply(appState: appState, toasts: toasts, loc: loc, enabled: remoteControlEnabled)
            // Same rationale as the `serverURL` reset above: a different
            // signed-in user (switch, or logout → nil) may see a different
            // controllable-session landscape, so the last poll's count can't
            // be trusted for them either.
            cardActions.knownRemoteTargetCount = nil
        }
        .onChange(of: appState.isAuthenticated) { _, _ in
            // A fresh sign-in sets `currentUserId` BEFORE `isAuthenticated`
            // (`LoginViewModel.completeSession` awaits `refreshCurrentUser` and
            // the success dwell in between), so the `currentUserId` observer
            // above reaches `apply` while it still reads signed-out and stops.
            // Without this second call the device was no « Lire sur… » target
            // and heard no invitation until the next trip to the foreground.
            // Idempotent: `apply` no-ops on an unchanged state.
            remoteControl.apply(appState: appState, toasts: toasts, loc: loc, enabled: remoteControlEnabled)
        }
        .onChange(of: remoteControlEnabled) { _, enabled in
            // Withdrawing re-posts with `supportsMediaControl: false`, which is
            // what actually removes this device from other clients' pickers —
            // just closing the socket would leave the stale declaration standing.
            remoteControl.apply(appState: appState, toasts: toasts, loc: loc, enabled: enabled)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                lastBackgroundedAt = Date()
                NotificationCenter.default.post(name: .cinemaxDidEnterBackground, object: nil)
                // Drop the remote-control socket: a backgrounded app can't act
                // on a play command anyway, and holding a WebSocket open is a
                // standing battery / radio-wake cost. Re-established on `.active`.
                remoteControl.stop()
                // Close the parental gate. `.background` and NOT `.inactive`:
                // the latter also fires for an app-switcher peek, a Control
                // Center swipe or a notification banner, and re-asking for the
                // PIN after one of those reads as the lock misfiring.
                parentalLock.lockForBackground()
            } else if newPhase == .active {
                // Network conditions may have changed while backgrounded —
                // re-evaluate whether the proxy is needed for this server.
                StreamTransportPolicy.shared.refresh()
                // A logout whose Keychain clear failed left the previous token
                // with the widget / Top Shelf; retry it (no-op otherwise).
                ExtensionSessionBridge.retryFailedClear()
                // A date set forward in the Settings app must not have closed
                // the parental PIN back-off: re-read it on the monotonic clock.
                parentalLock.refreshThrottle()
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
                } else if appState.isAuthenticated {
                    // Shorter hop — the token is not in question, but the
                    // POLICY may be. `AppState.currentUser` is a cache taken at
                    // login that nothing else refreshes for the life of the
                    // process, so an admin granting or withdrawing a permission
                    // reached a running client only at the next launch. The
                    // socket's `UserUpdated` frame is the immediate path (see
                    // `RemoteControlListener`); this is the floor for the case
                    // where the user has turned the remote-control socket off.
                    // One small request per foreground.
                    Task { await appState.refreshCurrentUser() }
                }
                // Re-open the socket dropped on background and re-declare the
                // capabilities, since the session may have been reaped while away.
                remoteControl.apply(appState: appState, toasts: toasts, loc: loc, enabled: remoteControlEnabled)
                // Re-derive the update decision, and re-ask the Store if a day
                // has passed. Free on the common path: the decision comes from
                // the stored release, and the request is behind its own throttle.
                if hasCheckedSession {
                    Task { await updateChecker.refresh() }
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
        .onChange(of: systemReduceMotion) { _, _ in
            // Same nudge for the system switch, which the tick also reads.
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

    /// A playlist was created, or an item was added to one. Its own fast path,
    /// like `cinemaxFavoritesChanged`: nothing about an item's userData changed,
    /// so neither refresh tier applies — what changed is the set of playlists
    /// and their item counts. Home's Playlists rail is the consumer, and it
    /// matters that it listens: that rail is the only route to a playlist on the
    /// default menu, so without this the surface that exists to make playlists
    /// findable would be the last place to hear about a new one.
    static let cinemaxPlaylistsChanged = Notification.Name("cinemaxPlaylistsChanged")

    /// Somebody may have just opened a Watch Together session. Home's « En
    /// direct » row is the consumer, and it is the only door into a session
    /// another person opened.
    ///
    /// Posted when a `DisplayMessage` arrives over the realtime socket, because
    /// that is the whole of what an invitation can be here: Jellyfin has no
    /// invitation primitive, so the lobby's « Prévenir » sends a plain toast
    /// telling the recipient to look at their Accueil. Before this, the row on
    /// the other end only caught up on the next 20 s poll — and only if that
    /// person happened to be sitting on Accueil already, which is precisely
    /// what the message is asking them to go and do.
    ///
    /// Deliberately not narrowed to invitations: a `DisplayMessage` costs one
    /// small permission-gated refresh, and the socket carries no way to tell an
    /// invitation from any other message a server might send.
    static let cinemaxLiveSessionsChanged = Notification.Name("cinemaxLiveSessionsChanged")
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
