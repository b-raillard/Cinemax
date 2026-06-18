import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - Unified Media Library Screen

struct MediaLibraryScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(NetworkMonitor.self) private var network
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var viewModel: MediaLibraryViewModel
    @State private var prefetcher = PosterPrefetcher()
    @State private var showSortFilter = false
    #if os(iOS)
    /// Lifted from `AdminItemMenu` so `navigationDestination(item:)` can
    /// live outside the lazy grid/row hosting the poster cards. The menu
    /// fires `onSelectDestination(_:)` and the card forwards it via
    /// `onAdminAction:` — we bind the resulting `AdminMenuPushIntent`
    /// here and host the destination on the body's outer ZStack.
    @State private var adminPushIntent: AdminMenuPushIntent?
    #endif
    #if os(tvOS)
    @State private var showSortPicker = false
    #endif
    /// Library landing layout preference (browse vs flat grid). Cross-platform:
    /// `grid` ("Show all") forces the flat grid even at the default landing;
    /// `browse` ("By genre") keeps each platform's default landing.
    @AppStorage(SettingsKey.libraryTVBrowseLayout) private var libraryTVBrowseLayout: String = SettingsKey.Default.libraryTVBrowseLayout

    /// `nil` for library tabs of Other / Mixed kind — disables the
    /// `includeItemTypes` filter at query time so every item in the parent
    /// folder surfaces. The screen still needs a concrete kind for layout
    /// decisions in sub-components; those default to `.movie` via the
    /// `displayKind` helper.
    let itemType: BaseItemKind?
    /// When non-nil, all queries scope to a specific Jellyfin library
    /// (a.k.a. user view) — used by the custom-menu library mode so each
    /// library tab fetches only its own contents. The override title
    /// surfaces the library name in place of the generic "Movies" / "TV Shows".
    let parentId: String?
    let overrideTitle: String?

    init(itemType: BaseItemKind?, parentId: String? = nil, overrideTitle: String? = nil) {
        self.itemType = itemType
        self.parentId = parentId
        self.overrideTitle = overrideTitle
        _viewModel = State(initialValue: MediaLibraryViewModel(itemType: itemType, parentId: parentId))
    }

    /// Concrete kind used for layout fall-back (hero aspect ratios, poster
    /// styles, sub-component APIs that require a `BaseItemKind`). Defaults
    /// to `.movie` for mixed / Other libraries — same poster ratio as
    /// series, so the visual cost of being wrong is small.
    private var displayKind: BaseItemKind { itemType ?? .movie }

    private var screenTitle: String {
        if let overrideTitle { return overrideTitle }
        return itemType == .series ? loc.localized("tvShows.title") : loc.localized("movies.title")
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            #if os(iOS)
            if !network.isOnline {
                OfflineLibraryView(scope: itemType == .series ? .series : .movies)
            } else if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else {
                mainContent
            }
            #else
            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else {
                mainContent
            }
            #endif
        }
        #if os(iOS)
        // Lifted out of `AdminItemMenu` so SwiftUI honors it — the menu's
        // host (`LibraryPosterCard`) lives inside `LazyVGrid`/`LazyHStack`,
        // and SwiftUI silently ignores `navigationDestination` placed
        // inside lazy containers. The outer ZStack here is eager.
        .navigationDestination(item: $adminPushIntent) { intent in
            adminMenuPushDestination(for: intent)
        }
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                filterButton
            }
        }
        .sheet(isPresented: $showSortFilter) {
            makeSortFilterSheet()
        }
        #else
        // tvOS: use `.fullScreenCover`. `.sheet` renders as a narrow centered
        // modal with a broken NavigationStack toolbar — see the bug we fixed
        // by giving the sheet its own tvOS body in `LibrarySortFilterSheet`.
        .fullScreenCover(isPresented: $showSortFilter) {
            makeSortFilterSheet()
                .environment(themeManager)
                .environment(loc)
        }
        .confirmationDialog(loc.localized("sort.by"), isPresented: $showSortPicker, titleVisibility: .visible) {
            ForEach(tvSortDirectionalOptions, id: \.id) { option in
                Button(option.label) {
                    viewModel.sortFilter.sortBy = option.value
                    viewModel.sortFilter.sortAscending = option.ascending
                }
            }
        }
        #endif
        .task {
            await viewModel.loadInitial(using: appState, loc: loc)
            prefetchBrowsePosters()
        }
        // Each filtered page that lands gets its posters warmed; the count is
        // a cheap Equatable proxy for "a page was appended".
        .onChange(of: viewModel.filteredLoader.items.count) {
            prefetchPosters(for: viewModel.filteredLoader.items)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            Task {
                prefetcher.reset()
                await viewModel.reload(using: appState, loc: loc)
                prefetchBrowsePosters()
            }
        }
    }

    // MARK: - Image prefetch

    /// Warms every genre row's posters once the browse data is in. URLs match
    /// `LibraryPosterCard`'s request exactly (primary, maxWidth 300, tag).
    private func prefetchBrowsePosters() {
        prefetchPosters(for: viewModel.itemsByGenre.values.flatMap { $0 })
    }

    private func prefetchPosters(for items: [BaseItemDto]) {
        let builder = appState.imageBuilder
        prefetcher.prefetch(items.map { item in
            item.id.map { builder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) }
        })
    }

    // MARK: Main Content Switch

    @ViewBuilder
    private var mainContent: some View {
        if shouldShowFilteredView {
            filteredView
        } else {
            browseView
        }
    }

    /// Filtered grid is shown when:
    /// - The user picked the "Show all" (grid) layout in Settings → Appearance
    ///   (both platforms) — the flat grid is the landing.
    /// - Otherwise, each platform's default rule: iOS switches to grid on any
    ///   non-default state (sort or filter); tvOS only on an active *filter*
    ///   (sort changes alone stay in browse).
    private var shouldShowFilteredView: Bool {
        if LibraryTVBrowseLayout(rawValue: libraryTVBrowseLayout) == .grid { return true }
        #if os(tvOS)
        return viewModel.sortFilter.isFiltered
        #else
        return viewModel.sortFilter.isNonDefault
        #endif
    }

    // MARK: Browse View (hero + genre rows + browse-genres grid)

    /// Shared between iOS and tvOS. tvOS additionally wraps the content in a
    /// `ScrollViewReader` so we can scroll back to the `library.top` anchor
    /// when the screen reappears (reveals the top tab bar after deep nav).
    private var browseView: some View {
        #if os(tvOS)
        ScrollViewReader { proxy in
            ScrollView {
                browseStack
            }
            .scrollClipDisabled()
            .refreshable { await viewModel.reload(using: appState, loc: loc) }
            .task(id: viewModel.sortFilter) {
                if !viewModel.genres.isEmpty {
                    await viewModel.reloadGenreItems(using: appState)
                }
            }
            .onAppear { proxy.scrollTo("library.top", anchor: .top) }
        }
        #else
        ScrollView {
            browseStack
        }
        .refreshable { await viewModel.reload(using: appState, loc: loc) }
        #endif
    }

    /// Vertical stack shared by iOS and tvOS browse views. tvOS prepends the
    /// compact top bar (sort menu + filters button + count) so it sits above
    /// the hero; iOS uses the navigation toolbar instead.
    @ViewBuilder
    private var browseStack: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            #if os(tvOS)
            Color.clear.frame(height: 0).id("library.top")
            tvTopBar
                .padding(.bottom, CinemaSpacing.spacing4)
            #endif

            if let hero = viewModel.heroItem {
                LibraryHeroSection(item: hero, itemType: displayKind)
                    .padding(.bottom, CinemaSpacing.spacing6)
            }

            ForEach(viewModel.genres.prefix(viewModel.genreLoadLimit), id: \.self) { genre in
                if let items = viewModel.itemsByGenre[genre], !items.isEmpty {
                    #if os(iOS)
                    LibraryGenreRow(
                        genre: genre,
                        items: items,
                        itemType: displayKind,
                        onViewAll: {
                            viewModel.sortFilter.selectedGenres = [genre]
                        },
                        onAdminAction: { item, dest in
                            adminPushIntent = AdminMenuPushIntent(item: item, destination: dest)
                        }
                    )
                    .padding(.bottom, CinemaSpacing.spacing6)
                    #else
                    LibraryGenreRow(genre: genre, items: items, itemType: displayKind) {
                        viewModel.sortFilter.selectedGenres = [genre]
                    }
                    .padding(.bottom, CinemaSpacing.spacing6)
                    #endif
                }
            }

            if !viewModel.genres.isEmpty {
                browseGenresSection
                    .padding(.bottom, CinemaSpacing.spacing6)
            }

            Spacer(minLength: 80)
        }
    }

    // MARK: Filtered View (iOS)

    private var filteredColumns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        AdaptiveLayout.posterGridColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var filteredView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    #if os(tvOS)
                    Color.clear.frame(height: 0).id("library.top")
                    tvTopBar
                    #else
                    Text(loc.localized(itemType == .series ? "tvShows.count" : "movies.count", viewModel.filteredLoader.totalCount))
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.horizontal, gridPadding)
                    #endif

                    if viewModel.filteredLoader.items.isEmpty && viewModel.filteredLoader.isLoadingMore {
                        filteredLoadingState
                    } else if viewModel.filteredLoader.items.isEmpty {
                        filteredEmptyState
                    } else {
                        LazyVGrid(columns: filteredColumns, spacing: gridSpacing) {
                            ForEach(viewModel.filteredLoader.items, id: \.id) { item in
                                #if os(iOS)
                                LibraryPosterCard(
                                    item: item,
                                    itemType: displayKind,
                                    onAdminAction: { item, dest in
                                        adminPushIntent = AdminMenuPushIntent(item: item, destination: dest)
                                    }
                                )
                                .id(item.id)
                                .onAppear { maybeLoadMore(triggerId: item.id) }
                                #else
                                LibraryPosterCard(item: item, itemType: displayKind)
                                    .id(item.id)
                                    .onAppear { maybeLoadMore(triggerId: item.id) }
                                #endif
                            }
                        }
                        .padding(.horizontal, gridPadding)

                        if viewModel.filteredLoader.isLoadingMore {
                            filteredPaginationFooter
                        }
                    }

                    Spacer(minLength: 80)
                }
                .padding(.top, CinemaSpacing.spacing3)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .refreshable {
                await viewModel.reload(using: appState, loc: loc)
            }
            .task(id: viewModel.sortFilter) {
                await viewModel.applyFilter(using: appState)
            }
            #if os(tvOS)
            .onAppear { proxy.scrollTo("library.top", anchor: .top) }
            #endif
            #if os(iOS)
            .overlay(alignment: .trailing) {
                if shouldShowJumpBar {
                    AlphabeticalJumpBar(
                        accent: themeManager.accent,
                        onSelect: { letter in
                            if let target = firstItemID(for: letter) {
                                withAnimation { proxy.scrollTo(target, anchor: .top) }
                            }
                        }
                    )
                    .padding(.trailing, CinemaSpacing.spacing2)
                }
            }
            #endif
        }
    }

    // MARK: - tvOS Compact Top Bar

    #if os(tvOS)
    /// Compact top bar that replaces the previous full-screen filter wall:
    /// title + count on the left, sort menu and filters button on the right.
    /// Filter detail (chips for watch status / decade / genre) lives inside
    /// the shared `LibrarySortFilterSheet` — one focusable button reaches
    /// all of it, freeing the entire viewport for posters and the hero.
    private var tvTopBar: some View {
        HStack(alignment: .center, spacing: CinemaSpacing.spacing4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(screenTitle)
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityAddTraits(.isHeader)

                Text(loc.localized("movies.titles", viewModel.sortFilter.isFiltered ? viewModel.filteredLoader.totalCount : viewModel.totalCount))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }

            Spacer()

            tvSortButton
            tvFilterSheetButton
        }
        .padding(.horizontal, CinemaSpacing.spacing20)
        // Group sort/filter as a discrete focus section so up-presses from the
        // hero's Play/More Info row reliably bridge the ~700pt of empty hero
        // backdrop and land on the top bar (and ultimately escape upward to
        // the tab bar) instead of getting absorbed by the hero's own bounds.
        .focusSection()
    }

    /// Opens a `confirmationDialog` listing every sort field doubled by direction
    /// (e.g. "Date Added ↓", "Date Added ↑"). Direction-as-separate-items keeps
    /// the action one focused click away — re-tap-to-reverse never worked well
    /// with remote navigation.
    private var tvSortButton: some View {
        Button {
            showSortPicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                Text(currentSortLabel)
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(CinemaColor.onSurface)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(Capsule())
        }
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
    }

    /// Opens `LibrarySortFilterSheet` (full-screen overlay on tvOS). Active
    /// state mirrors iOS: filled icon + accent background + numeric badge
    /// when filters are applied.
    private var tvFilterSheetButton: some View {
        let isActive = viewModel.sortFilter.isFiltered
        return Button {
            showSortFilter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle\(isActive ? ".fill" : "")")
                    .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                Text(loc.localized("library.filter.button"))
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                if isActive {
                    Text("\(activeFilterCount)")
                        .font(.system(size: CinemaScale.pt(14), weight: .bold))
                        .foregroundStyle(themeManager.onAccent)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Circle().fill(CinemaColor.onSurface.opacity(0.25)))
                }
            }
            .foregroundStyle(isActive ? themeManager.onAccent : CinemaColor.onSurface)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(isActive ? themeManager.accentContainer : CinemaColor.surfaceContainerHigh)
            .clipShape(Capsule())
        }
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
    }

    /// Sort options × direction. Each label encodes both, so the dialog is
    /// flat and one focused click commits both sortBy and sortAscending.
    private var tvSortDirectionalOptions: [(id: String, label: String, value: ItemSortBy, ascending: Bool)] {
        let fields: [(label: String, value: ItemSortBy, ascendingFirst: Bool)] = [
            (loc.localized("sort.dateAdded"), .dateCreated, false),       // newest first feels natural
            (loc.localized("sort.name"), .sortName, true),                // A→Z first
            (loc.localized("sort.releaseYear"), .productionYear, false),  // newest first
            (loc.localized("sort.rating"), .communityRating, false)       // highest first
        ]
        var out: [(String, String, ItemSortBy, Bool)] = []
        for f in fields {
            let descLabel = "\(f.label) ↓"
            let ascLabel = "\(f.label) ↑"
            if f.ascendingFirst {
                out.append((f.value.rawValue + ".asc", ascLabel, f.value, true))
                out.append((f.value.rawValue + ".desc", descLabel, f.value, false))
            } else {
                out.append((f.value.rawValue + ".desc", descLabel, f.value, false))
                out.append((f.value.rawValue + ".asc", ascLabel, f.value, true))
            }
        }
        return out
    }

    /// Label shown on the sort button — current field + direction arrow.
    private var currentSortLabel: String {
        let fieldLabel: String
        switch viewModel.sortFilter.sortBy {
        case .dateCreated:     fieldLabel = loc.localized("sort.dateAdded")
        case .sortName:        fieldLabel = loc.localized("sort.name")
        case .productionYear:  fieldLabel = loc.localized("sort.releaseYear")
        case .communityRating: fieldLabel = loc.localized("sort.rating")
        default:               fieldLabel = loc.localized("sort.dateAdded")
        }
        return "\(fieldLabel) \(viewModel.sortFilter.sortAscending ? "↑" : "↓")"
    }

    /// Count of active filters shown as a numeric badge on the filters button.
    private var activeFilterCount: Int {
        viewModel.sortFilter.selectedGenres.count
            + viewModel.sortFilter.selectedDecades.count
            + (viewModel.sortFilter.showUnwatchedOnly ? 1 : 0)
    }
    #endif

    // MARK: - Browse Genres Section

    private var browseGenresSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Text(loc.localized("tvShows.browseGenres"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.horizontal, browseGenresPadding)
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: browseGenresColumns, spacing: CinemaSpacing.spacing3) {
                ForEach(viewModel.genres, id: \.self) { genre in
                    genreCard(genre)
                }
            }
            .padding(.horizontal, browseGenresPadding)
        }
    }

    @ViewBuilder
    private func genreCard(_ genre: String) -> some View {
        Button {
            viewModel.sortFilter.selectedGenres = [genre]
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                    .fill(CinemaColor.surfaceContainerHigh)

                Text(genre)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .multilineTextAlignment(.center)
                    .padding(CinemaSpacing.spacing4)
            }
            .frame(height: genreCardHeight)
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }

    // MARK: - Pagination Trigger

    /// Guards pagination against SwiftUI calling `.onAppear` multiple times for the
    /// same card (view recycling, off-screen-and-back, parent re-renders). Previously
    /// each call spawned a Task that queued behind `PaginatedLoader`'s actor guard —
    /// correct but wasteful. Now we check `isLoadingMore` / `hasLoadedAll`
    /// synchronously before spawning, so redundant onAppears are free.
    private func maybeLoadMore(triggerId: String?) {
        let loader = viewModel.filteredLoader
        guard !loader.isLoadingMore,
              !loader.hasLoadedAll,
              let triggerId,
              triggerId == loader.items.last?.id else { return }
        Task { await viewModel.loadMoreFiltered(using: appState) }
    }

    // MARK: - Filter Button (iOS toolbar)

    #if os(iOS)
    /// iOS 26 navigation-bar toolbar items are rendered with Liquid Glass
    /// automatically — adding `.buttonStyle(.glass)` here would nest a glass
    /// capsule inside the toolbar's own glass container. Active-state signal
    /// is the `.fill` icon variant + accent tint on the label.
    @ViewBuilder
    private var filterButton: some View {
        let button = Button {
            showSortFilter = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle\(viewModel.sortFilter.isNonDefault ? ".fill" : "")")
                    .font(.system(size: filterIconSize, weight: .semibold))
                Text(loc.localized("movies.sortFilter"))
                    .font(.system(size: filterLabelSize, weight: .semibold))
                if viewModel.sortFilter.isFiltered {
                    let filterCount =
                        viewModel.sortFilter.selectedGenres.count
                        + viewModel.sortFilter.selectedDecades.count
                        + (viewModel.sortFilter.showUnwatchedOnly ? 1 : 0)
                    ZStack {
                        Circle()
                            .fill(CinemaColor.onSurface.opacity(0.25))
                        Text("\(filterCount)")
                            .font(.system(size: CinemaScale.pt(11), weight: .bold))
                    }
                    .frame(width: 20, height: 20)
                }
            }
        }

        if viewModel.sortFilter.isNonDefault {
            button.tint(themeManager.accent)
        } else {
            button
        }
    }
    #endif

    // MARK: - Loading & Error

    /// Layout-shaped placeholder for the initial load — mirrors the browse
    /// view's hero + poster rows instead of a context-free spinner.
    private var loadingView: some View {
        MediaPageSkeleton(
            heroHeight: skeletonHeroHeight,
            rows: [.poster, .poster],
            posterCardWidth: skeletonPosterWidth,
            wideCardWidth: skeletonPosterWidth * 2,
            horizontalPadding: browseGenresPadding
        )
    }

    private var skeletonHeroHeight: CGFloat {
        #if os(tvOS)
        820
        #else
        AdaptiveLayout.heroHeight(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var skeletonPosterWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        AdaptiveLayout.posterCardWidth(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private func errorView(_ message: String) -> some View {
        ErrorStateView(message: message, retryTitle: loc.localized("action.retry")) {
            // `reload` (not `loadInitial`) — `loadInitial` latches `hasLoaded`
            // on success and is a no-op once attempted, so Retry must go through
            // the reload path that always re-fetches.
            Task { await viewModel.reload(using: appState, loc: loc) }
        }
    }

    // MARK: - Empty States

    // MARK: - Alphabetical Jump Bar (iOS)

    #if os(iOS)
    /// Only shown when the filtered view is actually alphabetically meaningful:
    /// the user has sorted by name ascending. Other sorts (date added, year, rating)
    /// wouldn't produce a coherent A→Z scroll.
    private var shouldShowJumpBar: Bool {
        viewModel.sortFilter.sortBy == .sortName
            && viewModel.sortFilter.sortAscending
            && viewModel.filteredLoader.items.count > 20
    }

    /// Returns the id of the first loaded item whose name begins with the given letter.
    /// "#" targets the first item starting with a digit or non-letter character.
    private func firstItemID(for letter: String) -> String? {
        let target = letter.uppercased()
        for item in viewModel.filteredLoader.items {
            guard let name = item.name else { continue }
            let first = String(name.prefix(1)).uppercased()
            if target == "#" {
                if first.first.map({ !$0.isLetter }) ?? false { return item.id }
            } else if first == target {
                return item.id
            }
        }
        return nil
    }
    #endif

    /// Shown in the filtered grid (iOS or tvOS) when the current sort/filter combination
    /// yields no results. Offers a "Clear filters" action that resets sort + filter state.
    private var filteredEmptyState: some View {
        EmptyStateView(
            systemImage: "line.3.horizontal.decrease.circle",
            title: loc.localized("empty.library.filtered.title"),
            subtitle: loc.localized("empty.library.filtered.subtitle"),
            actionTitle: loc.localized("empty.library.filtered.action")
        ) {
            viewModel.sortFilter = LibrarySortFilterState()
        }
    }

    /// Shown in place of the filtered grid on the *initial* load (items still empty,
    /// `isLoadingMore` is true). Pairs the spinner with an explanatory label so the
    /// UI doesn't look like a hung fetch.
    private var filteredLoadingState: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            ProgressView()
                .tint(CinemaColor.onSurfaceVariant)
                .scaleEffect(1.3)
            Text(loc.localized(itemType == .series ? "library.loading.series" : "library.loading.movies"))
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CinemaSpacing.spacing10)
    }

    /// Footer row under the filtered grid when paginating additional pages. Keeps the
    /// visual continuity of the grid instead of centering a mid-screen spinner.
    private var filteredPaginationFooter: some View {
        ProgressView()
            .tint(CinemaColor.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, CinemaSpacing.spacing6)
    }

    // MARK: - Sort & Filter Sheet

    private func makeSortFilterSheet() -> LibrarySortFilterSheet {
        LibrarySortFilterSheet(
            sortFilter: Binding(
                get: { viewModel.sortFilter },
                set: { viewModel.sortFilter = $0 }
            ),
            onApply: { Task { await viewModel.applyFilter(using: appState) } },
            availableGenres: viewModel.genres
        )
    }

    // MARK: - Adaptive Sizing

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        32
        #else
        16
        #endif
    }

    #if os(iOS)
    private var filterIconSize: CGFloat { CinemaScale.pt(16) }
    private var filterLabelSize: CGFloat { CinemaScale.pt(14) }
    #endif

    private var genreCardHeight: CGFloat {
        #if os(tvOS)
        100
        #else
        72
        #endif
    }

    private var browseGenresPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var browseGenresColumns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing3), count: 4)
        #else
        AdaptiveLayout.browseGenreColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }
}

