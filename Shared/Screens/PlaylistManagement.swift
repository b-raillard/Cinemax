import SwiftUI
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playlists")

// MARK: - Playlist management: rename, delete, create
//
// One host, shared by the three screens that list playlists (Home's rail,
// « Vos playlists », a playlist's own page). The request lives in a `@State`
// at SCREEN level and the host is applied to the screen's body: the cards sit
// in a `LazyHStack` / `LazyVGrid`, where a presentation attached to the cell
// dies when the cell is recycled (the lazy-container RULE) — the same reason
// « Ajouter à une playlist » is hosted at the root.
//
// Not here, deliberately: « Lire » / « Lecture aléatoire » (the app has no
// play queue — `EpisodeNavigator` stays the only next/prev authority) and
// « Masquer de l'accueil » (it would need a per-server persisted list and a
// screen to bring a playlist back).

/// A management action on one playlist (or the creation of a new one), raised
/// by a card's menu or a toolbar and carried out by `.playlistManagement`.
enum PlaylistManagementRequest: Equatable {
    /// `name` pre-fills the field — the playlist's own name, not a placeholder.
    case rename(id: String, name: String)
    /// `name` is what the confirmation names.
    case delete(id: String, name: String)
    case create
}

extension View {
    /// Hosts the rename / delete / create dialogs for a screen. Apply it to the
    /// screen's body, OUTSIDE every lazy container, and raise a request by
    /// assigning `request` — the host consumes it (sets it back to `nil`).
    ///
    /// On success the host posts `.cinemaxPlaylistsChanged` (every list of
    /// playlists, and the cover store, refresh from it) and toasts; the
    /// callbacks are for what only the screen knows — a playlist's page pops
    /// itself once deleted and retitles itself once renamed.
    func playlistManagement(
        _ request: Binding<PlaylistManagementRequest?>,
        onDeleted: ((String) -> Void)? = nil,
        onRenamed: ((String, String) -> Void)? = nil
    ) -> some View {
        modifier(PlaylistManagementHost(request: request, onDeleted: onDeleted, onRenamed: onRenamed))
    }

    /// A playlist card's long-press menu: « Renommer » and « Supprimer la
    /// playlist ». Attach it to the card's focusable `Button`, never its label
    /// (tvOS focus). `canManage` false attaches no menu at all — not an empty
    /// one.
    ///
    /// `labels` are resolved by the CALLER and captured: a `contextMenu`'s
    /// content is a separate presentation context that receives no injected
    /// `@Observable` (the crash documented in `docs/rules/playlists.md`). The
    /// iOS preview (`preview`, ignored on tvOS) lifts the cover alone, built
    /// from the same values as the card's, so it serves from the same image
    /// cache entries; pass it with `cornerRadius: 0` — the system platter
    /// already rounds it.
    func playlistCardContextMenu(
        canManage: Bool,
        labels: PlaylistMenuLabels,
        preview: PlaylistCover,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(PlaylistCardContextMenu(
            canManage: canManage, labels: labels, preview: preview,
            onRename: onRename, onDelete: onDelete
        ))
    }
}

/// The two strings of a playlist card's menu, resolved before the menu exists.
struct PlaylistMenuLabels: Equatable {
    let rename: String
    let delete: String
}

// MARK: - Card menu

private struct PlaylistCardContextMenu: ViewModifier {
    let canManage: Bool
    let labels: PlaylistMenuLabels
    let preview: PlaylistCover
    let onRename: () -> Void
    let onDelete: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canManage {
            #if os(iOS)
            // An explicit preview, like the poster cards': the default one
            // lifts the whole label, title and count included — text with no
            // background, floating over whatever sits below the card.
            content.contextMenu {
                menuItems
            } preview: {
                preview
                    .frame(width: Self.previewSide)
            }
            #else
            content.contextMenu { menuItems }
            #endif
        } else {
            content
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onRename) {
            Label(labels.rename, systemImage: "pencil")
        }
        // The destructive entry in a group of its own, as on the mock-up.
        Divider()
        Button(role: .destructive, action: onDelete) {
            Label(labels.delete, systemImage: "trash")
        }
    }

    private static let previewSide: CGFloat = 220
}

