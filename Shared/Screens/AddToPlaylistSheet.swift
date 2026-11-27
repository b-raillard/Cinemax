import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Playlists")

// MARK: - "Add to a playlist"
//
// Playlists were browse-only: `LibraryFolderBrowseScreen` listed them and a
// scoped `MediaLibraryScreen` showed their contents, but nothing in the app
// could put anything in one. This is the write surface.
//
// Presented from a single place — the root of `AppNavigation` — rather than from
// each calling screen. The action is raised from poster context menus that live
// inside `LazyVGrid`s, and a presentation attached to a lazy child dies with the
// cell when it scrolls out. Hoisting it to the root also means the search grid,
// the library grid, the watched history and the detail screen all reuse one
// sheet with no per-screen plumbing — the same reasoning as `ToastOverlay`.

/// What the sheet is adding. `Identifiable` for `sheet(item:)`'s identity
/// contract; a fresh `id` per request so raising the same item twice re-presents.
struct AddToPlaylistRequest: Identifiable, Hashable {
    let id = UUID()
    let itemId: String
    let title: String
}

/// Root-injected raiser. Any screen can call `present(...)` without owning
/// presentation state.
@MainActor
@Observable
final class AddToPlaylistPresenter {
    var request: AddToPlaylistRequest?

    func present(itemId: String?, title: String?) {
        guard let itemId, !itemId.isEmpty else { return }
        request = AddToPlaylistRequest(itemId: itemId, title: title ?? "")
    }

    /// The request as `host` should present it: while the deep-link modal is
    /// up it is the one presenter (the root cannot present over it).
    func request(for host: PresentationHost) -> AddToPlaylistRequest? {
        host == .modal || !modalIsUp ? request : nil
    }

    /// Whether the deep-link modal fiche is up — assigned by `MainTabView`
    /// from `deepLinkFallback`, as `SeerrRequestPresenter.modalIsUp`.
    private(set) var modalIsUp = false
    /// The modal came, went or was replaced: the open request goes with it.
    func modalChanged(isUp: Bool) {
        modalIsUp = isUp
        request = nil
    }
}

/// Who presents a root-hosted flow (the playlist sheet, the Seerr request)
/// raised from a screen: the app's root, or the deep-link modal fiche
/// (`MainTabView.deepLinkDetail`), over which the root cannot present.
enum PresentationHost {
    case root, modal
}

/// Sheet-scoped model. Nothing outlives the sheet.
@MainActor
@Observable
final class AddToPlaylistModel {
    var playlists: [BaseItemDto] = []
    var isLoading = false
    var errorMessage: String?
    /// True while a create/add is in flight — disables every row and the
    /// create button so a double tap can't add twice.
    var busy = false
    var newPlaylistName = ""
    /// The ENTRY ids that stand for the title in each playlist holding it (a
    /// series: its episodes). A playlist missing here has not answered yet —
    /// its row then offers the add, which is what the sheet always did.
    private(set) var membership: [String: [String]] = [:]

    func isMember(_ playlistId: String?) -> Bool {
        playlistId.flatMap { membership[$0] }?.isEmpty == false
    }

    /// Which playlists already hold the title. Jellyfin has no « playlists
    /// containing this item » read, so each playlist's entries are asked for,
    /// in parallel; a playlist that fails to answer is left unknown.
    func loadMembership(itemId: String, userId: String?, api: any PlaylistAPI) async {
        guard let userId else { return }
        let ids = playlists.compactMap(\.id)
        await withTaskGroup(of: (String, [String])?.self) { group in
            for playlistId in ids {
                group.addTask {
                    guard let items = try? await api.getPlaylistItems(playlistId: playlistId, userId: userId) else {
                        return nil
                    }
                    return (playlistId, PlaylistMembership.entryIds(matching: itemId, in: items))
                }
            }
            for await answer in group {
                if let answer { membership[answer.0] = answer.1 }
            }
        }
    }

    func load(userId: String?, api: any PlaylistAPI, loc: LocalizationManager) async {
        guard let userId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            playlists = try await api.getPlaylists(userId: userId)
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
        }
    }
}

struct AddToPlaylistSheet: View {
    let request: AddToPlaylistRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast

