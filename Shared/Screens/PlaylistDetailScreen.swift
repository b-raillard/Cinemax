import SwiftUI
import OSLog
import CinemaxKit
@preconcurrency import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "PlaylistDetail")

/// Where a `.onMove` lands, in Jellyfin's terms.
///
/// SwiftUI hands `to` as an insertion point in the list **as it stands before**
/// the row is lifted out; Jellyfin's `movePlaylistItem` wants the entry's final
/// 0-based index **after** the move. The two agree when dragging upward and
/// differ by one when dragging downward — the off-by-one that silently drops a
/// row one slot short of where the finger left it.
enum PlaylistReorder {
    static func destinationIndex(from source: Int, to destination: Int) -> Int {
        destination > source ? destination - 1 : destination
    }
}

/// One playlist, in playlist order, reorderable.
///
/// A dedicated screen rather than the scoped `MediaLibraryScreen` the folder
/// browser used to push, for two reasons that are really one: a playlist is an
/// **ordered** collection, and only `getPlaylistItems` returns it in that order
/// — and only it populates `playlistItemID`, the ENTRY id every mutation is
/// addressed by (the same film can sit in a playlist twice, and each occurrence
/// moves independently). A `parentId` query returns neither.
struct PlaylistDetailScreen: View {
    let playlistId: String
    let title: String

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast
    @Environment(ThemeManager.self) private var themeManager

