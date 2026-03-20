import SwiftUI
import NukeUI
import CinemaxKit
import JellyfinAPI

@MainActor @Observable
final class MovieLibraryViewModel {
    var movies: [BaseItemDto] = []
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
                includeItemTypes: [.movie],
                sortBy: [.sortName],
                limit: pageSize
            )
            movies = result.items
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
                includeItemTypes: [.movie],
                sortBy: [.sortName],
                limit: pageSize,
                startIndex: movies.count
            )
            movies.append(contentsOf: result.items)
            hasLoadedAll = movies.count >= result.totalCount
        } catch {
            // Silently fail on pagination
        }
    }
}

struct MovieLibraryScreen: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = MovieLibraryViewModel()

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
        .navigationTitle("Movies")
        .task {
            await viewModel.loadInitial(using: appState)
        }
    }

    private var libraryGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                // Header
                HStack {
                    Text("\(viewModel.totalCount) Movies")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    Spacer()
                }
                .padding(.horizontal, gridPadding)

                // Grid
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(viewModel.movies, id: \.id) { item in
                        movieCard(item)
                            .onAppear {
                                if item.id == viewModel.movies.last?.id {
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
    private func movieCard(_ item: BaseItemDto) -> some View {
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

// MARK: - tvOS Card Button Style

#if os(tvOS)
struct CinemaTVCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.95 : 1.0))
            .shadow(
                color: CinemaColor.surfaceTint.opacity(isFocused ? 0.08 : 0),
                radius: 30, y: 15
            )
            .animation(.easeInOut(duration: 0.2), value: isFocused)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
#endif
