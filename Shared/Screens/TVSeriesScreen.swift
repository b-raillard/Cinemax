import SwiftUI
import NukeUI
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - Sort Option

enum TVSeriesSortOption: String, CaseIterable, Identifiable {
    case name = "Name"
    case dateAdded = "Date Added"
    case year = "Year"
    case rating = "Rating"
    case random = "Random"

    var id: String { rawValue }

    var sortBy: ItemSortBy {
        switch self {
        case .name: .sortName
        case .dateAdded: .dateCreated
        case .year: .productionYear
        case .rating: .communityRating
        case .random: .random
        }
    }
}

// MARK: - View Model

@MainActor @Observable
final class TVSeriesViewModel {
    // Discovery state
    var featuredShow: BaseItemDto?
    var genres: [String] = []
    var itemsByGenre: [String: [BaseItemDto]] = [:]

    // Filtered/flat grid state
    var filteredItems: [BaseItemDto] = []
    var filteredTotalCount = 0
    private var filteredHasLoadedAll = false
    private let pageSize = 40

    // Filter & sort state
    var selectedSortOption: TVSeriesSortOption = .name
    var sortAscending = true
    var selectedGenre: String? = nil
    var isFilterActive: Bool { selectedGenre != nil }

    // UI state
    var isLoading = true
    var isLoadingGenreRows = false
    var errorMessage: String?

    // MARK: Load

    func loadInitial(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true
        errorMessage = nil

        do {
            // Load genres and featured show concurrently
            async let genresFetch = appState.apiClient.getGenres(userId: userId, includeItemTypes: [.series])
            async let featuredFetch = appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.series],
                sortBy: [.random],
                limit: 1
            )

            let fetchedGenres = try await genresFetch
            let featuredResult = try await featuredFetch

            genres = fetchedGenres
            featuredShow = featuredResult.items.first
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false

        // Load genre rows in the background after initial render
        await loadGenreRows(using: appState)
    }

    func loadGenreRows(using appState: AppState) async {
        guard let userId = appState.currentUserId, !genres.isEmpty else { return }
        isLoadingGenreRows = true

        await withTaskGroup(of: (String, [BaseItemDto]).self) { group in
            for genre in genres {
                group.addTask {
                    do {
                        let result = try await appState.apiClient.getItems(
                            userId: userId,
                            includeItemTypes: [.series],
                            sortBy: [.random],
                            genres: [genre],
                            limit: 10
                        )
                        return (genre, result.items)
                    } catch {
                        return (genre, [])
                    }
                }
            }

            for await (genre, items) in group where !items.isEmpty {
                itemsByGenre[genre] = items
            }
        }

        isLoadingGenreRows = false
    }

    // MARK: Filtered Load

    func loadFiltered(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        filteredHasLoadedAll = false
        filteredItems = []

        do {
            let result = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.series],
                sortBy: [selectedSortOption.sortBy],
                sortOrder: sortAscending ? [.ascending] : [.descending],
                genres: selectedGenre.map { [$0] },
                limit: pageSize
            )
            filteredItems = result.items
            filteredTotalCount = result.totalCount
            filteredHasLoadedAll = filteredItems.count >= result.totalCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreFiltered(using appState: AppState) async {
        guard !filteredHasLoadedAll,
              let userId = appState.currentUserId else { return }

        do {
            let result = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.series],
                sortBy: [selectedSortOption.sortBy],
                sortOrder: sortAscending ? [.ascending] : [.descending],
                genres: selectedGenre.map { [$0] },
                limit: pageSize,
                startIndex: filteredItems.count
            )
            filteredItems.append(contentsOf: result.items)
            filteredHasLoadedAll = filteredItems.count >= result.totalCount
        } catch {
            // Silently fail on pagination
        }
    }

    // MARK: Filter Actions

    func applyGenreFilter(_ genre: String?, using appState: AppState) async {
        selectedGenre = genre
        await loadFiltered(using: appState)
    }

    func applySortAndFilter(using appState: AppState) async {
        await loadFiltered(using: appState)
    }

    func resetFilters(using appState: AppState) async {
        selectedGenre = nil
        selectedSortOption = .name
        sortAscending = true
        await loadFiltered(using: appState)
    }
}

// MARK: - Main Screen

