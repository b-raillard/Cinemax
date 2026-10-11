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
