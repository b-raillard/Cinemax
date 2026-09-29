import SwiftUI
import CinemaxKit
import JellyfinAPI

/// Every title of the season's Home row (« Tout voir »), films and series
/// together, in the row's order. Pushed onto Home's stack; the list is small
/// enough to load in one go (`SeasonRowLoader.fullLimit`).
struct SeasonCollectionScreen: View {
    let row: SeasonRow
    let title: String

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.seasonID) private var seasonID
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            SeasonalBackdrop().ignoresSafeArea()
            content
        }
        #if os(iOS)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // The title is drawn in the season's face just below; the bar keeps
        // the name (back-button menu, VoiceOver) without printing it twice.
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
        }
        #endif
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            Task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            LoadingStateView()
        } else if items.isEmpty {
            ErrorStateView(message: loc.localized("error.generic"), retryTitle: loc.localized("action.retry")) {
                Task { await load() }
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            Text(title)
                .accessibilityAddTraits(.isHeader)
                .font(SeasonalTypography.titleFont(for: SeasonalThemeCatalogue.theme(id: seasonID), size: CinemaScale.pt(40))
                      ?? CinemaFont.display(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, gridPadding)
                .padding(.top, CinemaSpacing.spacing5)

            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(items, id: \.id) { item in
                    LibraryPosterCard(item: item, itemType: item.type ?? .movie)
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
        .refreshable { await load() }
        #endif
    }

    private func load() async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true
        items = await SeasonRowLoader.items(for: row, limit: SeasonRowLoader.fullLimit, userId: userId, appState: appState)
        isLoading = false
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
