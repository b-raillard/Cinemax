import SwiftUI
import CinemaxKit
import JellyfinAPI

/// Browses a folder-of-folders library — Jellyfin **Collections** (BoxSets) or
/// **Playlists**. Each card is itself a folder; tapping one drills into its
/// contents via a scoped `MediaLibraryScreen`, whose own cards then open item
/// detail. Reached as a library tab from the custom-menu (library mode); see
/// `MenuConfigStore.libraryTab` → `.libraryFolders`.
struct LibraryFolderBrowseScreen: View {
    let parentId: String
    let title: String
    /// Drives the empty-state copy + icon (Playlists vs Collections).
    let isPlaylist: Bool

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var viewModel = FolderBrowseViewModel()
    /// Hoisted out of the `LazyVGrid` so `navigationDestination(item:)` is honored
    /// — SwiftUI silently ignores it inside lazy containers (see CLAUDE.md).
    @State private var selection: FolderSelection?

    var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .navigationDestination(item: $selection) { sel in
                MediaLibraryScreen(itemType: nil, parentId: sel.id, overrideTitle: sel.name)
            }
            .task(id: parentId) {
                await viewModel.load(parentId: parentId, using: appState)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView()
        case .failed:
            ErrorStateView(
                message: loc.localized("error.generic"),
                retryTitle: loc.localized("action.retry")
            ) {
                Task { await viewModel.load(parentId: parentId, using: appState) }
            }
        case .empty:
            EmptyStateView(
                systemImage: isPlaylist ? "music.note.list" : "rectangle.stack",
                title: loc.localized(isPlaylist ? "library.playlists.empty" : "library.collections.empty")
            )
        case .loaded(let folders):
            grid(folders)
        }
    }

    private func grid(_ folders: [BaseItemDto]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(folders, id: \.id) { folder in
                    Button {
                        if let id = folder.id {
                            selection = FolderSelection(id: id, name: folder.name ?? title)
                        }
                    } label: {
                        PosterCard(
                            title: folder.name ?? "",
                            imageURL: folder.id.map {
                                appState.imageBuilder.imageURL(
                                    itemId: $0, imageType: .primary,
                                    maxWidth: 300, tag: folder.primaryImageTagValue
                                )
                            },
                            subtitle: folder.childCount.map { loc.localized("library.itemCount", $0) }
                        )
                    }
                    // tvOS card focus lift, matching every other poster grid
                    // (Home/Favorites/filmography); .plain would drop the brighten.
                    #if os(tvOS)
                    .buttonStyle(CinemaTVCardButtonStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal, gridPadding)
            .padding(.top, CinemaSpacing.spacing3)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .refreshable {
            await viewModel.load(parentId: parentId, using: appState)
        }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        32
        #else
        16
        #endif
    }

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }
}

/// `navigationDestination(item:)` payload — the tapped folder's id + display name.
private struct FolderSelection: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
@Observable
final class FolderBrowseViewModel {
    enum State {
        case loading
        case loaded([BaseItemDto])
        case empty
        case failed
    }

    private(set) var state: State = .loading

    func load(parentId: String, using appState: AppState) async {
        guard let userId = appState.currentUserId else {
            state = .failed
            return
        }
        if case .loaded = state {} else { state = .loading }
        do {
            let result = try await appState.apiClient.getItems(
                userId: userId,
                parentId: parentId,
                sortBy: [.sortName],
                sortOrder: [.ascending]
            )
            state = result.items.isEmpty ? .empty : .loaded(result.items)
        } catch {
            state = .failed
        }
    }
}
