import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "WatchedHistory")

/// Most-recently-watched movies and episodes, newest first. Mirrors the
/// `FavoritesViewModel` load pattern (grid, limit 200) but filters on
/// `.isPlayed` and sorts by `.datePlayed` descending. Only leaf items carry a
/// real play timestamp, so the query includes movies + episodes (a series is
/// "played" only once fully watched, which would surface it out of order).
@MainActor @Observable
final class WatchedHistoryViewModel {
    var items: [BaseItemDto] = []
    var isLoading = true
    /// True when the last fetch threw — drives the error state instead of the
    /// (misleading) empty state.
    var loadFailed = false

    private var hasLoaded = false

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
                includeItemTypes: [.movie, .episode],
                sortBy: [.datePlayed],
                sortOrder: [.descending],
                filters: [.isPlayed],
                limit: 200
            ).items
        } catch {
            logger.warning("Watched history load failed: \(error.localizedDescription, privacy: .public)")
            loadFailed = true
        }
        isLoading = false
    }
}

/// Watched-history grid. Presented as a `.sheet` on iOS and a `.fullScreenCover`
/// on tvOS (tvOS `.sheet` renders a cramped modal) — the same platform-branched
/// chrome as `PrivacySecurityScreen`: iOS `NavigationStack` + toolbar Done,
/// tvOS custom header with an accent Done button and `.focusSection()` so
/// up-presses from the grid reach it. The header's Done button guarantees a
/// focusable in the loading / empty / error states too.
struct WatchedHistoryScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var viewModel = WatchedHistoryViewModel()
    @State private var prefetcher = PosterPrefetcher()

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSChrome
            #else
            iOSChrome
            #endif
        }
        .task {
            await viewModel.loadInitial(using: appState)
            prefetchPosters()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            Task { await viewModel.load(using: appState); prefetchPosters() }
        }
    }

    // MARK: - Chrome

    #if !os(tvOS)
    private var iOSChrome: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            content
        }
        .navigationTitle(loc.localized("settings.watchedHistory"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(loc.localized("action.done")) { dismiss() }
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
        }
    }
    #endif

    #if os(tvOS)
    private var tvOSChrome: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                tvHeader
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand { dismiss() }
    }

    private var tvHeader: some View {
        HStack(alignment: .center) {
            Text(loc.localized("settings.watchedHistory"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)

            Spacer(minLength: CinemaSpacing.spacing6)

            CinemaButton(
                title: loc.localized("action.done"),
                style: .accent
            ) {
                dismiss()
            }
            .frame(width: 240)
        }
        .padding(.horizontal, CinemaSpacing.spacing10)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
        // Without this, up-presses from the first grid row never reach the Done
        // button (separate container — same rule as the Home/Library hero).
        .focusSection()
    }
    #endif

    // MARK: - Content

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
                systemImage: "clock.arrow.circlepath",
                title: loc.localized("watchedHistory.empty.title"),
                subtitle: loc.localized("watchedHistory.empty.subtitle")
            )
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(viewModel.items, id: \.id) { item in
                    historyCard(item)
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
    private func historyCard(_ item: BaseItemDto) -> some View {
        let subtitle: String = {
            var parts: [String] = []
            if item.type == .episode {
                if let series = item.seriesName { parts.append(series) }
                if let season = item.parentIndexNumber, let ep = item.indexNumber {
                    parts.append(String(format: "S%02d:E%02d", season, ep))
                }
            } else if let year = item.productionYear {
                parts.append(String(year))
            }
            return parts.joined(separator: " · ")
        }()

        // Episodes carry a series-name; use their own title. Movies show name.
        let cardTitle = item.type == .episode
            ? (item.seriesName ?? item.name ?? "")
            : (item.name ?? "")

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
            }
        } label: {
            PosterCard(
                title: cardTitle,
                imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel([cardTitle, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))
        // Long-press / long-press-select: un-watch removes the item here (the
        // screen reloads off `.cinemaxShouldRefreshCatalogue`), favorite too.
        .mediaCardContextMenu(item: item)
    }

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
