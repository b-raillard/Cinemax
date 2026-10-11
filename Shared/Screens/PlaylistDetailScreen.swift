import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

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
///
/// Headed by the playlist's poster-stack cover, built from the entries already
/// loaded (no extra request), its name and « N éléments · durée ». When the
/// server allows it (`canManage`, its `canDelete`), the iOS toolbar's « … »
/// renames or deletes the playlist; a deletion pops the page. tvOS manages
/// from the cards (long press), so its header stays unfocusable.
struct PlaylistDetailScreen: View {
    let playlistId: String
    /// Whether the page offers rename / delete — the server's `canDelete`,
    /// carried by the card that opened it. Defaults to `false`, so a call site
    /// that does not know shows no management rather than a refused one.
    let canManage: Bool

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    /// State, not a `let`: a rename made on this page retitles it.
    @State private var title: String
    @State private var viewModel = PlaylistDetailViewModel()
    @State private var playlistManagement: PlaylistManagementRequest?
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    init(playlistId: String, title: String, canManage: Bool = false) {
        self.playlistId = playlistId
        self.canManage = canManage
        _title = State(initialValue: title)
    }

    var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            // Inline: the header below carries the name in large type, under
            // the cover — a large title above it would say it twice.
            .navigationBarTitleDisplayMode(.inline)
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
                if canManage {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Whatever the contents — deleting an EMPTY playlist is
                        // one of the reasons this menu exists.
                        Menu {
                            Button {
                                playlistManagement = .rename(id: playlistId, name: title)
                            } label: {
                                Label(loc.localized("playlist.rename"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                playlistManagement = .delete(id: playlistId, name: title)
                            } label: {
                                Label(loc.localized("playlist.delete"), systemImage: "trash")
                            }
                        } label: {
                            Label(loc.localized("playlist.manage"), systemImage: "ellipsis")
                        }
                    }
                }
            }
            #endif
            .task(id: playlistId) {
                await viewModel.load(playlistId: playlistId, using: appState)
            }
            .playlistManagement(
                $playlistManagement,
                // Gone from the server: nothing left to show here.
                onDeleted: { _ in dismiss() },
                onRenamed: { _, newName in title = newName }
            )
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
            // The header alone — its cover says « vide » and its line says
            // « Cette playlist est vide »: a playlist page keeps its name and
            // its look even with nothing in it (and tvOS, which has no
            // navigation bar, keeps a title).
            ScrollView {
                #if os(tvOS)
                header
                    .padding(.horizontal, CinemaTVLayout.pagePadding)
                    .padding(.top, CinemaSpacing.spacing5)
                #else
                header
                #endif
            }
            #if os(iOS)
            .refreshable {
                await viewModel.load(playlistId: playlistId, using: appState)
            }
            #endif
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
            // The first row, OUTSIDE the `ForEach` that carries `.onMove` and
            // the swipe actions: the header is neither movable nor removable.
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .deleteDisabled(true)
                .moveDisabled(true)

