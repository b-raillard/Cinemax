import SwiftUI
import CinemaxKit
import JellyfinAPI

/// Browses a folder-of-folders library — Jellyfin **Collections** (BoxSets) or
/// **Playlists**. Each card is itself a folder; tapping one drills into its
/// contents via a scoped `MediaLibraryScreen`, whose own cards then open item
/// detail. Reached as a library tab from the custom-menu (library mode); see
/// `MenuConfigStore.libraryTab` → `.libraryFolders`.
struct LibraryFolderBrowseScreen: View {
    /// Where the folders come from.
    ///
    /// `.playlists` exists so the "all playlists" screen does NOT depend on the
    /// server exposing a Playlists *view*: `getPlaylists` answers for the user
    /// directly. That was the second of the two conditions that made a created
    /// playlist unfindable — the first being that only a `.custom + .library`
    /// menu could reach this screen at all.
    enum Source: Hashable {
        case parent(String)
        case playlists
    }

    let source: Source
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
                // A playlist is ORDERED, and only `getPlaylistItems` returns it
                // in order — a `parentId` query cannot.
                if isPlaylist {
                    PlaylistDetailScreen(playlistId: sel.id, title: sel.name)
                } else {
                    // A collection gets its own fiche — backdrop, overview,
                    // "Play all", and its members — not a bare scoped grid.
                    // The fiche existed but nothing reached it: this browser
                    // predates it and drilled straight into `parentId`
                    // contents, so "Play all" was unreachable by any route.
                    MediaDetailScreen(itemId: sel.id, itemType: .boxSet)
                }
            }
            .task(id: source) {
                await viewModel.load(source: source, using: appState)
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
                Task { await viewModel.load(source: source, using: appState) }
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
            #if os(tvOS)
            // tvOS renders no navigation bar, so `.navigationTitle` above draws
            // nothing at all — the page arrived untitled. Same in-scroll title
            // `FavoritesScreen` carries.
            Text(title)
                .font(CinemaFont.display(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, gridPadding)
                .padding(.top, CinemaSpacing.spacing5)
            #endif

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
                            subtitle: folder.childCount.map { loc.itemCount($0) }
                        )
                    }
                    #if os(tvOS)
                    // Every other card grid in the app carries the focus card
                    // style; this one was the sole `.plain` holdout, so its
                    // cards neither grew nor brightened under focus.
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
        #else
        // Pull-to-refresh has no gesture on a remote — the modifier is inert
        // on tvOS and only reads as if a refresh were available.
        .refreshable {
            await viewModel.load(source: source, using: appState)
        }
        #endif
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

    func load(source: LibraryFolderBrowseScreen.Source, using appState: AppState) async {
        guard let userId = appState.currentUserId else {
            state = .failed
            return
        }
        if case .loaded = state {} else { state = .loading }
        do {
            let folders: [BaseItemDto]
            switch source {
            case .parent(let parentId):
                folders = try await appState.apiClient.getItems(
                    userId: userId,
                    parentId: parentId,
                    sortBy: [.sortName],
                    sortOrder: [.ascending]
                ).items
            case .playlists:
                folders = try await appState.apiClient.getPlaylists(userId: userId)
            }
            state = folders.isEmpty ? .empty : .loaded(folders)
        } catch {
            state = .failed
        }
    }
}
