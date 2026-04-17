import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - Unified Media Library Screen

struct MediaLibraryScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel: MediaLibraryViewModel
    @State private var showSortFilter = false

    let itemType: BaseItemKind

    init(itemType: BaseItemKind) {
        self.itemType = itemType
        _viewModel = State(initialValue: MediaLibraryViewModel(itemType: itemType))
    }

    private var screenTitle: String {
        itemType == .series ? loc.localized("tvShows.title") : loc.localized("movies.title")
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else {
                mainContent
            }
        }
        #if os(iOS)
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
        #endif
        .task {
            await viewModel.loadInitial(using: appState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            Task { await viewModel.reload(using: appState) }
        }
    }

    // MARK: Main Content Switch

    @ViewBuilder
    private var mainContent: some View {
        #if os(tvOS)
        tvMainContent
        #else
        if viewModel.sortFilter.isNonDefault {
            filteredView
        } else {
            browseView
        }
        #endif
    }

    // MARK: - tvOS Main Content (inline filter)

    #if os(tvOS)
    private var tvMainContent: some View {
        // ScrollViewReader so we can pop back to the top of the page (and reveal
        // the tvOS top tab bar) whenever the screen reappears after a deep nav.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("library.top")

                    tvFilterBar
                        .padding(.bottom, CinemaSpacing.spacing6)

                    if viewModel.sortFilter.isFiltered {
                        // Filtered grid (genre selected)
                        if viewModel.filteredLoader.items.isEmpty && viewModel.filteredLoader.isLoadingMore {
                            filteredLoadingState
                        } else if viewModel.filteredLoader.items.isEmpty {
                            filteredEmptyState
                        } else {
                            LazyVGrid(columns: filteredColumns, spacing: gridSpacing) {
                                ForEach(viewModel.filteredLoader.items, id: \.id) { item in
                                    posterCard(item)
                                        .onAppear { maybeLoadMore(triggerId: item.id) }
                                }
                            }
                            .padding(.horizontal, CinemaSpacing.spacing20)

                            if viewModel.filteredLoader.isLoadingMore {
                                filteredPaginationFooter
                            }
                        }
                    } else {
                        // Browse genre rows
                        ForEach(viewModel.genres.prefix(viewModel.genreLoadLimit), id: \.self) { genre in
                            if let items = viewModel.itemsByGenre[genre], !items.isEmpty {
                                genreRow(genre: genre, items: items)
                                    .padding(.bottom, CinemaSpacing.spacing6)
                            }
                        }

                        if !viewModel.genres.isEmpty {
                            browseGenresSection
                                .padding(.bottom, CinemaSpacing.spacing6)
                        }
                    }

                    Spacer(minLength: 80)
                }
            }
            .scrollClipDisabled()
            .refreshable {
                await viewModel.reload(using: appState)
            }
            .task(id: viewModel.sortFilter) {
                if viewModel.sortFilter.isFiltered {
                    await viewModel.applyFilter(using: appState)
                } else if !viewModel.genres.isEmpty {
                    await viewModel.reloadGenreItems(using: appState)
                }
            }
            .onAppear {
                proxy.scrollTo("library.top", anchor: .top)
            }
        }
    }
    #endif

    // MARK: Browse View (iOS — genre rows + hero)

    private var browseView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let hero = viewModel.heroItem {
                    heroSection(hero)
                        .padding(.bottom, CinemaSpacing.spacing6)
                }

                ForEach(viewModel.genres.prefix(viewModel.genreLoadLimit), id: \.self) { genre in
                    if let items = viewModel.itemsByGenre[genre], !items.isEmpty {
                        genreRow(genre: genre, items: items)
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }
                }

                if !viewModel.genres.isEmpty {
                    browseGenresSection
                        .padding(.bottom, CinemaSpacing.spacing6)
                }

                Spacer(minLength: 80)
            }
        }
        .refreshable {
            await viewModel.reload(using: appState)
        }
    }

    // MARK: Filtered View (iOS)

    private var filteredColumns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
        #endif
    }

    private var filteredView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    Text(loc.localized(itemType == .series ? "tvShows.count" : "movies.count", viewModel.filteredLoader.totalCount))
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.horizontal, gridPadding)

                    if viewModel.filteredLoader.items.isEmpty && viewModel.filteredLoader.isLoadingMore {
                        filteredLoadingState
                    } else if viewModel.filteredLoader.items.isEmpty {
                        filteredEmptyState
                    } else {
                        LazyVGrid(columns: filteredColumns, spacing: gridSpacing) {
                            ForEach(viewModel.filteredLoader.items, id: \.id) { item in
                                posterCard(item)
                                    .id(item.id)
                                    .onAppear { maybeLoadMore(triggerId: item.id) }
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
            .refreshable {
                await viewModel.reload(using: appState)
            }
            .task(id: viewModel.sortFilter) {
                await viewModel.applyFilter(using: appState)
            }
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

    // MARK: - Hero Section

    @ViewBuilder
    private func heroSection(_ item: BaseItemDto) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let id = item.id {
                CinemaLazyImage(
                    url: appState.imageBuilder.imageURL(itemId: id, imageType: .backdrop, maxWidth: ImageURLBuilder.screenPixelWidth),
                    fallbackIcon: nil,
                    fallbackBackground: CinemaColor.surfaceContainerLow
                )
                .accessibilityHidden(true)
            }

            CinemaGradient.heroOverlay

            VStack(alignment: .leading, spacing: heroContentSpacing) {
                // Metadata badges
                HStack(spacing: 8) {
                    if let rating = item.officialRating {
                        RatingBadge(rating: rating)
                    }
                    heroMetadataText(for: item)
                }
                .foregroundStyle(CinemaColor.onSurfaceVariant)

                // Title
                Text(item.name ?? "")
                    .font(.system(size: heroTitleSize, weight: .black))
                    .tracking(-1.5)
                    .foregroundStyle(.white)
                    .textCase(.uppercase)
                    .lineLimit(2)

                // Overview — hidden on iOS to keep hero compact
                #if os(tvOS)
                if let overview = item.overview {
                    Text(overview)
                        .font(.system(size: overviewFontSize))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(3)
                        .frame(maxWidth: maxOverviewWidth, alignment: .leading)
                }
                #endif

                // Action buttons
                if let id = item.id {
                    heroActionButtons(id: id, item: item)
                }
            }
            .padding(.horizontal, heroPadding)
            .padding(.top, heroPadding)
            .padding(.bottom, heroPadding + CinemaSpacing.spacing6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
    }

    @ViewBuilder
    private func heroActionButtons(id: String, item: BaseItemDto) -> some View {
        HStack(spacing: heroButtonSpacing) {
            PlayLink(itemId: id, title: item.name ?? "") {
                HStack(spacing: CinemaSpacing.spacing2) {
                    Text(loc.localized("action.play"))
                        .font(.system(size: heroButtonFontSize, weight: .bold))
                    Image(systemName: "play.fill")
                        .font(.system(size: heroButtonFontSize - 2, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, heroButtonVerticalPadding)
                .padding(.horizontal, CinemaSpacing.spacing4)
                #if os(iOS)
                .background(themeManager.accentContainer)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                #endif
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .accent))
            #else
            .buttonStyle(.plain)
            #endif
            .frame(width: heroButtonWidth)

            NavigationLink {
                MediaDetailScreen(itemId: id, itemType: itemType)
            } label: {
                HStack(spacing: CinemaSpacing.spacing2) {
                    Text(loc.localized("action.moreInfo"))
                        .font(.system(size: heroButtonFontSize, weight: .bold))
                        .lineLimit(1)
                    Image(systemName: "info.circle")
                        .font(.system(size: heroButtonFontSize - 2, weight: .bold))
                }
                .foregroundStyle(CinemaColor.onSurface)
                #if os(tvOS)
                .frame(maxWidth: .infinity)
                #endif
                .padding(.vertical, heroButtonVerticalPadding)
                .padding(.horizontal, CinemaSpacing.spacing4)
                #if os(iOS)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                #endif
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
            .frame(width: heroButtonWidth)
            #else
            .buttonStyle(.plain)
            .fixedSize()
            #endif
        }
    }

    // MARK: - tvOS Inline Filter Bar

    #if os(tvOS)
    private var tvFilterBar: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            // Title row
            HStack(alignment: .center) {
                Text(screenTitle)
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityAddTraits(.isHeader)

                Text(loc.localized("movies.titles", viewModel.sortFilter.isFiltered ? viewModel.filteredLoader.totalCount : viewModel.totalCount))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)

                Spacer()
            }

            // Sort section
            Text(loc.localized("sort.by"))
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .textCase(.uppercase)
                .tracking(0.8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tvSortOptions, id: \.value.rawValue) { option in
                        let isSelected = viewModel.sortFilter.sortBy == option.value
                        Button {
                            if isSelected {
                                viewModel.sortFilter.sortAscending.toggle()
                            } else {
                                viewModel.sortFilter.sortBy = option.value
                                viewModel.sortFilter.sortAscending = (option.value == .sortName || option.value == .communityRating)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(option.label)
                                    .font(.system(size: CinemaScale.pt(18), weight: isSelected ? .bold : .medium))
                                if isSelected {
                                    Image(systemName: viewModel.sortFilter.sortAscending ? "arrow.up" : "arrow.down")
                                        .font(.system(size: CinemaScale.pt(14), weight: .bold))
                                }
                            }
                            .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurface)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                isSelected
                                    ? themeManager.accentContainer
                                    : CinemaColor.surfaceContainerHigh
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
                        .focusEffectDisabled()
                        .hoverEffectDisabled()
                    }
                }
            }
            .scrollClipDisabled()

            // Watch Status section
            Text(loc.localized("filter.watchStatus"))
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .textCase(.uppercase)
                .tracking(0.8)

            HStack(spacing: 10) {
                let isSelected = viewModel.sortFilter.showUnwatchedOnly
                Button {
                    viewModel.sortFilter.showUnwatchedOnly.toggle()
                } label: {
                    Text(loc.localized("filter.unwatchedOnly"))
                        .font(.system(size: CinemaScale.pt(18), weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurface)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            isSelected
                                ? themeManager.accentContainer
                                : CinemaColor.surfaceContainerHigh
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
                .focusEffectDisabled()
                .hoverEffectDisabled()
            }

            // Decade section
            Text(loc.localized("filter.byDecade"))
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .textCase(.uppercase)
                .tracking(0.8)

            FlowLayout(spacing: 10) {
                ForEach(tvDecadeOptions, id: \.self) { decade in
                    let isSelected = viewModel.sortFilter.selectedDecades.contains(decade)
                    Button {
                        if isSelected {
                            viewModel.sortFilter.selectedDecades.remove(decade)
                        } else {
                            viewModel.sortFilter.selectedDecades.insert(decade)
                        }
                    } label: {
                        Text(loc.localized("filter.decade", decade))
                            .font(.system(size: CinemaScale.pt(18), weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurface)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                isSelected
                                    ? themeManager.accentContainer
                                    : CinemaColor.surfaceContainerHigh
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
                    .focusEffectDisabled()
                    .hoverEffectDisabled()
                }
            }

            // Genre section
            if !viewModel.genres.isEmpty {
                Text(loc.localized("filter.byGenre"))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .textCase(.uppercase)
                    .tracking(0.8)

                FlowLayout(spacing: 10) {
                    // "All" chip
                    let allSelected = viewModel.sortFilter.selectedGenres.isEmpty
                    Button {
                        viewModel.sortFilter.selectedGenres = []
                    } label: {
                        Text(loc.localized("tvShows.all"))
                            .font(.system(size: CinemaScale.pt(18), weight: allSelected ? .bold : .medium))
                            .foregroundStyle(allSelected ? themeManager.onAccent : CinemaColor.onSurface)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                allSelected
                                    ? themeManager.accentContainer
                                    : CinemaColor.surfaceContainerHigh
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
                    .focusEffectDisabled()
                    .hoverEffectDisabled()

                    ForEach(viewModel.genres, id: \.self) { genre in
                        let isSelected = viewModel.sortFilter.selectedGenres.contains(genre)
                        Button {
                            if isSelected {
                                viewModel.sortFilter.selectedGenres.remove(genre)
                            } else {
                                viewModel.sortFilter.selectedGenres.insert(genre)
                            }
                        } label: {
                            Text(genre)
                                .font(.system(size: CinemaScale.pt(18), weight: isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurface)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(
                                    isSelected
                                        ? themeManager.accentContainer
                                        : CinemaColor.surfaceContainerHigh
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
                        .focusEffectDisabled()
                        .hoverEffectDisabled()
                    }
                }
            }

            // Reset button (refresh moved to Settings > Server > Refresh Catalogue)
            if viewModel.sortFilter.isNonDefault {
                HStack(spacing: 10) {
                    Button {
                        viewModel.sortFilter = LibrarySortFilterState()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: CinemaScale.pt(18), weight: .medium))
                            Text(loc.localized("action.reset"))
                                .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                        }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(CinemaColor.surfaceContainerHigh)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
                    .focusEffectDisabled()
                    .hoverEffectDisabled()
                }
            }
        }
        .padding(.horizontal, CinemaSpacing.spacing20)
    }

    private var tvSortOptions: [(label: String, value: ItemSortBy)] {
        [
            (loc.localized("sort.dateAdded"), .dateCreated),
            (loc.localized("sort.name"), .sortName),
            (loc.localized("sort.releaseYear"), .productionYear),
            (loc.localized("sort.rating"), .communityRating)
        ]
    }

    /// Decades offered as chips on tvOS, most-recent-first.
    private var tvDecadeOptions: [Int] { [2020, 2010, 2000, 1990, 1980, 1970, 1960, 1950] }
    #endif

    // MARK: - Genre Row

    @ViewBuilder
    private func genreRow(genre: String, items: [BaseItemDto]) -> some View {
        ContentRow(
            title: genre,
            showViewAll: true,
            onViewAll: { viewModel.sortFilter.selectedGenres = [genre] },
            data: items,
            id: \.id
        ) { item in
            posterCard(item)
                .frame(width: posterCardWidth)
        }
    }

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

    // MARK: - Poster Card

    @ViewBuilder
    private func posterCard(_ item: BaseItemDto) -> some View {
        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if itemType == .series {
                if let count = item.childCount {
                    parts.append(loc.localized(count == 1 ? "tvShows.season" : "tvShows.seasonsPlural", count))
                }
            } else {
                if let rating = item.communityRating {
                    parts.append(String(format: "%.1f", rating))
                }
            }
            return parts.joined(separator: " · ")
        }()

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: itemType)
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300) },
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

    // MARK: - Filter Button

    private var filterButton: some View {
        Button {
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
                            .font(.system(size: 11, weight: .bold))
                    }
                    .frame(width: 20, height: 20)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                viewModel.sortFilter.isNonDefault
                    ? themeManager.accentContainer
                    : CinemaColor.surfaceContainerHigh
            )
            .clipShape(Capsule())
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: viewModel.sortFilter.isNonDefault ? .accent : .ghost))
        #else
        .buttonStyle(.plain)
        #endif
    }

    // MARK: - Loading & Error

    private var loadingView: some View { LoadingStateView() }

    private func errorView(_ message: String) -> some View {
        ErrorStateView(message: message, retryTitle: loc.localized("action.retry")) {
            Task { await viewModel.loadInitial(using: appState) }
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

    // MARK: - Hero Helpers

    private func heroMetadataText(for item: BaseItemDto) -> some View {
        let parts: [String] = [
            item.productionYear.map(String.init),
            itemType == .series
                ? item.childCount.map { loc.localized($0 == 1 ? "tvShows.season" : "tvShows.seasonsPlural", $0) }
                : item.formattedRuntime,
            item.genres?.first
        ].compactMap { $0 }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: metadataFontSize, weight: .medium))
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

    private var heroHeight: CGFloat {
        #if os(tvOS)
        820
        #else
        360
        #endif
    }

    private var heroTitleSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(72)
        #else
        20
        #endif
    }

    private var overviewFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(18)
        #else
        14
        #endif
    }

    private var heroPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        CinemaSpacing.spacing4
        #endif
    }

    private var heroContentSpacing: CGFloat {
        #if os(tvOS)
        16
        #else
        10
        #endif
    }

    private var maxOverviewWidth: CGFloat {
        #if os(tvOS)
        600
        #else
        300
        #endif
    }

    private var heroButtonWidth: CGFloat {
        #if os(tvOS)
        240
        #else
        160
        #endif
    }

    private var heroButtonFontSize: CGFloat {
        #if os(tvOS)
        28
        #else
        16
        #endif
    }

    private var heroButtonVerticalPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing4
        #else
        CinemaSpacing.spacing2
        #endif
    }

    private var heroButtonSpacing: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing5
        #else
        12
        #endif
    }

    private var posterCardWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        140
        #endif
    }

    private var metadataFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(16)
        #else
        CinemaScale.pt(13)
        #endif
    }

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        CinemaSpacing.spacing3
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        32
        #else
        16
        #endif
    }

    private var filterIconSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(24)
        #else
        CinemaScale.pt(16)
        #endif
    }

    private var filterLabelSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(22)
        #else
        CinemaScale.pt(14)
        #endif
    }

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
        CinemaSpacing.spacing6
        #endif
    }

    private var browseGenresColumns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing3), count: 4)
        #else
        Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing3), count: 2)
        #endif
    }
}

// MARK: - Convenience Wrappers

struct MovieLibraryScreen: View {
    var body: some View {
        MediaLibraryScreen(itemType: .movie)
    }
}

