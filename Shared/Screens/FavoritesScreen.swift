import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Favorites")

/// Aggregated view of every hearted movie and series across all libraries —
/// the user's personal "watchlist". Reached via the "View All" affordance on
/// the Home Favorites row. Reuses the poster grid; un-hearting an item from its
/// detail screen removes it here via `.cinemaxFavoritesChanged`.
@MainActor @Observable
final class FavoritesViewModel {
    var items: [BaseItemDto] = []
    var isLoading = true
    /// True when the last fetch threw — drives the error state instead of the
    /// (misleading) empty state. The View maps it to localized copy.
    var loadFailed = false

    private var hasLoaded = false

    /// First load — no-op once content is loaded (screen reappearance).
    func loadInitial(using appState: AppState) async {
        guard !hasLoaded else { return }
        await load(using: appState)
    }

    func load(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        hasLoaded = true
        isLoading = true
        loadFailed = false
        do {
            items = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.movie, .series],
                sortBy: [.sortName],
                sortOrder: [.ascending],
                isFavorite: true,
                limit: 200
            ).items
        } catch {
            logger.warning("Favorites load failed: \(error.localizedDescription, privacy: .public)")
            loadFailed = true
        }
        isLoading = false
    }
}

/// Full-screen grid of the user's favorites. Pushed onto Home's navigation
/// stack — it does NOT declare its own `NavigationStack` (the parent provides
/// one; nesting would break the per-card `NavigationLink` pushes).
struct FavoritesScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var viewModel = FavoritesViewModel()
    @State private var prefetcher = PosterPrefetcher()

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            content
        }
        #if os(iOS)
        .navigationTitle(loc.localized("home.favorites"))
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            await viewModel.loadInitial(using: appState)
            prefetchPosters()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxFavoritesChanged)) { _ in
            Task { await viewModel.load(using: appState); prefetchPosters() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            Task { await viewModel.load(using: appState); prefetchPosters() }
        }
        // A per-item watched/resume toggle (tier-2) — reload immediately so an
        // un-watch drops the item while this grid is on screen.
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxItemUserDataChanged)) { _ in
            Task { await viewModel.load(using: appState); prefetchPosters() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            LoadingStateView()
        } else if viewModel.loadFailed && viewModel.items.isEmpty {
            ErrorStateView(message: loc.localized("error.generic"), retryTitle: loc.localized("action.retry")) {
                Task { await viewModel.load(using: appState) }
            }
        } else if viewModel.items.isEmpty {
            EmptyStateView(
                systemImage: "heart",
                title: loc.localized("favorites.empty.title"),
                subtitle: loc.localized("favorites.empty.subtitle")
            )
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            #if os(tvOS)
            // tvOS has no navigation bar — carry the title in-scroll.
            Text(loc.localized("home.favorites"))
                .font(CinemaFont.display(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, gridPadding)
                .padding(.top, CinemaSpacing.spacing5)
            #endif

            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(viewModel.items, id: \.id) { item in
                    favoriteCard(item)
                }
            }
            .padding(.horizontal, gridPadding)
            .padding(.top, CinemaSpacing.spacing3)

            Spacer(minLength: 80)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        #if os(iOS)
        .refreshable { await viewModel.load(using: appState) }
        #endif
    }

    @ViewBuilder
    private func favoriteCard(_ item: BaseItemDto) -> some View {
        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if let type = item.type { parts.append(type.rawValue) }
            return parts.joined(separator: " · ")
        }()

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    /// Warms Nuke for every card — URLs mirror the card's own request exactly
    /// (primary, maxWidth 300, tag) so the prefetch and render hit the same
    /// cache entry. See `PosterPrefetcher`.
    private func prefetchPosters() {
        let builder = appState.imageBuilder
        prefetcher.prefetch(viewModel.items.map { item in
            item.id.map { builder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) }
        })
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        AdaptiveLayout.posterGridColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        20
        #endif
    }

    private var gridPadding: CGFloat {
        #if os(tvOS)
        48
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }
}
