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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                tvFilterBar
                    .padding(.bottom, CinemaSpacing.spacing6)

                if viewModel.sortFilter.isFiltered {
                    // Filtered grid (genre selected)
                    if viewModel.filteredLoader.items.isEmpty && viewModel.filteredLoader.isLoadingMore {
                        ProgressView()
                            .tint(CinemaColor.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CinemaSpacing.spacing10)
                    } else {
                        LazyVGrid(columns: filteredColumns, spacing: gridSpacing) {
                            ForEach(viewModel.filteredLoader.items, id: \.id) { item in
                                posterCard(item)
                                    .onAppear {
                                        if item.id == viewModel.filteredLoader.items.last?.id {
                                            Task { await viewModel.loadMoreFiltered(using: appState) }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, CinemaSpacing.spacing20)
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
        .task(id: viewModel.sortFilter) {
            if viewModel.sortFilter.isFiltered {
                await viewModel.applyFilter(using: appState)
            } else if !viewModel.genres.isEmpty {
                await viewModel.reloadGenreItems(using: appState)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                Text(loc.localized(itemType == .series ? "tvShows.count" : "movies.count", viewModel.filteredLoader.totalCount))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.horizontal, gridPadding)

                if viewModel.filteredLoader.items.isEmpty && viewModel.filteredLoader.isLoadingMore {
                    ProgressView()
                        .tint(CinemaColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CinemaSpacing.spacing10)
                } else {
                    LazyVGrid(columns: filteredColumns, spacing: gridSpacing) {
                        ForEach(viewModel.filteredLoader.items, id: \.id) { item in
                            posterCard(item)
                                .onAppear {
                                    if item.id == viewModel.filteredLoader.items.last?.id {
                                        Task { await viewModel.loadMoreFiltered(using: appState) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, gridPadding)
                }

                Spacer(minLength: 80)
            }
            .padding(.top, CinemaSpacing.spacing3)
        }
        .task(id: viewModel.sortFilter) {
            await viewModel.applyFilter(using: appState)
        }
    }

    // MARK: - Hero Section

    @ViewBuilder
    private func heroSection(_ item: BaseItemDto) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let id = item.id {
                CinemaLazyImage(
                    url: appState.imageBuilder.imageURL(itemId: id, imageType: .backdrop, maxWidth: 1920),
                    fallbackIcon: nil,
                    fallbackBackground: CinemaColor.surfaceContainerLow
                )
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

            // Reset button — separate line, only when filters are active
            if viewModel.sortFilter.isNonDefault {
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
    #endif

    // MARK: - Genre Row

    @ViewBuilder
    private func genreRow(genre: String, items: [BaseItemDto]) -> some View {
        ContentRow(title: genre, showViewAll: true, onViewAll: {
            viewModel.sortFilter.selectedGenres = [genre]
        }) {
            ForEach(items, id: \.id) { item in
                posterCard(item)
                    .frame(width: posterCardWidth)
            }
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
                    ZStack {
                        Circle()
                            .fill(CinemaColor.onSurface.opacity(0.25))
                        Text("\(viewModel.sortFilter.selectedGenres.count)")
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

// MARK: - Sort & Filter Sheet

private struct LibrarySortFilterSheet: View {
    @Binding var sortFilter: LibrarySortFilterState
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    let onApply: () -> Void
    var availableGenres: [String] = []

    private var sortOptions: [(label: String, value: ItemSortBy)] {
        [
            (loc.localized("sort.dateAdded"), .dateCreated),
            (loc.localized("sort.name"), .sortName),
            (loc.localized("sort.releaseYear"), .productionYear),
            (loc.localized("sort.rating"), .communityRating),
            (loc.localized("sort.runtime"), .runtime)
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CinemaColor.surface.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                        sortSection
                        sortOrderSection
                        if !availableGenres.isEmpty {
                            genreSection
                        }
                        Spacer(minLength: 80)
                    }
                    .padding(.horizontal, CinemaSpacing.spacing4)
                    .padding(.top, CinemaSpacing.spacing4)
                }
            }
            .navigationTitle(loc.localized("movies.sortFilter"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.localized("action.apply")) {
                        onApply()
                        dismiss()
                    }
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.reset")) {
                        sortFilter = LibrarySortFilterState()
                        onApply()
                        dismiss()
                    }
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
    }

    // MARK: Sort By

    private var sortSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("sort.by"))

            VStack(spacing: 0) {
                ForEach(sortOptions, id: \.value.rawValue) { option in
                    sortRow(label: option.label, value: option.value)
                }
            }
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        }
    }

    @ViewBuilder
    private func sortRow(label: String, value: ItemSortBy) -> some View {
        let isSelected = sortFilter.sortBy == value

        Button {
            sortFilter.sortBy = value
        } label: {
            HStack {
                Text(label)
                    .font(CinemaFont.body)
                    .foregroundStyle(isSelected ? themeManager.accent : CinemaColor.onSurface)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .background(
                isSelected
                    ? themeManager.accent.opacity(0.08)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)

        if value != sortOptions.last?.value {
            Divider()
                .background(CinemaColor.outlineVariant)
                .padding(.leading, CinemaSpacing.spacing4)
        }
    }

    // MARK: Sort Order

    private var sortOrderSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("sort.order"))

            HStack(spacing: CinemaSpacing.spacing3) {
                orderChip(label: loc.localized("sort.ascending"), icon: "arrow.up", isAscending: true)
                orderChip(label: loc.localized("sort.descending"), icon: "arrow.down", isAscending: false)
            }
        }
    }

    @ViewBuilder
    private func orderChip(label: String, icon: String, isAscending: Bool) -> some View {
        let isSelected = sortFilter.sortAscending == isAscending

        Button {
            sortFilter.sortAscending = isAscending
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : CinemaColor.onSurfaceVariant)
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(
                isSelected
                    ? themeManager.accentContainer
                    : CinemaColor.surfaceContainerHigh
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Genre Filter

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            HStack {
                sectionHeader(loc.localized("filter.byGenre"))
                Spacer()
                if !sortFilter.selectedGenres.isEmpty {
                    Button {
                        sortFilter.selectedGenres = []
                    } label: {
                        Text(loc.localized("action.clear"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(themeManager.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            FlowLayout(spacing: CinemaSpacing.spacing2) {
                ForEach(availableGenres, id: \.self) { genre in
                    genreChip(genre)
                }
            }
        }
    }

    @ViewBuilder
    private func genreChip(_ genre: String) -> some View {
        let isSelected = sortFilter.selectedGenres.contains(genre)

        Button {
            if isSelected {
                sortFilter.selectedGenres.remove(genre)
            } else {
                sortFilter.selectedGenres.insert(genre)
            }
        } label: {
            Text(genre)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? .white : CinemaColor.onSurfaceVariant)
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.vertical, CinemaSpacing.spacing2)
                .background(
                    isSelected
                        ? themeManager.accentContainer
                        : CinemaColor.surfaceContainerHigh
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Section Header

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(CinemaFont.label(.large))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .textCase(.uppercase)
            .tracking(0.8)
    }
}

// MARK: - Flow Layout (wrapping chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var firstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !firstInRow && rowWidth + spacing + size.width > width {
                height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
                firstInRow = true
            } else {
                if !firstInRow { rowWidth += spacing }
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
                firstInRow = false
            }
        }
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var firstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !firstInRow && x + spacing + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
                firstInRow = true
            } else if !firstInRow {
                x += spacing
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
            firstInRow = false
        }
    }
}

// MARK: - tvOS Card Button Style

#if os(tvOS)
struct CinemaTVCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .brightness(isFocused ? 0.05 : 0)
            .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
            .animation(motionEnabled ? .easeInOut(duration: 0.1) : nil, value: configuration.isPressed)
    }
}

struct TVFilterChipButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .overlay(
                Capsule()
                    .strokeBorder(accent, lineWidth: isFocused ? 2 : 0)
            )
            .animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: isFocused)
            .animation(motionEnabled ? .easeInOut(duration: 0.1) : nil, value: configuration.isPressed)
    }
}
#endif