    @State private var model = AddToPlaylistModel()

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        NavigationStack {
            iosBody
                .navigationTitle(loc.localized("playlist.add.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(loc.localized("action.done")) { dismiss() }
                            .tint(themeManager.accent)
                    }
                }
        }
        #endif
    }

    // MARK: - iOS

    #if os(iOS)
    private var iosBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                itemHeader
                createSection
                playlistList
            }
            .padding(CinemaSpacing.spacing4)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .task { await reload() }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    // Focus section so an up-press from the rows reaches Done
                    // instead of being absorbed — same reason as
                    // `RemotePlaySheet` / `PrivacySecurityScreen`.
                    HStack {
                        Text(loc.localized("playlist.add.title"))
                            .font(CinemaFont.headline(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                        Spacer()
                        // Accent, like every other cover's Done — this one and
                        // « Lire sur… » were the only two drawn as ghosts.
                        CinemaButton(title: loc.localized("action.done"), style: .accent) { dismiss() }
                            .frame(width: CinemaTVLayout.ctaWidth)
                    }
                    .focusSection()

                    itemHeader
                    createSection
                    playlistList
                }
                .padding(.horizontal, CinemaTVLayout.pagePadding)
                .padding(.vertical, CinemaSpacing.spacing8)
            }
        }
        .task { await reload() }
    }
    #endif

    // MARK: - Shared pieces

    /// Reminds the user what is being added — the sheet is raised from a long
    /// press on a poster, so by the time it opens the card may be off screen.
    @ViewBuilder
    private var itemHeader: some View {
        if !request.title.isEmpty {
            Text(request.title)
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .lineLimit(2)
        }
    }

    /// Create-and-add in one step: the new playlist is seeded with this item, so
    /// the user never has to create it and then find it in the list below.
    private var createSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            GlassTextField(
                label: loc.localized("playlist.new.label"),
                text: $model.newPlaylistName,
                placeholder: loc.localized("playlist.new.placeholder"),
                icon: "text.badge.plus"
            )
            CinemaButton(title: loc.localized("playlist.new.create"), style: .accent) {
                createAndAdd()
            }
            .disabled(model.busy || trimmedNewName.isEmpty)
        }
    }

    private var trimmedNewName: String {
        model.newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var playlistList: some View {
        // The spinner only before the first answer: every press reloads the
        // list (counts, ticks), and swapping the rows for a spinner dropped
        // the tvOS focus off the row that had just been pressed.
        if model.isLoading && model.playlists.isEmpty {
            LoadingStateView()
        } else if let error = model.errorMessage {
            ErrorStateView(message: error, retryTitle: loc.localized("action.retry")) {
                Task { await reload() }
            }
        } else if model.playlists.isEmpty {
            // Not a dead end: the create field above is the way out, which is
            // why it sits above the list rather than below it.
            EmptyStateView(
                systemImage: "music.note.list",
                title: loc.localized("playlist.empty.title"),
                subtitle: loc.localized("playlist.empty.subtitle")
            )
        } else {
            VStack(spacing: CinemaSpacing.spacing3) {
                ForEach(model.playlists, id: \.id) { playlist in
                    playlistRow(playlist)
                }
            }
        }
    }

    /// One playlist row. tvOS uses the validated full-width-row treatment
    /// (`TVFilterRowButtonStyle` + effects disabled), matching `RemotePlaySheet`.
    @ViewBuilder
    private func playlistRow(_ playlist: BaseItemDto) -> some View {
        let row = rowButton(playlist)
        #if os(tvOS)
        row.buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
            .focusEffectDisabled()
            .hoverEffectDisabled()
        #else
        row.buttonStyle(.plain)
        #endif
    }

    private func rowButton(_ playlist: BaseItemDto) -> some View {
        let isMember = model.isMember(playlist.id)
        let count = loc.itemCount(playlist.childCount ?? 0)
        return Button {
            toggle(playlist)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                PlaylistSheetCover(playlist: playlist)
                    .frame(width: Self.coverSide)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(playlist))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                    Text(isMember ? count + " · " + loc.localized("playlist.sheet.contains") : count)
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: CinemaSpacing.spacing2)
                // A tick where the title already is, a plus where a press
                // would put it — the sheet used to offer « + » everywhere and
                // add a second copy without a word.
                Image(systemName: isMember ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: CinemaScale.pt(24), weight: .semibold))
                    .foregroundStyle(isMember ? themeManager.accent : CinemaColor.onSurfaceVariant)
            }
            .padding(CinemaSpacing.spacing3)
            .glassPanel()
            .contentShape(Rectangle())
        }
        .disabled(model.busy)
        .accessibilityLabel(displayName(playlist))
        .accessibilityValue(isMember ? loc.localized("playlist.sheet.contains") : "")
        .accessibilityHint(loc.localized(isMember ? "playlist.removeItem" : "playlist.add.title"))
        .accessibilityAddTraits(isMember ? [.isButton, .isSelected] : .isButton)
    }

    private static var coverSide: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(64)
        #else
        CinemaScale.pt(52)
        #endif
    }

    private func displayName(_ playlist: BaseItemDto) -> String {
        let name = playlist.name ?? ""
        return name.isEmpty ? loc.localized("playlist.untitled") : name
    }

    // MARK: - Actions

    private func reload() async {
        await model.load(userId: appState.currentUserId, api: appState.apiClient, loc: loc)
        await model.loadMembership(itemId: request.itemId, userId: appState.currentUserId, api: appState.apiClient)
    }

    /// One press adds the title, or takes it out of a playlist that holds it.
    /// The sheet STAYS open: a title often goes into more than one playlist,
    /// and « Terminé » is the way out.
    private func toggle(_ playlist: BaseItemDto) {
        guard !model.busy, let playlistId = playlist.id, let userId = appState.currentUserId else { return }
        let held = model.membership[playlistId] ?? []
        Task {
            model.busy = true
            defer { model.busy = false }
            do {
                if held.isEmpty {
                    try await appState.apiClient.addToPlaylist(
                        playlistId: playlistId, itemIds: [request.itemId], userId: userId
                    )
                    toast.success(loc.localized("playlist.added", displayName(playlist)))
                } else {
                    // Entry ids: every occurrence of the title (for a series,
                    // each of its episodes) is an entry of its own.
                    try await appState.apiClient.removeFromPlaylist(playlistId: playlistId, entryIds: held)
                    toast.success(loc.localized("playlist.removedFrom", displayName(playlist)))
                }
                NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
                await reload()
            } catch {
                logger.error("Playlist toggle failed: \(error.localizedDescription, privacy: .public)")
                toast.error(loc.userFacingMessage(for: error))
            }
        }
    }

    private func createAndAdd() {
        let name = trimmedNewName
        guard !model.busy, !name.isEmpty, let userId = appState.currentUserId else { return }
        Task {
            model.busy = true
            do {
                // Seeded with the item, so this is one round-trip rather than
                // create-then-add — and there is no window where the playlist
                // exists but is empty.
                _ = try await appState.apiClient.createPlaylist(
                    name: name,
                    itemIds: [request.itemId],
                    userId: userId
                )
                model.busy = false
                model.newPlaylistName = ""
                NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
                toast.success(loc.localized("playlist.added", name))
                await reload()
            } catch {
                model.busy = false
                logger.error("Create playlist failed: \(error.localizedDescription, privacy: .public)")
                toast.error(loc.userFacingMessage(for: error))
            }
        }
    }
}