            ForEach(viewModel.items, id: \.playlistItemID) { item in
                NavigationLink {
                    DeferredView {
                        if let id = item.id {
                            MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                        }
                    }
                } label: {
                    PlaylistRow(item: item, imageBuilder: appState.imageBuilder)
                }
                .listRowBackground(CinemaColor.surfaceContainerLow)
                .swipeActions(edge: .trailing) {
                    if let entryId = item.playlistItemID {
                        Button(role: .destructive) {
                            Task { await remove(entryId: entryId) }
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
        .background(SeasonalBackdrop().ignoresSafeArea())
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
            // Unfocusable: tvOS manages a playlist from its card's long press,
            // so the page's only focusable rows are its entries.
            header
                .padding(.horizontal, CinemaTVLayout.pagePadding)
                .padding(.top, CinemaSpacing.spacing5)

            LazyVStack(spacing: CinemaSpacing.spacing3) {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.playlistItemID) { index, item in
                    // A `NavigationLink` rather than the hoisted
                    // `navigationDestination(item:)` the folder browser uses:
                    // the destination closure is honored inside a lazy
                    // container, only the `item:` modifier is not.
                    NavigationLink {
                        DeferredView {
                            if let id = item.id {
                                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                            }
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
                        if let entryId = item.playlistItemID {
                            Button(role: .destructive) {
                                Task { await remove(entryId: entryId) }
                            } label: {
                                Label(loc.localized("playlist.removeItem"), systemImage: "minus.circle")
                            }
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

    // MARK: - Header

    /// The cover, the name and « N éléments · durée ». Built from the loaded
    /// entries: the cover takes their posters (series poster for an episode,
    /// never a repeat), at the very URLs the cards ask for.
    private var header: some View {
        let cover = PlaylistCoverStack.content(
            preview: PlaylistPreview(
                posters: PlaylistCoverStack.posters(from: viewModel.items),
                totalCount: viewModel.items.count
            ),
            fallbackCount: nil
        )
        #if os(tvOS)
        return HStack(alignment: .center, spacing: CinemaSpacing.spacing8) {
            PlaylistCover(content: cover, imageBuilder: appState.imageBuilder)
                .frame(width: CinemaTVLayout.playlistCoverSide)
            headerText(alignment: .leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        #else
        return VStack(spacing: CinemaSpacing.spacing3) {
            PlaylistCover(content: cover, imageBuilder: appState.imageBuilder)
                .frame(width: 216)
            headerText(alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CinemaSpacing.spacing3)
        .accessibilityElement(children: .combine)
        #endif
    }

    private func headerText(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: CinemaSpacing.spacing1) {
            Text(title)
                .font(CinemaFont.headline(.medium))
                .foregroundStyle(CinemaColor.onSurface)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text(headerMeta)
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceMuted)
                .lineLimit(1)
        }
    }

    /// « 4 éléments · 6 h 12 min ». A SERIES entry adds nothing to the
    /// duration: its runtime is one episode's, not the show's total (a season
    /// likewise carries no total of its own). An empty playlist says so.
    private var headerMeta: String {
        let items = viewModel.items
        if items.isEmpty { return loc.localized("playlist.contents.empty") }
        var parts = [loc.itemCount(items.count)]
        let ticks = items
            .filter { $0.type != .series && $0.type != .season }
            .compactMap(\.runTimeTicks)
            .reduce(0, +)
        if ticks.jellyfinMinutes > 0 { parts.append(loc.runtime(minutes: ticks.jellyfinMinutes)) }
        return parts.joined(separator: " · ")
    }

    private func remove(entryId: String) async {
        switch await viewModel.remove(entryId: entryId, playlistId: playlistId, using: appState) {
        case .removed:
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
            toast.success(loc.localized("playlist.removeItem.done"))
        case .notFound:
            // The list moved under an open menu. Nothing was sent, so nothing
            // is announced — a toast here would report a removal that never
            // happened.
            break
        case .failed(let error):
            toast.error(loc.userFacingMessage(for: error))
        }
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
    /// What a removal actually did. `nil` used to mean both "removed" and
    /// "found nothing", so a stale index still toasted a removal and posted a
    /// change notification.
    enum RemoveOutcome {
        case removed
        /// No entry with that id — the list moved under a menu that was already
        /// open. Nothing was sent and nothing is claimed.
        case notFound
        case failed(any Error)
    }

    /// Removes an entry and tells the server. On refusal the row is already
    /// back — the screen must not claim a removal the playlist did not record.
    ///
    /// Takes the ENTRY id, not an index: the same film can sit in a playlist
    /// twice, only `getPlaylistItems` populates `playlistItemID`, and a menu
    /// closure built before a reload would carry an index that now points at a
    /// different row. Resolving the position here makes the guarantee
    /// unconditional rather than dependent on the list not having moved.
    func remove(entryId: String, playlistId: String, using appState: AppState) async -> RemoveOutcome {
        guard let index = items.firstIndex(where: { $0.playlistItemID == entryId }) else {
            return .notFound
        }
        let snapshot = items
        items.remove(at: index)
        if items.isEmpty { state = .empty }
        do {
            try await appState.apiClient.removeFromPlaylist(playlistId: playlistId, entryIds: [entryId])
            return .removed
        } catch {
            logger.error("Playlist remove failed: \(error.localizedDescription, privacy: .public)")
            items = snapshot
            state = .loaded
            return .failed(error)
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
            // NOT `.notConnected`, which `userFacingMessage` renders as a
            // network problem: the server is fine, this entry simply has no id
            // to address it by.
            return JellyfinError.malformedRecord
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
