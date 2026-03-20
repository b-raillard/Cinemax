import SwiftUI

struct MainTabView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedTab: AppTab = .home

    var body: some View {
        #if os(tvOS)
        sidebarLayout
        #else
        if sizeClass == .regular {
            sidebarLayout
        } else {
            tabBarLayout
        }
        #endif
    }

    // MARK: - Sidebar (tvOS + iPad Landscape)

    private var sidebarLayout: some View {
        NavigationSplitView {
            sidebarContent
                #if os(tvOS)
                .frame(width: 256)
                #endif
        } detail: {
            selectedTabView
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cinemax")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ForEach(AppTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 17, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? .white : CinemaColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .background(
                            selectedTab == tab
                                ? Capsule().fill(CinemaColor.tertiaryContainer)
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
                        Label(tab.title, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        .tint(CinemaColor.tertiaryContainer)
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

    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .tvShows: "TV Shows"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film"
        case .tvShows: "tv"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}