// MARK: - Host

private struct PlaylistManagementHost: ViewModifier {
    @Binding var request: PlaylistManagementRequest?
    let onDeleted: ((String) -> Void)?
    let onRenamed: ((String, String) -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast

    /// The request, once consumed, drives these — set together with the
    /// field's text, so an alert never opens on the previous text (the
    /// `ServersScreen` rename order: text first, then the presentation).
    @State private var renaming: Target?
    @State private var deleting: Target?
    @State private var isCreating = false
    @State private var nameText = ""
    /// One server call at a time: a double tap must not delete or create twice.
    @State private var isBusy = false

    private struct Target: Equatable {
        let id: String
        let name: String
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, newValue in
                guard let newValue else { return }
                begin(newValue)
                request = nil
            }
            .confirmationDialog(
                loc.localized("playlist.delete"),
                isPresented: Binding(
                    get: { deleting != nil },
                    set: { if !$0 { deleting = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleting
            ) { target in
                Button(loc.localized("playlist.delete"), role: .destructive) {
                    Task { await delete(target) }
                }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: { target in
                Text(loc.localized("playlist.delete.message", target.name))
            }
            .alert(
                loc.localized("playlist.rename.title"),
                isPresented: Binding(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } }
                ),
                presenting: renaming
            ) { target in
                TextField(loc.localized("playlist.new.placeholder"), text: $nameText)
                Button(loc.localized("action.save")) {
                    let name = nameText
                    Task { await rename(target, to: name) }
                }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            }
            .alert(loc.localized("playlist.new.label"), isPresented: $isCreating) {
                TextField(loc.localized("playlist.new.placeholder"), text: $nameText)
                Button(loc.localized("playlist.create")) {
                    let name = nameText
                    Task { await create(named: name) }
                }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: {
                Text(loc.localized("playlist.create.message"))
            }
    }

    private func begin(_ request: PlaylistManagementRequest) {
        switch request {
        case let .rename(id, name):
            nameText = name
            renaming = Target(id: id, name: name)
        case let .delete(id, name):
            deleting = Target(id: id, name: name)
        case .create:
            nameText = ""
            isCreating = true
        }
    }

    private func delete(_ target: Target) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await appState.apiClient.deletePlaylist(playlistId: target.id)
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
            toast.success(loc.localized("playlist.delete.done"))
            onDeleted?(target.id)
        } catch {
            logger.error("Playlist delete failed: \(error.localizedDescription, privacy: .public)")
            // A dedicated title, NOT `userFacingMessage`: the server refuses a
            // delete with 401 (« not your playlist »), which that mapping
            // reads as « session expirée ». An unreachable server still says
            // so underneath.
            let detail = loc.userFacingMessage(for: error)
            toast.error(
                loc.localized("playlist.delete.failed"),
                message: detail == loc.localized("error.network") ? detail : nil
            )
        }
    }

    private func rename(_ target: Target, to rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An emptied field or an unchanged name is not a rename.
        guard !name.isEmpty, name != target.name, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await appState.apiClient.renamePlaylist(playlistId: target.id, name: name)
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
            toast.success(loc.localized("playlist.rename.done"))
            onRenamed?(target.id, name)
        } catch {
            logger.error("Playlist rename failed: \(error.localizedDescription, privacy: .public)")
            toast.error(loc.userFacingMessage(for: error))
        }
    }

    private func create(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isBusy, let userId = appState.currentUserId else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // An empty seed: `createPlaylist` passes `mediaType: .video`,
            // which is what lets Jellyfin create a playlist with no items.
            _ = try await appState.apiClient.createPlaylist(name: name, itemIds: [], userId: userId)
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
            toast.success(loc.localized("playlist.create.done", name))
        } catch {
            logger.error("Playlist create failed: \(error.localizedDescription, privacy: .public)")
            toast.error(loc.userFacingMessage(for: error))
        }
    }
}
