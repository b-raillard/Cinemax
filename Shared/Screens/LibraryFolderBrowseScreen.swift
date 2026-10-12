import SwiftUI
import CinemaxKit
import JellyfinAPI

/// Browses a folder-of-folders library — Jellyfin **Collections** (BoxSets) or
/// **Playlists**. Each card is itself a folder: a collection opens its fiche,
/// a playlist its own page (`PlaylistDetailScreen`). Reached as a library tab
/// from the custom-menu (library mode; see `MenuConfigStore.libraryTab` →
/// `.libraryFolders`) and, for playlists, from Home's « Vos playlists » rail.
///
/// Playlists get the playlist card (poster-stack cover, a count line that is
/// always laid out), its rename / delete menu, a « Nouvelle playlist » action
/// and a reload on `.cinemaxPlaylistsChanged`. Collections keep the plain
/// poster grid, unchanged.
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
    /// Rename / delete / create — screen-level for the same reason: a dialog
    /// attached to a grid cell dies when the cell is recycled.
    @State private var playlistManagement: PlaylistManagementRequest?

    var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if isPlaylist {
                    ToolbarItem(placement: .topBarTrailing) {
                        // No glass button style of its own: iOS 26 already
                        // draws toolbar items in Liquid Glass (toolbar RULE).
                        Button {
                            playlistManagement = .create
                        } label: {
                            Label(loc.localized("playlist.new.label"), systemImage: "plus")
                        }
                    }
                }
            }
            #endif
            .navigationDestination(item: $selection) { sel in
                // A playlist is ORDERED, and only `getPlaylistItems` returns it
                // in order — a `parentId` query cannot.
                if isPlaylist {
                    PlaylistDetailScreen(playlistId: sel.id, title: sel.name, canManage: sel.canManage)
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
            // A playlist created, renamed or deleted — here or anywhere else.
            // `load` keeps the grid on screen while it refetches.
            .onReceive(NotificationCenter.default.publisher(for: .cinemaxPlaylistsChanged)) { _ in
                guard isPlaylist else { return }
                Task { await viewModel.load(source: source, using: appState) }
            }
            .playlistManagement($playlistManagement)
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
            if isPlaylist {
                // Not a dead end: the first playlist can be made right here.
                EmptyStateView(
                    systemImage: "music.note.list",
                    title: loc.localized("library.playlists.empty"),
                    actionTitle: loc.localized("playlist.new.label"),
                    onAction: { playlistManagement = .create }
                )
            } else {
                EmptyStateView(
                    systemImage: "rectangle.stack",
                    title: loc.localized("library.collections.empty")
                )
            }
        case .loaded(let folders):
            grid(folders)
        }
    }

    private func grid(_ folders: [BaseItemDto]) -> some View {
        ScrollView {
            #if os(tvOS)
            // tvOS renders no navigation bar, so `.navigationTitle` above draws
            // nothing at all — the page arrived untitled. Same in-scroll title
            // `FavoritesScreen` carries. Playlists put their « Nouvelle
            // playlist » beside it (iOS has it in the toolbar), in its own
            // focus section so an up-press from the grid reaches it.
            HStack(alignment: .center, spacing: CinemaSpacing.spacing4) {
                Text(title)
                    .font(CinemaFont.display(.small))
                    .foregroundStyle(CinemaColor.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isPlaylist {
                    CinemaButton(title: loc.localized("playlist.new.label"), style: .ghost, icon: "plus") {
                        playlistManagement = .create
                    }
                    .frame(width: CinemaTVLayout.ctaWidth)
                }
            }
            .focusSection()
            .padding(.horizontal, gridPadding)
            .padding(.top, CinemaSpacing.spacing5)
            #endif

            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(folders, id: \.id) { folder in
                    if isPlaylist {
                        playlistCard(folder)
                    } else {
                        collectionCard(folder)
                    }
                }
            }
            #if os(tvOS)
            // A section of its own, so Down from the header's « Nouvelle
            // playlist » always enters the grid: the focus engine only moves
            // to what lies in the button's path, and with fewer than six
            // playlists nothing sits under a trailing 240 pt button — focus
            // was trapped between it and the tab bar.
            .focusSection()
            #endif
            .padding(.horizontal, gridPadding)
            .padding(.top, CinemaSpacing.spacing3)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #else
        // Pull-to-refresh has no gesture on a remote — the modifier is inert
        // on tvOS and only reads as if a refresh were available.
        .refreshable {
            // A change made on another device: the covers and counts are
            // re-asked too, not just the list.
            if isPlaylist { PlaylistPreviewStore.shared.invalidate() }
            await viewModel.load(source: source, using: appState)
        }
        #endif
    }

    /// The playlist card: poster-stack cover, a count line that is always laid
    /// out (cards of one row share a height whatever they know), and the
    /// playlist's rename / delete menu when the server allows it.
    private func playlistCard(_ playlist: BaseItemDto) -> some View {
        PlaylistCardButton(playlist: playlist) {
            if let id = playlist.id {
                // The RAW name — see `PlaylistDetailScreen.init`.
                selection = FolderSelection(
                    id: id,
                    name: playlist.name ?? "",
                    canManage: playlist.canDelete == true
                )
            }
        } onManage: { request in
            playlistManagement = request
        }
    }

    private func collectionCard(_ folder: BaseItemDto) -> some View {
        Button {
            if let id = folder.id {
                selection = FolderSelection(id: id, name: folder.name ?? title, canManage: false)
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

    private var columns: [GridItem] {
        #if os(tvOS)
        CinemaTVLayout.posterGridColumns
        #else
        // Square playlist covers read best two-up on a phone and four-up on an
        // iPad; collections keep their three 2:3 posters a row.
        let count = isPlaylist
            ? (AdaptiveLayout.form(horizontalSizeClass: sizeClass) == .regular ? 4 : 2)
            : 3
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.gridGutter
        #else
        16
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

/// `navigationDestination(item:)` payload — the tapped folder's id + display
/// name, and for a playlist whether its page offers rename / delete (the
/// server's `canDelete`).
private struct FolderSelection: Identifiable, Hashable {
    let id: String
    let name: String
    let canManage: Bool
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
    /// Three callers can overlap (`.task`, pull-to-refresh, and the
    /// `.cinemaxPlaylistsChanged` reload): only the newest load may write, or
    /// a slower, older answer could bring back a playlist just deleted.
    @ObservationIgnored private var loadGeneration = 0

    func load(source: LibraryFolderBrowseScreen.Source, using appState: AppState) async {
        loadGeneration += 1
        let generation = loadGeneration
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
                    sortOrder: [.ascending],
                    // `.items` seul : cet écran liste des dossiers, il n'affiche
                    // ni total ni pagination.
                    enableTotalRecordCount: false
                ).items
            case .playlists:
                folders = try await appState.apiClient.getPlaylists(userId: userId)
            }
            guard generation == loadGeneration else { return }
            state = folders.isEmpty ? .empty : .loaded(folders)
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed
        }
    }
}
