import SwiftUI
import NukeUI
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - Sort & Filter State

struct MovieSortFilterState: Equatable {
    var sortBy: ItemSortBy = .sortName
    var sortAscending: Bool = true
    var selectedGenres: Set<String> = []

    var isFiltered: Bool { !selectedGenres.isEmpty }
    var isNonDefault: Bool { sortBy != .sortName || !sortAscending || isFiltered }
}

// MARK: - View Model

@MainActor @Observable
final class MovieLibraryViewModel {
    // Hero
    var heroItem: BaseItemDto?

    // Genre rows  (ordered genre names + items per genre)
    var genres: [String] = []
    var itemsByGenre: [String: [BaseItemDto]] = [:]

    // Filtered flat list (used when a filter/sort is active)
    var filteredMovies: [BaseItemDto] = []
    var filteredTotalCount = 0
    var filteredIsLoadingMore = false
    private var filteredHasLoadedAll = false

    // Shared state
    var totalCount = 0
    var isLoading = true
    var errorMessage: String?

    // Sort & filter
    var sortFilter = MovieSortFilterState()

    // Internal
    private let pageSize = 40
    private let genreItemLimit = 12
    let genreLoadLimit = 8  // how many genres to hydrate with items

    func loadInitial(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true
        errorMessage = nil

        do {
            // Parallel: genre list + total count + hero
            async let genresResult = appState.apiClient.getGenres(
                userId: userId,
                includeItemTypes: [.movie]
            )
            async let countResult = appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.movie],
                sortBy: [.random],
                sortOrder: [.ascending],
                limit: 1
            )

            let fetchedGenres = try await genresResult
            let countData = try await countResult

            genres = fetchedGenres
            totalCount = countData.totalCount

            // Pick a random hero from the first page of movies
            let heroResult = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.movie],
                sortBy: [.random],
                sortOrder: [.ascending],
                limit: 20
            )
            heroItem = heroResult.items.randomElement()

            // Load items for the first N genres concurrently.
            // BaseItemDto is not Sendable in the Jellyfin SDK; we box results to cross
            // the task boundary safely (the type is a value-typed Codable struct).
            struct GenreResult: @unchecked Sendable {
                let genre: String
                let items: [BaseItemDto]
            }
            let genresToLoad = Array(fetchedGenres.prefix(genreLoadLimit))
            try await withThrowingTaskGroup(of: GenreResult.self) { group in
                for genre in genresToLoad {
                    group.addTask {
                        let result = try await appState.apiClient.getItems(
                            userId: userId,
                            includeItemTypes: [.movie],
                            sortBy: [.random],
                            sortOrder: [.ascending],
                            genres: [genre],
                            limit: self.genreItemLimit
                        )
                        return GenreResult(genre: genre, items: result.items)
                    }
                }
                for try await entry in group {
                    itemsByGenre[entry.genre] = entry.items
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func applyFilter(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        filteredMovies = []
        filteredHasLoadedAll = false
        filteredIsLoadingMore = false
        await loadFilteredPage(using: appState, userId: userId, startIndex: 0)
    }

    func loadMoreFiltered(using appState: AppState) async {
        guard !filteredHasLoadedAll, !filteredIsLoadingMore,
              let userId = appState.currentUserId else { return }
        await loadFilteredPage(using: appState, userId: userId, startIndex: filteredMovies.count)
    }

    private func loadFilteredPage(using appState: AppState, userId: String, startIndex: Int) async {
        filteredIsLoadingMore = true
        do {
            let genres = sortFilter.selectedGenres.isEmpty ? nil : Array(sortFilter.selectedGenres)
            let result = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.movie],
                sortBy: [sortFilter.sortBy],
                sortOrder: sortFilter.sortAscending ? [.ascending] : [.descending],
                genres: genres,
                limit: pageSize,
                startIndex: startIndex
            )
            if startIndex == 0 {
                filteredMovies = result.items
            } else {
                filteredMovies.append(contentsOf: result.items)
            }
            filteredTotalCount = result.totalCount
            filteredHasLoadedAll = filteredMovies.count >= result.totalCount
        } catch {
            // Silently fail on pagination
        }
        filteredIsLoadingMore = false
    }
}

// MARK: - Main Screen

