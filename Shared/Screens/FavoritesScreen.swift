import SwiftUI
import OSLog
import CinemaxKit
@preconcurrency import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Favorites")

/// Aggregated view of every hearted movie and series across all libraries —
/// the user's personal "watchlist". Reached via the "View All" affordance on
/// the Home Favorites row. Reuses the poster grid; un-hearting an item from its
/// detail screen removes it here via `.cinemaxFavoritesChanged`. Paginated
/// (40/page via `PaginatedLoader`, mirroring `MediaLibraryViewModel`'s
/// filtered grid) rather than a one-shot 200-item fetch.
@MainActor @Observable
final class FavoritesViewModel {
    let loader = PaginatedLoader<BaseItemDto>(pageSize: 40)
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

    /// Full reload from page 0 — pull-to-refresh, and every catalogue /
    /// favorites / userData notification. Resets the paginator first so a
    /// stale page 2+ never survives under a changed favorites set.
    func load(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        hasLoaded = true
        isLoading = true
        loader.reset()
        await fetchNextPage(using: appState, userId: userId)
        isLoading = false
    }

    /// Pagination continuation — called from the grid's last-card `.onAppear`
    /// trigger.
    func loadMore(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        await fetchNextPage(using: appState, userId: userId)
    }

    private func fetchNextPage(using appState: AppState, userId: String) async {
        await loader.loadMore { startIndex in
            do {
                let result = try await appState.apiClient.getItems(
                    userId: userId,
                    includeItemTypes: [.movie, .series],
                    sortBy: [.sortName],
                    sortOrder: [.ascending],
                    isFavorite: true,
                    limit: 40,
                    startIndex: startIndex
                )
                self.loadFailed = false
                return (items: result.items, total: result.totalCount)
            } catch {
                logger.warning("Favorites load failed: \(error.localizedDescription, privacy: .public)")
                self.loadFailed = true
                throw error
            }
        }
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
        }
        // Each page that lands (initial or paginated) gets its posters warmed;
        // the count is a cheap Equatable proxy for "a page was appended" —
        // mirrors `MediaLibraryScreen`'s filtered-grid prefetch.
        .onChange(of: viewModel.loader.items.count) {
            prefetchPosters()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxFavoritesChanged)) { _ in
            Task { await viewModel.load(using: appState) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            Task {
                prefetcher.reset()
                await viewModel.load(using: appState)
            }
        }
        // A per-item watched/resume toggle (tier-2) — reload immediately so an
        // un-watch drops the item while this grid is on screen.
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxItemUserDataChanged)) { _ in
            Task { await viewModel.load(using: appState) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.loader.items.isEmpty {
            LoadingStateView()
        } else if viewModel.loadFailed && viewModel.loader.items.isEmpty {
            ErrorStateView(message: loc.localized("error.generic"), retryTitle: loc.localized("action.retry")) {
                Task { await viewModel.load(using: appState) }
            }
        } else if viewModel.loader.items.isEmpty {
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
                ForEach(viewModel.loader.items, id: \.id) { item in
                    favoriteCard(item)
                        .onAppear { maybeLoadMore(triggerId: item.id) }
                }
            }
            .padding(.horizontal, gridPadding)
            .padding(.top, CinemaSpacing.spacing3)

            if viewModel.loader.isLoadingMore {
                paginationFooter
            }

            Spacer(minLength: 80)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        #if os(iOS)
        .refreshable { await viewModel.load(using: appState) }
        #endif
    }

    /// Footer row under the grid while paginating additional pages — keeps
    /// visual continuity instead of centering a mid-screen spinner. Mirrors
    /// `MovieLibraryScreen.filteredPaginationFooter`.
    private var paginationFooter: some View {
        ProgressView()
            .tint(CinemaColor.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, CinemaSpacing.spacing6)
    }

    /// Guards pagination against SwiftUI calling `.onAppear` multiple times for
    /// the same card. Mirrors `MovieLibraryScreen.maybeLoadMore`.
    private func maybeLoadMore(triggerId: String?) {
        let loader = viewModel.loader
        guard !loader.isLoadingMore,
              !loader.hasLoadedAll,
              let triggerId,
              triggerId == loader.items.last?.id else { return }
        Task { await viewModel.loadMore(using: appState) }
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
        prefetcher.prefetch(viewModel.loader.items.map { item in
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
