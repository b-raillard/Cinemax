import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Top-level tab container. Hardcoded tabs have been replaced by a dynamic
/// list resolved from `MenuConfigStore` — the user can choose between the
/// default 5 tabs, a curated set by content type, or a per-library tab list
/// in Settings → Interface → Main Menu.
struct MainTabView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(MenuConfigStore.self) private var menuConfig
    @Environment(SettingsNavCoordinator.self) private var settingsNav
    @State private var selectedTabID: String = "home"

    /// Snapshot of `menuConfig.resolvedTabs` used to render the tab bar.
    /// Decoupling from the live `@Observable` reads stops the `TabView`
    /// from reconfiguring its UIKit-backed bar on every mutation while the
    /// user is actively editing in the Main Menu sub-page — that reconfig
    /// (tab added/removed/reordered) made tvOS's focus engine bail out of
    /// the inner page and snap focus onto the top-bar `Réglages` pill, so
    /// every toggle felt like a full page reload. Snapshot only refreshes
    /// when the user is *not* on the menu editor.
    @State private var displayedTabs: [ResolvedTab] = []

    #if os(tvOS)
    @State private var playerCoordinator = VideoPlayerCoordinator()
    #endif

    /// True only while the user is editing the menu on the Main Menu
    /// sub-page. Drives whether the bar snapshot keeps pace with the live
    /// store or stays frozen until they back out.
    private var isEditingMenu: Bool {
        settingsNav.selectedInterfaceSub == .menu
    }

    var body: some View {
        Group {
            #if os(tvOS)
            tvTabLayout(tabs: displayedTabs)
                .environment(playerCoordinator)
                .task { playerCoordinator.localizationManager = loc }
            #else
            iOSTabLayout(tabs: displayedTabs)
            #endif
        }
        .onAppear {
            // Initial seed — without this the bar is empty for one frame.
            if displayedTabs.isEmpty {
                displayedTabs = menuConfig.resolvedTabs
            }
        }
        .onChange(of: menuConfig.resolvedTabs) { _, new in
            // Fine-grained edits (toggle / reorder / library refresh)
            // freeze the bar while the menu editor is open — otherwise
            // every toggle reconfigures the tab bar and rips focus off
            // the row the user is touching. The bar catches up the
            // moment they back out (handled below).
            guard !isEditingMenu else { return }
            displayedTabs = new
        }
        .onChange(of: isEditingMenu) { _, editing in
            // Editor just closed → flush pending edits into the bar.
            if !editing {
                displayedTabs = menuConfig.resolvedTabs
            }
        }
        .onChange(of: menuConfig.mode) { _, _ in
            // Mode change (default ↔ custom, including Reset which forces
            // back to default) is a *structural* edit — refresh the bar
            // even while the editor is open. Same intent as the user
            // explicitly asking for a different menu.
            displayedTabs = menuConfig.resolvedTabs
        }
        .onChange(of: menuConfig.customKind) { _, _ in
            // Switching the tab source (content type ↔ library) replaces
            // the entire set of entries — refresh the bar live so the
            // user sees what they're configuring.
            displayedTabs = menuConfig.resolvedTabs
        }
    }

    // MARK: - tvOS Tab Bar (native top tab bar)
    //
    // Uses the iOS 18 / tvOS 18 `Tab(value:)` API. The earlier `.tabItem
    // + .tag` pattern (pre-18) wasn't preserving child-view `@State`
    // across a `ForEach` diff when `MenuConfigStore` mutates — every
    // toggle / kind-change was remounting `SettingsScreen` and dropping
    // its `selectedCategory`/`selectedInterfaceSub`, dumping the user
    // back to the Settings landing (or rendering a transient empty
    // page). The newer `Tab(value:)` builds an identity off the `value`
    // and survives collection mutations cleanly.

    #if os(tvOS)
    @ViewBuilder
    private func tvTabLayout(tabs: [ResolvedTab]) -> some View {
        TabView(selection: $selectedTabID) {
            ForEach(tabs) { tab in
                Tab(value: tab.id) {
                    NavigationStack {
                        destinationView(for: tab)
                    }
                } label: {
                    Label(tab.displayTitle(loc), systemImage: tab.icon)
                }
            }
        }
    }
    #endif

    // MARK: - iOS / iPadOS — adaptive tab bar ↔ sidebar

    #if !os(tvOS)
    /// Uses the iOS 18 `Tab` API with `.tabViewStyle(.sidebarAdaptable)` so iPhone gets
    /// a bottom tab bar while iPad regular width gets a native sidebar.
    ///
    /// Deliberately *not* tagging the Search tab with `role: .search`: per Apple's
    /// WWDC 2024 docs, a `.search` role tab is force-placed at the trailing edge
    /// of the iPhone tab bar regardless of declaration order, which conflicts
    /// with this app's user-reorderable menu and was causing the selection to
    /// snap to Search after a drag-reorder.
    @ViewBuilder
    private func iOSTabLayout(tabs: [ResolvedTab]) -> some View {
        TabView(selection: $selectedTabID) {
            ForEach(tabs) { tab in
                Tab(value: tab.id) {
                    NavigationStack {
                        destinationView(for: tab)
                    }
                } label: {
                    Label(tab.displayTitle(loc), systemImage: tab.icon)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(themeManager.accentContainer)
        .sensoryFeedback(.selection, trigger: selectedTabID)
    }
    #endif

    // MARK: - Destination dispatch

    /// Resolves a `ResolvedTab` to its content view. iPhone overflow (>5 tabs)
    /// is handled by SwiftUI's native `TabView` — no custom More surface
    /// here, the system creates one with the iOS 26 liquid-glass treatment.
    @ViewBuilder
    func destinationView(for tab: ResolvedTab) -> some View {
        switch tab.destination {
        case .home:
            HomeScreen()
        case .search:
            SearchScreen()
        case .settings:
            SettingsScreen()
        case .mediaLibrary(let kind):
            MediaLibraryScreen(itemType: kind)
        case .libraryView(let id, let name, let kind):
            // `kind` is nil for mixed / Other libraries — propagate so the
            // screen skips the `includeItemTypes` filter and surfaces every
            // item in the parent folder regardless of how Jellyfin typed it.
            MediaLibraryScreen(itemType: kind, parentId: id, overrideTitle: name)
        }
    }
}