struct MovieLibraryScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel = MovieLibraryViewModel()
    @State private var showSortFilter = false

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
        .navigationTitle(loc.localized("movies.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                filterButton
            }
        }
        #endif
        .task {
            await viewModel.loadInitial(using: appState)
        }
        .sheet(isPresented: $showSortFilter) {
            makeSortFilterSheet()
        }
    }

    // MARK: Main Content Switch

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.sortFilter.isNonDefault {
            filteredView
        } else {
            browseView
        }
    }

    // MARK: Browse View (genre rows + hero)

    private var browseView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Hero section (mobile only at top; desktop gets a header bar instead)
                #if os(iOS)
                if let hero = viewModel.heroItem {
                    heroSection(hero)
                        .padding(.bottom, CinemaSpacing.spacing6)
                }
                #endif

                // Desktop/tvOS header bar with count + filter button
                #if os(tvOS)
                tvHeaderBar
                    .padding(.bottom, CinemaSpacing.spacing6)
                #endif

                // Genre rows
                ForEach(viewModel.genres.prefix(viewModel.genreLoadLimit), id: \.self) { genre in
                    if let items = viewModel.itemsByGenre[genre], !items.isEmpty {
                        genreRow(genre: genre, items: items)
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }
                }

                Spacer(minLength: 80)
            }
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    // MARK: Filtered / Flat Grid View

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
                // Header
                HStack {
                    Text(loc.localized("movies.count", viewModel.filteredTotalCount))
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)

                    Spacer()

                    filterButton
                }
                .padding(.horizontal, gridPadding)

                if viewModel.filteredMovies.isEmpty && viewModel.filteredIsLoadingMore {
                    ProgressView()
                        .tint(CinemaColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CinemaSpacing.spacing10)
                } else {
                    LazyVGrid(columns: filteredColumns, spacing: gridSpacing) {
                        ForEach(viewModel.filteredMovies, id: \.id) { item in
                            moviePosterCard(item)
                                .onAppear {
                                    if item.id == viewModel.filteredMovies.last?.id {
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

            // Content overlay
            VStack(alignment: .leading, spacing: heroPadding > 60 ? 16 : 10) {
                // Metadata badges
                HStack(spacing: 8) {
                    if let rating = item.officialRating {
                        Text(rating)
                            .font(.system(size: badgeFontSize, weight: .bold))
                            .tracking(1)
                            .textCase(.uppercase)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))
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

                // Overview
                if let overview = item.overview {
                    Text(overview)
                        .font(.system(size: overviewFontSize))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(3)
                        .frame(maxWidth: maxOverviewWidth, alignment: .leading)
                }

                // Action buttons
                if let id = item.id {
                    HStack(spacing: 12) {
                        PlayLink(itemId: id, title: item.name ?? "") {
                            HStack(spacing: CinemaSpacing.spacing2) {
                                Text(loc.localized("movies.playNow"))
                                    .font(.system(size: heroPadding > 60 ? 28 : 18, weight: .bold))
                                Image(systemName: "play.fill")
                                    .font(.system(size: heroPadding > 60 ? 26 : 16, weight: .bold))
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
                        .frame(width: playButtonWidth)

                        NavigationLink {
                            MediaDetailScreen(itemId: id, itemType: .movie)
                        } label: {
                            HStack(spacing: CinemaSpacing.spacing2) {
                                Text(loc.localized("action.moreInfo"))
                                    .font(.system(size: heroPadding > 60 ? 28 : 18, weight: .bold))
                                Image(systemName: "info.circle")
                                    .font(.system(size: heroPadding > 60 ? 26 : 16, weight: .bold))
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
                        .frame(width: playButtonWidth)
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

    // MARK: - tvOS Header Bar

    #if os(tvOS)
    private var tvHeaderBar: some View {
        HStack(alignment: .center, spacing: CinemaSpacing.spacing4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.localized("movies.title"))
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Text(loc.localized("movies.titles", viewModel.totalCount))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }

            Spacer()

            filterButton
        }
        .padding(.horizontal, CinemaSpacing.spacing20)
    }
    #endif

    // MARK: - Genre Row

    @ViewBuilder
    private func genreRow(genre: String, items: [BaseItemDto]) -> some View {
        ContentRow(title: genre, showViewAll: true) {
            ForEach(items, id: \.id) { item in
                moviePosterCard(item)
                    .frame(width: posterCardWidth)
            }
        }
    }

    // MARK: - Poster Card

    @ViewBuilder
    private func moviePosterCard(_ item: BaseItemDto) -> some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if let rating = item.communityRating {
                parts.append(String(format: "%.1f", rating))
            }
            return parts.joined(separator: " · ")
        }()

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: .movie)
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

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            ProgressView()
                .tint(CinemaColor.onSurfaceVariant)
                .scaleEffect(1.5)
        }
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

    // MARK: - Hero Helpers

    private func heroMetadataText(for item: BaseItemDto) -> some View {
        let parts: [String] = [
            item.productionYear.map(String.init),
            item.runTimeTicks.map { ticks in
                let minutes = ticks / 600_000_000
                return minutes > 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
            },
            item.genres?.first
        ].compactMap { $0 }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: metadataFontSize, weight: .medium))
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

    private var overviewFontSize: CGFloat {
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

    private var maxOverviewWidth: CGFloat {
        #if os(tvOS)
        600
        #else
        300
        #endif
    }

    private var playButtonWidth: CGFloat {
        #if os(tvOS)
        240
        #else
        160
        #endif
    }

    private var posterCardWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        140
        #endif
    }

    private var badgeFontSize: CGFloat {
        #if os(tvOS)
        12
        #else
        10
        #endif
    }

    private var metadataFontSize: CGFloat {
        #if os(tvOS)
        16
        #else
        13
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
        24
        #else
        16
        #endif
    }

    private var filterLabelSize: CGFloat {
        #if os(tvOS)
        22
        #else
        14
        #endif
    }
}

// MARK: - Sort & Filter Sheet

private struct SortFilterSheet: View {
    @Binding var sortFilter: MovieSortFilterState
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    let onApply: () -> Void

    // All available genres come from the parent, but we read them from AppState via the VM.
    // For simplicity the sheet derives available genres from sortFilter context.
    // The full genre list is injected via the parent.
    var availableGenres: [String] = []

    private var sortOptions: [(label: String, value: ItemSortBy)] {
        [
            (loc.localized("sort.name"), .sortName),
            (loc.localized("sort.dateAdded"), .dateCreated),
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.reset")) {
                        sortFilter = MovieSortFilterState()
                        onApply()
                        dismiss()
                    }
                    .font(.system(size: 17, weight: .regular))
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

// MARK: - SortFilterSheet + Genre Injection

extension MovieLibraryScreen {
    // Bridges the genre list from the ViewModel into the sheet
    private func makeSortFilterSheet() -> SortFilterSheet {
        SortFilterSheet(
            sortFilter: Binding(
                get: { viewModel.sortFilter },
                set: { viewModel.sortFilter = $0 }
            ),
            onApply: { Task { await viewModel.applyFilter(using: appState) } },
            availableGenres: viewModel.genres
        )
    }
}

// MARK: - Flow Layout (wrapping chips)

private struct FlowLayout: Layout {
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .brightness(isFocused ? 0.05 : 0)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
#endif
