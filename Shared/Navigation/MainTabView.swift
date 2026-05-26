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
    @State private var selectedTabID: String = "home"

    #if os(tvOS)
    @State private var playerCoordinator = VideoPlayerCoordinator()
    #endif

    var body: some View {
        let tabs = menuConfig.resolvedTabs
        Group {
            #if os(tvOS)
            tvTabLayout(tabs: tabs)
                .environment(playerCoordinator)
                .task { playerCoordinator.localizationManager = loc }
            #else
            iOSTabLayout(tabs: tabs)
            #endif
        }
        // No `reconcileSelection` — `TabView`'s `selection` binding keeps the
        // current tab id even when the underlying list reorders. Reassigning
        // `selectedTabID` on every list change was bumping the user to a
        // different tab during reorder/toggle (the source of the "redirected
        // to Search/Home for no reason" reports).
    }

    // MARK: - tvOS Tab Bar (native top tab bar)

    #if os(tvOS)
    @ViewBuilder
    private func tvTabLayout(tabs: [ResolvedTab]) -> some View {
        TabView(selection: $selectedTabID) {
            ForEach(tabs) { tab in
                NavigationStack {
                    destinationView(for: tab)
                }
                .tabItem {
                    Label(tab.displayTitle(loc), systemImage: tab.icon)
                }
                .tag(tab.id)
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
