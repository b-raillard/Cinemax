import SwiftUI

struct MainTabView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
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
        if sizeClass == .regular {
            sidebarLayout
        } else {
            tabBarLayout
        }
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

    // MARK: - Sidebar (iPad Landscape)

    private var sidebarLayout: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            selectedTabView
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.localized("app.name"))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ForEach(AppTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(loc.localized(tab.titleKey), systemImage: tab.icon)
                        .font(.system(size: 17, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? .white : CinemaColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .background(
                            selectedTab == tab
                                ? Capsule().fill(themeManager.accentContainer)
                                : nil
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(CinemaColor.surfaceContainerLow.opacity(0.7))
    }

    // MARK: - Tab Bar (iPhone + iPad Portrait)

    private var tabBarLayout: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases) { tab in
                selectedView(for: tab)
                    .tabItem {
                        Label(loc.localized(tab.titleKey), systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        .tint(themeManager.accentContainer)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var selectedTabView: some View {
        selectedView(for: selectedTab)
    }

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