// MARK: - Presentation

/// Presents the sheet — bottom sheet on iOS, full-screen cover on tvOS
/// (`.sheet` renders as a broken narrow modal on tvOS 26). Applied ONCE, at the
/// root of `AppNavigation`; see the file header for why it isn't attached at the
/// call sites. Environment objects are re-injected so the sheet's own
/// `@Environment` reads resolve regardless of automatic propagation — same shape
/// as `RemotePlayPresentation`.
struct AddToPlaylistPresentation: ViewModifier {
    let presenter: AddToPlaylistPresenter
    let appState: AppState
    let themeManager: ThemeManager
    let loc: LocalizationManager
    let toast: ToastCenter
    /// `.modal`: hosted inside the deep-link fiche (`MainTabView`), which
    /// then presents instead of the root — see `PresentationHost`.
    var host: PresentationHost = .root

    func body(content: Content) -> some View {
        presented(content)
    }

    @ViewBuilder
    private func presented(_ content: Content) -> some View {
        let request = Binding(get: { presenter.request(for: host) }, set: { presenter.request = $0 })
        #if os(tvOS)
        content.fullScreenCover(item: request) { request in sheetView(request) }
        #else
        content.sheet(item: request) { request in sheetView(request) }
        #endif
    }

    private func sheetView(_ request: AddToPlaylistRequest) -> some View {
        AddToPlaylistSheet(request: request)
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toast)
    }
}

/// A playlist's poster-stack cover on a row of the sheet, from the shared
/// preview store — the same request, held once, as the card on Home.
private struct PlaylistSheetCover: View {
    let playlist: BaseItemDto

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsKey.privacyMaxContentAge) private var maxContentAge: Int = SettingsKey.Default.privacyMaxContentAge

    private var store: PlaylistPreviewStore { .shared }

    var body: some View {
        let preview = playlist.id.flatMap { store.preview(for: $0) }
        PlaylistCover(
            content: PlaylistCoverStack.content(preview: preview, fallbackCount: playlist.childCount),
            imageBuilder: appState.imageBuilder,
            cornerRadius: CinemaRadius.medium
        )
        .accessibilityHidden(true)
        .task(id: Request(
            playlistId: playlist.id, userId: appState.currentUserId,
            contentAgeCap: maxContentAge, generation: store.generation
        )) {
            guard let id = playlist.id, let userId = appState.currentUserId else { return }
            store.load(playlistId: id, userId: userId, contentAgeCap: maxContentAge, api: appState.apiClient)
        }
    }

    private struct Request: Hashable {
        let playlistId: String?
        let userId: String?
        let contentAgeCap: Int
        let generation: Int
    }
}
