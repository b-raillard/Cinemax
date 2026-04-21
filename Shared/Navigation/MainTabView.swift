import SwiftUI

struct MainTabView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var selectedTab: AppTab = .home

    #if os(tvOS)
    @State private var playerCoordinator = VideoPlayerCoordinator()
    #endif

    var body: some View {
        #if os(tvOS)
        tvTabLayout
            .environment(playerCoordinator)
            .task { playerCoordinator.localizationManager = loc }
        #else
        iOSTabLayout
        #endif
    }

    // MARK: - tvOS Tab Bar (native top tab bar)

    #if os(tvOS)
    private var tvTabLayout: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases) { tab in
                selectedView(for: tab)
                    .tabItem {
                        Label(loc.localized(tab.titleKey), systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
    }
    #endif

    // MARK: - iOS / iPadOS — adaptive tab bar ↔ sidebar

    #if !os(tvOS)
    /// Uses the iOS 18 `Tab` API with `.tabViewStyle(.sidebarAdaptable)` so iPhone gets
    /// a bottom tab bar while iPad regular width gets a native sidebar. Replaces the
    /// previous hand-built `NavigationSplitView` sidebar (which needed manual selection
    /// highlight, capsule styling, and detail wiring).
    private var iOSTabLayout: some View {
        TabView(selection: $selectedTab) {
            Tab(value: AppTab.home) {
                NavigationStack { HomeScreen() }
            } label: {
                Label(loc.localized("tab.home"), systemImage: "house.fill")
            }
            Tab(value: AppTab.movies) {
                NavigationStack { MovieLibraryScreen() }
            } label: {
                Label(loc.localized("tab.movies"), systemImage: "film")
            }
            Tab(value: AppTab.tvShows) {
                NavigationStack { TVSeriesScreen() }
            } label: {
                Label(loc.localized("tab.tvShows"), systemImage: "tv.fill")
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchScreen() }
            } label: {
                Label(loc.localized("tab.search"), systemImage: "magnifyingglass")
            }
            Tab(value: AppTab.settings) {
                NavigationStack { SettingsScreen() }
            } label: {
                Label(loc.localized("tab.settings"), systemImage: "gearshape")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(themeManager.accentContainer)
    }
    #endif

    // MARK: - Tab Content (tvOS only; iOS uses Tab blocks above)

    #if os(tvOS)
    @ViewBuilder
    private func selectedView(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            NavigationStack { HomeScreen() }
        case .movies:
            NavigationStack { MovieLibraryScreen() }
        case .tvShows:
            NavigationStack { TVSeriesScreen() }
        case .search:
            NavigationStack { SearchScreen() }
        case .settings:
            NavigationStack { SettingsScreen() }
        }
    }
    #endif
}

// MARK: - Tab Definition

enum AppTab: String, CaseIterable, Identifiable {
    case home, movies, tvShows, search, settings

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .home: "tab.home"
        case .movies: "tab.movies"
        case .tvShows: "tab.tvShows"
        case .search: "tab.search"
        case .settings: "tab.settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film"
        case .tvShows: "tv.fill"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}