struct TVSeriesScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel = TVSeriesViewModel()
    @State private var showFilterSheet = false

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
        .navigationTitle(loc.localized("tvShows.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                filterButton
            }
        }
        #endif
        .sheet(isPresented: $showFilterSheet) {
            TVSeriesFilterSheet(viewModel: viewModel) {
                Task { await viewModel.applySortAndFilter(using: appState) }
            }
        }
        .task {
            await viewModel.loadInitial(using: appState)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        ProgressView()
            .tint(CinemaColor.onSurfaceVariant)
            .scaleEffect(1.5)
    }

    // MARK: - Filter Button

    private var filterButton: some View {
        Button {
            showFilterSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(viewModel.isFilterActive ? themeManager.accent : CinemaColor.onSurface)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isFilterActive {
            filteredGridView
        } else {
            discoveryView
        }
    }

    // MARK: - Discovery Layout

    private var discoveryView: some View {
        ScrollView {
            LazyVStack(spacing: CinemaSpacing.spacing6) {
                // Hero
                if let hero = viewModel.featuredShow {
                    heroSection(hero)
                }

                // Genre rows
                if viewModel.isLoadingGenreRows && viewModel.itemsByGenre.isEmpty {
                    genreRowsPlaceholder
                } else {
                    genreRows
                }

                // Browse Genres
                if !viewModel.genres.isEmpty {
                    browseGenresSection
                }

                Spacer(minLength: 80)
            }
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    // MARK: - Hero Section

    @ViewBuilder
    private func heroSection(_ item: BaseItemDto) -> some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        ZStack(alignment: .bottomLeading) {
            // Backdrop image
            if let id = item.id {
                LazyImage(url: builder.imageURL(itemId: id, imageType: .backdrop, maxWidth: 1920)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(CinemaColor.surfaceContainerLow)
                    }
                }
            }

            // Gradient overlay
            CinemaGradient.heroOverlay

            // Content
            VStack(alignment: .leading, spacing: heroContentSpacing) {
                // Metadata badges
                HStack(spacing: 8) {
                    if let rating = item.officialRating {
                        Text(rating)
                            .font(.system(size: heroBadgeFontSize, weight: .bold))
                            .tracking(1)
                            .textCase(.uppercase)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }

                    heroMetadata(for: item)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }

                // Title
                Text(item.name ?? "")
                    .font(.system(size: heroTitleSize, weight: .black))
                    .tracking(-1.5)
                    .foregroundStyle(.white)
                    .textCase(.uppercase)
                    .lineLimit(2)

                // Overview
                if let overview = item.overview {
                    Text(overview)
                        .font(.system(size: heroOverviewFontSize))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(3)
                        .frame(maxWidth: heroOverviewMaxWidth, alignment: .leading)
                }

                // Action buttons
                HStack(spacing: 12) {
                    if let id = item.id {
                        PlayLink(itemId: id, title: item.name ?? "") {
                            HStack(spacing: CinemaSpacing.spacing2) {
                                Text(loc.localized("action.play"))
                                    .font(.system(size: heroButtonFontSize, weight: .bold))
                                Image(systemName: "play.fill")
                                    .font(.system(size: heroButtonFontSize - 2, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, heroPadding > 60 ? CinemaSpacing.spacing4 : CinemaSpacing.spacing2)
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
                            MediaDetailScreen(itemId: id, itemType: .series)
                        } label: {
                            HStack(spacing: CinemaSpacing.spacing2) {
                                Text(loc.localized("tvShows.myList"))
                                    .font(.system(size: heroButtonFontSize, weight: .bold))
                                Image(systemName: "plus")
                                    .font(.system(size: heroButtonFontSize - 2, weight: .bold))
                            }
                            .foregroundStyle(CinemaColor.onSurface)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, heroPadding > 60 ? CinemaSpacing.spacing4 : CinemaSpacing.spacing2)
                            .padding(.horizontal, CinemaSpacing.spacing4)
                            #if os(iOS)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                            #endif
                        }
                        #if os(tvOS)
                        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .frame(width: heroButtonWidth)
                    }
                }
            }
            .padding(heroPadding)
            .padding(.bottom, CinemaSpacing.spacing6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
    }

    private func heroMetadata(for item: BaseItemDto) -> some View {
        let parts: [String] = [
            item.productionYear.map(String.init),
            item.childCount.map { loc.localized($0 == 1 ? "tvShows.season" : "tvShows.seasonsPlural", $0) },
            item.genres?.first
        ].compactMap { $0 }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: heroMetadataFontSize, weight: .medium))
    }

    // MARK: - Genre Rows

    private var genreRows: some View {
        ForEach(viewModel.genres, id: \.self) { genre in
            if let items = viewModel.itemsByGenre[genre], !items.isEmpty {
                ContentRow(
                    title: genre,
                    showViewAll: true,
                    onViewAll: { Task { await viewModel.applyGenreFilter(genre, using: appState) } }
                ) {
                    ForEach(items, id: \.id) { item in
                        seriesCard(item)
                            .frame(width: posterCardWidth)
                    }
                }
            }
        }
    }

    private var genreRowsPlaceholder: some View {
        VStack(spacing: CinemaSpacing.spacing6) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .fill(CinemaColor.surfaceContainerHigh)
                        .frame(width: 140, height: 24)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: CinemaSpacing.spacing3) {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: CinemaRadius.large)
                                    .fill(CinemaColor.surfaceContainerHigh)
                                    .frame(width: posterCardWidth)
                                    .aspectRatio(2/3, contentMode: .fit)
                            }
                        }
                        .padding(.horizontal, CinemaSpacing.spacing6)
                    }
                }
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
            Task { await viewModel.applyGenreFilter(genre, using: appState) }
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

    // MARK: - Filtered Grid

    private var filteredGridView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                // Active filter header
                HStack {
                    if let genre = viewModel.selectedGenre {
                        HStack(spacing: CinemaSpacing.spacing2) {
                            Text(genre)
                                .font(CinemaFont.label(.large))
                                .foregroundStyle(themeManager.accent)
                            Button {
                                Task { await viewModel.applyGenreFilter(nil, using: appState) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, CinemaSpacing.spacing3)
                        .padding(.vertical, CinemaSpacing.spacing1)
                        .background(CinemaColor.surfaceContainerHigh)
                        .clipShape(Capsule())
                    }

                    Spacer()

                    Text(loc.localized("tvShows.count", viewModel.filteredTotalCount))
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                .padding(.horizontal, gridPadding)

                // Grid
                LazyVGrid(columns: filteredColumns, spacing: gridSpacing) {
                    ForEach(viewModel.filteredItems, id: \.id) { item in
                        seriesCard(item)
                            .onAppear {
                                if item.id == viewModel.filteredItems.last?.id {
                                    Task { await viewModel.loadMoreFiltered(using: appState) }
                                }
                            }
                    }
                }
                .padding(.horizontal, gridPadding)

                Spacer(minLength: 80)
            }
            .padding(.top, CinemaSpacing.spacing3)
        }
    }

    // MARK: - Series Card

    @ViewBuilder
    private func seriesCard(_ item: BaseItemDto) -> some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if let count = item.childCount { parts.append(loc.localized(count == 1 ? "tvShows.season" : "tvShows.seasonsPlural", count)) }
            return parts.joined(separator: " · ")
        }()

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: .series)
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { builder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300) },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(CinemaColor.error)
            Text(message)
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
            CinemaButton(title: "Retry", style: .ghost) {
                Task { await viewModel.loadInitial(using: appState) }
            }
            .frame(width: 160)
        }
    }

    // MARK: - Adaptive Sizing

    private var heroHeight: CGFloat {
        #if os(tvOS)
        820
        #else
        500
        #endif
    }

    private var heroTitleSize: CGFloat {
        #if os(tvOS)
        72
        #else
        40
        #endif
    }

    private var heroOverviewFontSize: CGFloat {
        #if os(tvOS)
        18
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

    private var heroOverviewMaxWidth: CGFloat {
        #if os(tvOS)
        600
        #else
        300
        #endif
    }

    private var heroButtonWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        160
        #endif
    }

    private var heroButtonFontSize: CGFloat {
        #if os(tvOS)
        28
        #else
        18
        #endif
    }

    private var heroBadgeFontSize: CGFloat {
        #if os(tvOS)
        12
        #else
        10
        #endif
    }

    private var heroMetadataFontSize: CGFloat {
        #if os(tvOS)
        16
        #else
        13
        #endif
    }

    private var posterCardWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        140
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

    private var filteredColumns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
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
}

