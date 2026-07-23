import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "MediaCardContextMenu")

/// Shared long-press (iOS) / long-press-select (tvOS) context menu for poster
/// cards on the library and search grids. Mirrors the proven Home
/// continue-watching pattern (`HomeScreen.continueWatchingPlayLink`): the menu
/// is attached to the card's focusable `Button`/`NavigationLink` — never its
/// label — so tvOS focus behavior is untouched.
///
/// Actions read the item's current played / favorite state from `userData`,
/// call the matching API, toast the result, and post
/// `.cinemaxShouldRefreshCatalogue` / `.cinemaxFavoritesChanged` so the owning
/// grid (and Home) reload from server truth. A failure surfaces a user-facing
/// error toast (`userFacingMessage(for:)`) and leaves server state untouched.
extension View {
    func mediaCardContextMenu(item: BaseItemDto) -> some View {
        modifier(MediaCardContextMenu(item: item))
    }
}

private struct MediaCardContextMenu: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast

    let item: BaseItemDto

    // Optimistic mirrors of the toggle state. The menu label is derived from
    // the item's `userData`, but that value is a snapshot captured when the
    // owning grid built the card — and the library browse grid does NOT reload
    // its genre-row cards on `.cinemaxFavoritesChanged`, so without these the
    // menu re-opens showing a stale "add to favorites" after the item was
    // already favorited. Each toggle updates its mirror so the label reflects
    // the action immediately, with no extra server round-trip / catalogue
    // reload. `@State` is per-card-identity, so it never leaks across items.
    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?

    func body(content: Content) -> some View {
        let isPlayed = playedOverride ?? item.userData?.isPlayed ?? false
        let isFavorite = favoriteOverride ?? item.userData?.isFavorite ?? false

        content.contextMenu {
            Button {
                Task { await toggleWatched(isPlayed: isPlayed) }
            } label: {
                Label(
                    loc.localized(isPlayed ? "detail.watched.remove" : "detail.watched.add"),
                    systemImage: isPlayed ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            Button {
                Task { await toggleFavorite(isFavorite: isFavorite) }
            } label: {
                Label(
                    loc.localized(isFavorite ? "detail.favorite.remove" : "detail.favorite.add"),
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
            }
        }
    }

    private func toggleWatched(isPlayed: Bool) async {
        guard let userId = appState.currentUserId, let id = item.id else { return }
        do {
            if isPlayed {
                try await appState.apiClient.markItemUnplayed(itemId: id, userId: userId)
            } else {
                try await appState.apiClient.markItemPlayed(itemId: id, userId: userId)
            }
            playedOverride = !isPlayed
            toast.success(loc.localized(isPlayed ? "card.markedUnwatched" : "card.markedWatched"))
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
        } catch {
            logger.error("Card watched toggle failed: \(error.localizedDescription, privacy: .public)")
            toast.error(loc.userFacingMessage(for: error))
        }
    }

    private func toggleFavorite(isFavorite: Bool) async {
        guard let userId = appState.currentUserId, let id = item.id else { return }
        do {
            try await appState.apiClient.setFavorite(itemId: id, userId: userId, favorite: !isFavorite)
            favoriteOverride = !isFavorite
            toast.success(loc.localized(isFavorite ? "card.unfavorited" : "card.favorited"))
            NotificationCenter.default.post(name: .cinemaxFavoritesChanged, object: nil)
        } catch {
            logger.error("Card favorite toggle failed: \(error.localizedDescription, privacy: .public)")
            toast.error(loc.userFacingMessage(for: error))
        }
    }
}
