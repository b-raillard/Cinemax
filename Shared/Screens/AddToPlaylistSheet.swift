import SwiftUI
import OSLog
import CinemaxKit

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
                        CinemaButton(title: loc.localized("action.done"), style: .ghost) { dismiss() }
                            .frame(width: 240)
                    }
                    .focusSection()

                    itemHeader
                    createSection
                    playlistList
                }
                .padding(CinemaSpacing.spacing8)
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
        if model.isLoading {
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
        Button {
            add(to: playlist)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "music.note.list")
                    .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(playlist))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                    Text(loc.localized("playlist.itemCount", playlist.childCount ?? 0))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: CinemaSpacing.spacing2)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
            }
            .padding(CinemaSpacing.spacing4)
            .glassPanel()
        }
        .disabled(model.busy)
        .accessibilityLabel(displayName(playlist))
        .accessibilityHint(loc.localized("playlist.add.title"))
    }

    private func displayName(_ playlist: BaseItemDto) -> String {
        let name = playlist.name ?? ""
        return name.isEmpty ? loc.localized("playlist.untitled") : name
    }

    // MARK: - Actions

    private func reload() async {
        await model.load(userId: appState.currentUserId, api: appState.apiClient, loc: loc)
    }

    private func add(to playlist: BaseItemDto) {
        guard !model.busy, let playlistId = playlist.id, let userId = appState.currentUserId else { return }
        Task {
            model.busy = true
            do {
                try await appState.apiClient.addToPlaylist(
                    playlistId: playlistId,
                    itemIds: [request.itemId],
                    userId: userId
                )
                model.busy = false
                toast.success(loc.localized("playlist.added", displayName(playlist)))
                dismiss()
            } catch {
                // Sheet stays open so the user can retry or pick another one.
                model.busy = false
                logger.error("Add to playlist failed: \(error.localizedDescription, privacy: .public)")
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
                toast.success(loc.localized("playlist.added", name))
                dismiss()
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
    @Binding var request: AddToPlaylistRequest?
    let appState: AppState
    let themeManager: ThemeManager
    let loc: LocalizationManager
    let toast: ToastCenter

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.fullScreenCover(item: $request) { request in sheetView(request) }
        #else
        content.sheet(item: $request) { request in sheetView(request) }
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