    @State private var viewModel = PlaylistDetailViewModel()
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .environment(\.editMode, $editMode)
            .toolbar {
                if !viewModel.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        // NOT the system `EditButton`: it takes its title from
                        // the DEVICE language, so it read "Edit" over a French
                        // app on an English phone — and the app's language is a
                        // setting of its own here, independent of the system's.
                        Button {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        } label: {
                            Text(loc.localized(editMode.isEditing ? "action.done" : "playlist.reorder"))
                        }
                    }
                }
            }
            #endif
            .task(id: playlistId) {
                await viewModel.load(playlistId: playlistId, using: appState)
            }
            // Only ever pushed (Home's playlists rail, or the Playlists tab's
            // folder browser) — see `tvPushedScreen`.
            .tvPushedScreen()
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
                Task { await viewModel.load(playlistId: playlistId, using: appState) }
            }
        case .empty:
            EmptyStateView(
                systemImage: "music.note.list",
                title: loc.localized("playlist.contents.empty")
            )
        case .loaded:
            list
        }
    }

    #if os(iOS)
    /// A native `List` — the same deliberate exception `MenuSettingsScreen+iOS`
    /// makes, and for the same reason: `.onMove` with the system's own ≡ handle
    /// exists nowhere else.
    ///
    /// Unlike that screen this one does NOT force edit mode on permanently.
    /// There, every row is a toggle; here every row opens an item, and an
    /// always-editing `List` swallows the taps that would open it. The
    /// `EditButton` is what keeps both gestures available — the same split
    /// Music.app makes.
    private var list: some View {
        List {
            ForEach(viewModel.items, id: \.playlistItemID) { item in
                NavigationLink {
                    if let id = item.id {
                        MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                    }
                } label: {
                    PlaylistRow(item: item, imageBuilder: appState.imageBuilder)
                }
                .listRowBackground(CinemaColor.surfaceContainerLow)
                .swipeActions(edge: .trailing) {
                    if let index = viewModel.items.firstIndex(where: { $0.playlistItemID == item.playlistItemID }) {
                        Button(role: .destructive) {
                            Task { await remove(at: index) }
                        } label: {
                            Label(loc.localized("playlist.removeItem"), systemImage: "minus.circle")
                        }
                    }
                }
            }
            .onMove { offsets, destination in
                guard let source = offsets.first else { return }
                Task { await move(from: source, to: destination) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CinemaColor.surface.ignoresSafeArea())
        .refreshable {
            await viewModel.load(playlistId: playlistId, using: appState)
        }
    }
    #else
    /// tvOS has no drag-and-drop and no `EditButton`. Each row carries the two
    /// moves it can make instead — the standard answer on a focus-driven
    /// remote, and enough to reach any arrangement.
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: CinemaSpacing.spacing3) {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.playlistItemID) { index, item in
                    // A `NavigationLink` rather than the hoisted
                    // `navigationDestination(item:)` the folder browser uses:
                    // the destination closure is honored inside a lazy
                    // container, only the `item:` modifier is not.
                    NavigationLink {
                        if let id = item.id {
                            MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                        }
                    } label: {
                        PlaylistRow(item: item, imageBuilder: appState.imageBuilder)
                            .padding(CinemaSpacing.spacing3)
                            .background(CinemaColor.surfaceContainerLow, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
                    }
                    // A full-width row, so the accent stroke rather than the
                    // card style — scaling a row this wide visibly shifts its
                    // own content sideways.
                    .buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
                    .focusEffectDisabled()
                    .hoverEffectDisabled()
                    .contextMenu {
                        if index > 0 {
                            Button {
                                Task { await move(from: index, to: index - 1) }
                            } label: {
                                Label(loc.localized("playlist.moveUp"), systemImage: "arrow.up")
                            }
                        }
                        Button(role: .destructive) {
                            Task { await remove(at: index) }
                        } label: {
                            Label(loc.localized("playlist.removeItem"), systemImage: "minus.circle")
                        }
                        if index < viewModel.items.count - 1 {
                            Button {
                                // `+2` because SwiftUI's move destination is an
                                // insertion point in the pre-move list — the
                                // same convention `PlaylistReorder` normalises.
                                Task { await move(from: index, to: index + 2) }
                            } label: {
                                Label(loc.localized("playlist.moveDown"), systemImage: "arrow.down")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, CinemaTVLayout.pagePadding)
            .padding(.top, CinemaSpacing.spacing3)
        }
        .scrollClipDisabled()
    }
    #endif

    private func remove(at index: Int) async {
        guard let failure = await viewModel.remove(at: index, playlistId: playlistId, using: appState) else {
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
            toast.success(loc.localized("playlist.removeItem.done"))
            return
        }
        toast.error(loc.userFacingMessage(for: failure))
    }

    private func move(from source: Int, to destination: Int) async {
        let target = PlaylistReorder.destinationIndex(from: source, to: destination)
        guard let failure = await viewModel.move(from: source, to: target, playlistId: playlistId, using: appState) else {
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
            return
        }
        toast.error(loc.userFacingMessage(for: failure))
    }
}

/// One entry: its poster, its title, and what it is.
private struct PlaylistRow: View {
    let item: BaseItemDto
    let imageBuilder: ImageURLBuilder

    var body: some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: posterWidth)
                .overlay {
                    CinemaLazyImage(
                        url: item.id.map {
                            imageBuilder.imageURL(
                                itemId: $0, imageType: .primary,
                                maxWidth: 200, tag: item.primaryImageTagValue
                            )
                        },
                        fallbackIcon: "film"
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                // Scaled to FILL, so a 16:9 episode still overflows a 2:3 slot
                // and stays hit-testable past the clip without this.
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "")
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(2)
                Text(subtitle)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, CinemaSpacing.spacing1)
    }

    private var subtitle: String {
        var parts: [String] = []
        if item.type == .episode, let series = item.seriesName { parts.append(series) }
        if let year = item.productionYear { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    private var posterWidth: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(76)
        #else
        CinemaScale.pt(46)
        #endif
    }
}

@MainActor
@Observable
final class PlaylistDetailViewModel {
    enum State {
        case loading
        case loaded
        case empty
        case failed
    }

    private(set) var state: State = .loading
    private(set) var items: [BaseItemDto] = []

    func load(playlistId: String, using appState: AppState) async {
        guard let userId = appState.currentUserId else {
            state = .failed
            return
        }
        if case .loaded = state {} else { state = .loading }
        do {
            items = try await appState.apiClient.getPlaylistItems(playlistId: playlistId, userId: userId)
            state = items.isEmpty ? .empty : .loaded
        } catch {
            logger.error("Playlist load failed: \(error.localizedDescription, privacy: .public)")
            state = .failed
        }
    }

    /// Removes an entry and tells the server. Returns the error when the server
    /// refused, having already put the row back — the screen must not claim a
    /// removal the playlist did not record.
    ///
    /// Addressed by ENTRY id, never item id: the same film can sit in a
    /// playlist twice and only `getPlaylistItems` populates `playlistItemID`.
    /// An entry without one is refused rather than removing the wrong
    /// occurrence — the same guard `move` makes.
    func remove(at index: Int, playlistId: String, using appState: AppState) async -> (any Error)? {
        guard items.indices.contains(index) else { return nil }
        let snapshot = items
        let entry = items.remove(at: index)
        guard let entryId = entry.playlistItemID else {
            items = snapshot
            return JellyfinError.notConnected
        }
        if items.isEmpty { state = .empty }
        do {
            try await appState.apiClient.removeFromPlaylist(playlistId: playlistId, entryIds: [entryId])
            return nil
        } catch {
            logger.error("Playlist remove failed: \(error.localizedDescription, privacy: .public)")
            items = snapshot
            state = .loaded
            return error
        }
    }

    /// Moves an entry and tells the server. Returns the error when the server
    /// refused, having already put the list back — the row must not stay where
    /// the finger dropped it if the playlist did not actually change.
    ///
    /// Optimistic on purpose: a drag that waits for a round-trip before the row
    /// settles reads as a dropped gesture.
    func move(from source: Int, to target: Int, playlistId: String, using appState: AppState) async -> (any Error)? {
        guard items.indices.contains(source), target >= 0, target < items.count else { return nil }
        let snapshot = items
        let entry = items.remove(at: source)
        items.insert(entry, at: target)
        guard let entryId = entry.playlistItemID else {
            // No entry id means the list did not come from `getPlaylistItems`,
            // which is the only thing that populates it — refuse rather than
            // address the wrong occurrence.
            items = snapshot
            return JellyfinError.notConnected
        }
        do {
            try await appState.apiClient.movePlaylistItem(
                playlistId: playlistId, entryId: entryId, newIndex: target
            )
            return nil
        } catch {
            logger.error("Playlist move failed: \(error.localizedDescription, privacy: .public)")
            items = snapshot
            return error
        }
    }
}
