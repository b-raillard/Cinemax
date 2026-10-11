import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - Cover

/// A playlist's cover: up to three DISTINCT posters fanned out over a blurred
/// copy of the front one — the « pile d'affiches ». Square, like the system's
/// own playlist artwork, but it never repeats a poster: Jellyfin's 2×2 mosaic
/// draws a single film four times on a one-item playlist.
///
/// The layout itself (which posters, where) is `PlaylistCoverStack`, pure and
/// tested. Images go through `CinemaLazyImage` at `primary` / 300 / tag —
/// byte-identical to every poster card, so a cover is drawn from Nuke's cache
/// when its films were already on screen.
///
/// Built as a `Color.clear` shell with overlays (never a `ZStack` around a
/// `.fill` image), clipped, then `contentShape` — the hit-test RULE. Hidden
/// from VoiceOver: the card's title and count say what it is.
struct PlaylistCover: View {
    let content: PlaylistCoverContent
    let imageBuilder: ImageURLBuilder
    /// The context-menu preview passes 0: the system platter already rounds it.
    var cornerRadius: CGFloat = CinemaRadius.large

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    layers(side: min(proxy.size.width, proxy.size.height))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func layers(side: CGFloat) -> some View {
        switch content {
        case .loading:
            // No icon: a playlist with contents must not flash « vide » while
            // its preview is on its way.
            CinemaColor.surfaceContainerHigh
        case .empty:
            CinemaColor.surfaceContainerHigh
                .overlay {
                    Image(systemName: "music.note.list")
                        .resizable()
                        .scaledToFit()
                        .frame(width: side * 0.3, height: side * 0.3)
                        .foregroundStyle(CinemaColor.outlineVariant)
                }
        case .posters(let posters):
            ground(posters.first, side: side)
                .overlay {
                    ForEach(PlaylistCoverStack.placed(posters)) { placed in
                        poster(placed, side: side)
                    }
                }
        }
    }

    /// The front poster, blurred to fill the square, under a veil that keeps
    /// the fanned posters legible over it.
    private func ground(_ poster: PlaylistCoverPoster?, side: CGFloat) -> some View {
        Color.clear
            .overlay {
                CinemaLazyImage(url: url(for: poster), fallbackIcon: nil)
                    .blur(radius: side * 0.08, opaque: true)
            }
            .overlay { CinemaColor.surfaceContainerLowest.opacity(0.4) }
            .clipped()
    }

    private func poster(_ placed: PlaylistCoverStack.PlacedPoster, side: CGFloat) -> some View {
        let height = side * PlaylistCoverStack.posterHeightFraction
        return Color.clear
            .frame(width: height * 2 / 3, height: height)
            .overlay { CinemaLazyImage(url: url(for: placed.poster), fallbackIcon: "film") }
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
            .shadow(color: Color.black.opacity(0.35), radius: side * 0.04, x: 0, y: side * 0.02)
            .rotationEffect(.degrees(placed.slot.rotation))
            .offset(x: placed.slot.xOffset * side, y: placed.slot.yOffset * side)
    }

    private func url(for poster: PlaylistCoverPoster?) -> URL? {
        poster.map { imageBuilder.imageURL(itemId: $0.itemId, imageType: .primary, maxWidth: 300, tag: $0.tag) }
    }
}

// MARK: - Card

/// A playlist card: the cover, the name on one line, the count beneath.
///
/// The count line is ALWAYS laid out — a hidden placeholder holds its height
/// while the count is unknown, the way `PosterCard` holds its title's. Cards
/// whose count arrived and cards whose count had not used to differ by one
/// line, which is what misaligned « Vos playlists ».
struct PlaylistCard: View {
    let title: String
    let countText: String?
    let cover: PlaylistCoverContent
    let imageBuilder: ImageURLBuilder

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            PlaylistCover(content: cover, imageBuilder: imageBuilder)
                .cinemaFocus()

            Text(title)
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: "M")
                .font(CinemaFont.label(.medium))
                .lineLimit(1)
                .hidden()
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    if let countText {
                        Text(countText)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceMuted)
                            .lineLimit(1)
                    }
                }
        }
    }
}

// MARK: - Wired card

/// A playlist card as a focusable button, wired to the shared
/// `PlaylistPreviewStore` and carrying the playlist's management menu.
///
/// The preview is asked for from the card's own `.task(id:)`: the cards live
/// in a `LazyHStack` / `LazyVGrid`, so only the playlists actually drawn are
/// fetched. The task is keyed on the store's `generation`, so a change
/// anywhere (`.cinemaxPlaylistsChanged`) re-asks once per card on screen while
/// the cover keeps what it shows.
///
/// The menu sits on the `Button` — the focusable view — never on its label
/// (tvOS focus). Rename / Delete only when the server says the user may
/// delete it (`canDelete`: owner or administrator); its strings are resolved
/// HERE and captured, since a `contextMenu`'s content receives no injected
/// `@Observable` (see `docs/rules/playlists.md`).
struct PlaylistCardButton: View {
    let playlist: BaseItemDto
    let onOpen: () -> Void
    /// Raised by the menu; the screen's `.playlistManagement` host acts on it.
    let onManage: (PlaylistManagementRequest) -> Void

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc

    private var store: PlaylistPreviewStore { .shared }

    var body: some View {
        let preview = playlist.id.flatMap { store.preview(for: $0) }
        let cover = PlaylistCoverStack.content(preview: preview, fallbackCount: playlist.childCount)
        let count = preview?.totalCount ?? playlist.childCount
        let title = Self.displayName(playlist.name, untitled: loc.localized("playlist.untitled"))

        Button(action: onOpen) {
            PlaylistCard(
                title: title,
                countText: count.map { loc.itemCount($0) },
                cover: cover,
                imageBuilder: appState.imageBuilder
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .playlistCardContextMenu(
            canManage: playlist.canDelete == true && playlist.id != nil,
            labels: PlaylistMenuLabels(
                rename: loc.localized("playlist.rename"),
                delete: loc.localized("playlist.delete")
            ),
            preview: PlaylistCover(content: cover, imageBuilder: appState.imageBuilder, cornerRadius: 0),
            onRename: {
                if let id = playlist.id { onManage(.rename(id: id, name: playlist.name ?? "")) }
            },
            onDelete: {
                if let id = playlist.id { onManage(.delete(id: id, name: title)) }
            }
        )
        .task(id: PreviewRequest(playlistId: playlist.id, userId: appState.currentUserId, generation: store.generation)) {
            guard let id = playlist.id, let userId = appState.currentUserId else { return }
            store.load(playlistId: id, userId: userId, api: appState.apiClient)
        }
    }

    /// A playlist's name, or « Playlist sans nom » for a blank one.
    static func displayName(_ name: String?, untitled: String) -> String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return untitled }
        return name
    }

    private struct PreviewRequest: Hashable {
        let playlistId: String?
        let userId: String?
        let generation: Int
    }
}
