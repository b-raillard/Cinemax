import SwiftUI
import NukeUI
import CinemaxKit
import JellyfinAPI

@MainActor @Observable
final class TVSeriesViewModel {
    var series: [BaseItemDto] = []
    var totalCount = 0
    var isLoading = true
    var errorMessage: String?
    private var hasLoadedAll = false
    private let pageSize = 40

    func loadInitial(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        isLoading = true

        do {
            let result = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.series],
                sortBy: [.sortName],
                limit: pageSize
            )
            series = result.items
            totalCount = result.totalCount
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadMore(using appState: AppState) async {
        guard !hasLoadedAll, !isLoading,
              let userId = appState.currentUserId else { return }

        do {
            let result = try await appState.apiClient.getItems(
                userId: userId,
                includeItemTypes: [.series],
                sortBy: [.sortName],
                limit: pageSize,
                startIndex: series.count
            )
            series.append(contentsOf: result.items)
            hasLoadedAll = series.count >= result.totalCount
        } catch {
            // Silently fail on pagination
        }
    }
}

struct TVSeriesScreen: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = TVSeriesViewModel()

    private let columns: [GridItem] = {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
        #endif
    }()

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(CinemaColor.onSurfaceVariant)
                    .scaleEffect(1.5)
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else {
                libraryGrid
            }
        }
        .navigationTitle("TV Shows")
        .task {
            await viewModel.loadInitial(using: appState)
        }
    }

    private var libraryGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                HStack {
                    Text("\(viewModel.totalCount) Series")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    Spacer()
                }
                .padding(.horizontal, gridPadding)

                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(viewModel.series, id: \.id) { item in
                        seriesCard(item)
                            .onAppear {
                                if item.id == viewModel.series.last?.id {
                                    Task { await viewModel.loadMore(using: appState) }
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

    @ViewBuilder
    private func seriesCard(_ item: BaseItemDto) -> some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if let count = item.childCount { parts.append("\(count) Seasons") }
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