// MARK: - Sort & Filter Sheet

struct TVSeriesFilterSheet: View {
    @Bindable var viewModel: TVSeriesViewModel
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    // Local draft state — committed only on Apply
    @State private var draftSort: TVSeriesSortOption
    @State private var draftAscending: Bool
    @State private var draftGenre: String?

    init(viewModel: TVSeriesViewModel, onApply: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onApply = onApply
        _draftSort = State(initialValue: viewModel.selectedSortOption)
        _draftAscending = State(initialValue: viewModel.sortAscending)
        _draftGenre = State(initialValue: viewModel.selectedGenre)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CinemaColor.surface.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                        sortSection
                        genreSection
                        Spacer(minLength: CinemaSpacing.spacing8)
                    }
                    .padding(.top, CinemaSpacing.spacing4)
                }
            }
            .navigationTitle(loc.localized("movies.sortFilter"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(loc.localized("action.reset")) {
                        draftSort = .name
                        draftAscending = true
                        draftGenre = nil
                    }
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(loc.localized("action.apply")) {
                        viewModel.selectedSortOption = draftSort
                        viewModel.sortAscending = draftAscending
                        viewModel.selectedGenre = draftGenre
                        onApply()
                        dismiss()
                    }
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(themeManager.accent)
                }
            }
            #endif
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(CinemaColor.surfaceContainerLow)
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: Sort Section

    private var sortSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("sort.by"))

            VStack(spacing: 0) {
                ForEach(TVSeriesSortOption.allCases) { option in
                    sortRow(option)
                    if option != TVSeriesSortOption.allCases.last {
                        Divider()
                            .background(CinemaColor.outlineVariant)
                            .padding(.leading, CinemaSpacing.spacing4)
                    }
                }
            }
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            .padding(.horizontal, CinemaSpacing.spacing4)

            // Sort direction toggle (hidden for Random)
            if draftSort != .random {
                HStack(spacing: 0) {
                    sortDirectionButton(label: loc.localized("sort.ascending"), icon: "arrow.up", isSelected: draftAscending) {
                        draftAscending = true
                    }
                    sortDirectionButton(label: loc.localized("sort.descending"), icon: "arrow.down", isSelected: !draftAscending) {
                        draftAscending = false
                    }
                }
                .background(CinemaColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                .padding(.horizontal, CinemaSpacing.spacing4)
            }
        }
    }

    @ViewBuilder
    private func sortRow(_ option: TVSeriesSortOption) -> some View {
        let isSelected = draftSort == option

        Button {
            draftSort = option
        } label: {
            HStack {
                Text(localizedSortOption(option))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(isSelected ? themeManager.accent : CinemaColor.onSurface)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(themeManager.accent)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
        }
        .buttonStyle(.plain)
    }

    private func sortDirectionButton(label: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: CinemaSpacing.spacing2) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(CinemaFont.label(.large))
            }
            .foregroundStyle(isSelected ? themeManager.accent : CinemaColor.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, CinemaSpacing.spacing3)
        }
        .buttonStyle(.plain)
    }

    // MARK: Genre Section

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("tvShows.genre"))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: CinemaSpacing.spacing2) {
                    // "All" chip
                    genreChip(title: loc.localized("tvShows.all"), isSelected: draftGenre == nil) {
                        draftGenre = nil
                    }

                    ForEach(viewModel.genres, id: \.self) { genre in
                        genreChip(title: genre, isSelected: draftGenre == genre) {
                            draftGenre = draftGenre == genre ? nil : genre
                        }
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing4)
            }
        }
    }

    private func genreChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CinemaFont.label(.large))
                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurface)
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.vertical, CinemaSpacing.spacing2)
                .background(
                    isSelected
                        ? themeManager.accentContainer
                        : CinemaColor.surfaceContainerHighest
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func localizedSortOption(_ option: TVSeriesSortOption) -> String {
        switch option {
        case .name: loc.localized("sort.name")
        case .dateAdded: loc.localized("sort.dateAdded")
        case .year: loc.localized("sort.releaseYear")
        case .rating: loc.localized("sort.rating")
        case .random: loc.localized("sort.random")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(CinemaFont.label(.small))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.5)
            .padding(.horizontal, CinemaSpacing.spacing4)
    }
}
