import SwiftUI
import NukeUI
import CinemaxKit
import JellyfinAPI

@MainActor @Observable
final class SearchViewModel {
    var searchText = ""
    var results: [BaseItemDto] = []
    var isSearching = false
    var hasSearched = false

    private var searchTask: Task<Void, Never>?

    func search(using appState: AppState) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            results = []
            hasSearched = false
            return
        }

        searchTask = Task {
            // Debounce
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            guard let userId = appState.currentUserId else { return }
            isSearching = true

            do {
                let items = try await appState.apiClient.searchItems(userId: userId, searchTerm: query, limit: 30)
                guard !Task.isCancelled else { return }
                results = items
            } catch {
                guard !Task.isCancelled else { return }
                results = []
            }

            isSearching = false
            hasSearched = true
        }
    }
}

struct SearchScreen: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = SearchViewModel()

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

            VStack(spacing: 0) {
                searchField
                resultContent
            }
        }
        .navigationTitle("Search")
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .font(.system(size: searchIconSize))

            TextField("Search movies, shows...", text: Bindable(viewModel).searchText)
                #if os(iOS)
                .textFieldStyle(.plain)
                #endif
                .font(.system(size: searchFontSize))
                .foregroundStyle(CinemaColor.onSurface)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: viewModel.searchText) {
                    viewModel.search(using: appState)
                }

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    viewModel.results = []
                    viewModel.hasSearched = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CinemaColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        .padding(.horizontal, gridPadding)
        .padding(.vertical, CinemaSpacing.spacing3)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultContent: some View {
        if viewModel.isSearching {
            Spacer()
            ProgressView()
                .tint(CinemaColor.onSurfaceVariant)
                .scaleEffect(1.5)
            Spacer()
        } else if viewModel.results.isEmpty && viewModel.hasSearched {
            Spacer()
            VStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaColor.outlineVariant)
                Text("No results found")
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            Spacer()
        } else if viewModel.results.isEmpty {
            Spacer()
            VStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaColor.outlineVariant)
                Text("Search your library")
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            Spacer()
        } else {
            resultsGrid
        }
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                Text("\(viewModel.results.count) Results")
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.horizontal, gridPadding)

                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(viewModel.results, id: \.id) { item in
                        resultCard(item)
                    }
                }
                .padding(.horizontal, gridPadding)

                Spacer(minLength: 80)
            }
        }
    }

    @ViewBuilder
    private func resultCard(_ item: BaseItemDto) -> some View {
        let serverURL = appState.serverURL ?? URL(string: "http://localhost")!
        let builder = ImageURLBuilder(serverURL: serverURL)

        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if let type = item.type { parts.append(type.rawValue) }
            return parts.joined(separator: " · ")
        }()

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(
                    itemId: id,
                    itemType: item.type ?? .movie
                )
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

    // MARK: - Sizing

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

    private var searchFontSize: CGFloat {
        #if os(tvOS)
        24
        #else
        17
        #endif
    }

    private var searchIconSize: CGFloat {
        #if os(tvOS)
        22
        #else
        17
        #endif
    }
}
