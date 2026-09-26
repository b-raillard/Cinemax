import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Favorites")

/// Aggregated view of every hearted movie and series across all libraries —
/// the user's personal "watchlist". Reached via the "View All" affordance on
/// the Home Favorites row. Reuses the poster grid; un-hearting an item from its
/// detail screen removes it here via `.cinemaxFavoritesChanged`. Paginated
/// (40/page via `PaginatedLoader`, mirroring `MediaLibraryViewModel`'s
/// filtered grid) rather than a one-shot 200-item fetch.
@MainActor @Observable
final class FavoritesViewModel {
    let loader = PaginatedLoader<BaseItemDto>(pageSize: 40, identity: { $0.id })
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

    /// Notification-driven refresh — re-pulls the span already on screen instead
    /// of collapsing to page 0. The cards in this grid carry a context menu whose
    /// watched / favorite toggles raise the very notifications this answers, so a
    /// `load()` here yanked the user back to the top of their own list. Falls
    /// back to a full load when nothing has been paged in yet.
    func refresh(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        guard !loader.items.isEmpty else {
            await load(using: appState)
            return
        }
        await loader.refreshLoadedSpan { startIndex, limit in
            try await self.page(using: appState, userId: userId, startIndex: startIndex, limit: limit)
        }
    }

    private func fetchNextPage(using appState: AppState, userId: String) async {
        await loader.loadMore { startIndex in
            try await self.page(using: appState, userId: userId, startIndex: startIndex, limit: 40)
        }
    }

    /// The one query, shared by pagination and by `refresh` so the two can never
    /// disagree on sort/filter.
    private func page(
        using appState: AppState, userId: String, startIndex: Int, limit: Int
    ) async throws -> (items: [BaseItemDto], total: Int) {
        do {
            let result = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.movie, .series],
                sortBy: [.sortName],
                sortOrder: [.ascending],
                isFavorite: true,
                limit: limit,
                startIndex: startIndex,
                fieldSet: .card
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

/// Full-screen grid of the user's favorites. Two doors: PUSHED onto Home's
/// navigation stack (the Favoris row's « Voir tout »), and presented MODALLY
/// from Réglages → Compte (`isModal`, wrapped in its own `NavigationStack` by
/// `FavoritesSheet`). It never declares a `NavigationStack` itself: nesting one
/// under Home's would break the per-card `NavigationLink` pushes.
///
/// The Settings door exists because Home was the only one — a hidden Favoris
/// row, or a custom menu without Accueil, left the screen unreachable
/// (audit 2026-09-22, §5).
struct FavoritesScreen: View {
    /// Presented from Settings: carries its own Done / Menu exit and title,
    /// the way `WatchedHistoryScreen` does.
    var isModal = false

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var viewModel = FavoritesViewModel()
    @State private var prefetcher = PosterPrefetcher()
    /// Card → fiche zoom (iOS) — see `CardZoom`.
    @Namespace private var zoomNamespace

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            #if os(tvOS)
            if isModal {
                VStack(spacing: 0) {
                    tvModalHeader
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // On the stack's ROOT content, never on the presentation: an
                // ancestor `onExitCommand` swallows the pop of a fiche pushed
                // from a card. Only in the modal branch — the pushed screen
                // must keep Home's own Menu routing (and a `nil` handler
                // would send the app to the background).
                .onExitCommand { dismiss() }
            } else {
                content
            }
            #else
            content
            #endif
        }
        #if os(iOS)
        .navigationTitle(loc.localized("home.favorites"))
        .navigationBarTitleDisplayMode(isModal ? .inline : .large)
        .toolbar {
            if isModal {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.done")) { dismiss() }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
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
        // Raised by this grid's OWN card menus, among others — so refresh the
        // span on screen rather than collapsing to page 0 under the user's finger.
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxFavoritesChanged)) { _ in
            Task { await viewModel.refresh(using: appState) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            Task {
                prefetcher.reset()
                await viewModel.load(using: appState)
            }
        }
        // A per-item watched/resume toggle (tier-2) — refresh immediately so an
        // un-watch drops the item while this grid is on screen. Same span-preserving
        // path as above: the toggle usually comes from a card in this very grid.
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxItemUserDataChanged)) { _ in
            Task { await viewModel.refresh(using: appState) }
        }
        // `tvPushedScreen()` is applied at Home's push site, not here: this
        // screen is also a modal root (Settings), which must not register as a
        // pushed screen.
    }

    #if os(tvOS)
    /// Title + Done, as `WatchedHistoryScreen.tvHeader`: Done guarantees a
    /// focusable in the loading / empty / error states, where Menu alone would
    /// have nothing to land on.
    private var tvModalHeader: some View {
        HStack(alignment: .center) {
            Text(loc.localized("home.favorites"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)
            Spacer(minLength: CinemaSpacing.spacing6)
            CinemaButton(title: loc.localized("action.done"), style: .accent) {
                dismiss()
            }
            .frame(width: CinemaTVLayout.ctaWidth)
        }
        .padding(.horizontal, CinemaTVLayout.pagePadding)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
        .focusSection()
    }
    #endif

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
                illustration: .noFavorites,
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
            // tvOS has no navigation bar — carry the title in-scroll (the modal
            // carries it in its header instead).
            if !isModal {
            Text(loc.localized("home.favorites"))
                .font(CinemaFont.display(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, gridPadding)
                .padding(.top, CinemaSpacing.spacing5)
            }
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
            if let type = item.type, let kind = loc.itemKind(type) { parts.append(kind) }
            return parts.joined(separator: " · ")
        }()
        let zoom = CardZoom(zoomNamespace, surface: "favorites", itemId: item.id)
        // One value feeds both the overlay and VoiceOver, so the card
        // cannot announce a state it does not draw.
        let status = MediaCardStatus.make(
            positionTicks: item.userData?.playbackPositionTicks,
            runtimeTicks: item.runTimeTicks,
            isPlayed: item.userData?.isPlayed
        )

        NavigationLink {
            DeferredView {
                if let id = item.id {
                    MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                }
            }
            .cardZoomDestination(zoom)
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) },
                subtitle: subtitle,
                status: status,
                zoomSource: zoom
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))
        .mediaCardStatusAccessibility(status)
        // On the NavigationLink (the focusable button), never its label,
        // so tvOS focus is untouched.
        .mediaCardContextMenu(item: item, artwork: .poster)
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
        CinemaTVLayout.posterGridColumns
        #else
        AdaptiveLayout.posterGridColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.gridGutter
        #else
        20
        #endif
    }

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pagePadding
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }
}

/// Favorites as a modal from Réglages → Compte: its own `NavigationStack`, so
/// a card still pushes its fiche. The caller re-injects the environment (a
/// presentation does not inherit it).
struct FavoritesSheet: View {
    var body: some View {
        NavigationStack {
            FavoritesScreen(isModal: true)
        }
    }
}
