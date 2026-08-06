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
/// call the matching API, toast the result, and post the tier-2
/// `.cinemaxItemUserDataChanged` (watched) / `.cinemaxFavoritesChanged`
/// (favorite) so the owning grid (and Home) reflect server truth without a
/// catalogue-wide fan-out. A failure surfaces a user-facing error toast
/// (`userFacingMessage(for:)`) and leaves server state untouched.
extension View {
    func mediaCardContextMenu(
        item: BaseItemDto,
        navigation: CardPlaybackNavigation? = nil
    ) -> some View {
        modifier(MediaCardContextMenu(item: item, navigation: navigation))
    }
}

private struct MediaCardContextMenu: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast
    /// Optional on purpose. `@Environment(Type.self)` for an `@Observable`
    /// **traps at runtime** when the value is absent, and this menu is attached
    /// to cards that also live inside modally-presented hosts, which have to
    /// re-inject the environment by hand (see `WatchedHistoryScreen`'s sheet
    /// builder — the same reason `ToastCenter` is re-injected there). An
    /// optional read degrades a forgotten injection into a missing menu entry
    /// instead of a crash.
    @Environment(AddToPlaylistPresenter.self) private var playlists: AddToPlaylistPresenter?
    /// Same optionality rationale as `playlists` above.
    @Environment(CardActionPresenter.self) private var cardActions: CardActionPresenter?
    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator: VideoPlayerCoordinator?
    #endif

    let item: BaseItemDto
    let navigation: CardPlaybackNavigation?

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
        let isPlayable = item.type == .movie || item.type == .series || item.type == .episode
        // Only computed for the types whose card carries the useful userData —
        // a series card doesn't know its next-up episode's, so its label stays
        // "Play" and "Play from beginning" doesn't show.
        let localResume: Bool = {
            guard item.type == .movie || item.type == .episode else { return false }
            guard let ticks = item.userData?.playbackPositionTicks, ticks > 0 else { return false }
            return !(item.userData?.isPlayed ?? false)
        }()

        content.contextMenu {
            if isPlayable {
                Button {
                    Task { await startPlayback(fromStart: false) }
                } label: {
                    Label(
                        loc.localized(localResume ? "card.resume" : "card.play"),
                        systemImage: "play.fill"
                    )
                }
                if localResume {
                    Button {
                        Task { await startPlayback(fromStart: true) }
                    } label: {
                        Label(loc.localized("card.playFromStart"), systemImage: "gobackward")
                    }
                }
                Divider()
            }
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
            // Raises the root-hosted sheet rather than presenting one here: this
            // menu hangs off cards inside `LazyVGrid`s, and a presentation
            // attached to a lazy child dies with the recycled cell.
            if let playlists {
                Button {
                    playlists.present(itemId: item.id, title: item.name)
                } label: {
                    Label(loc.localized("playlist.add.action"), systemImage: "text.badge.plus")
                }
            }
        }
    }

    /// Starts playback. tvOS goes through `VideoPlayerCoordinator` (already a
    /// root presenter, exactly what `PlayLink` does); iOS goes through the
    /// `fullScreenCover` hosted by `AppNavigation`, because a menu button
    /// inside a lazy container can't push a `NavigationLink`.
    private func startPlayback(fromStart: Bool) async {
        guard let userId = appState.currentUserId, let id = item.id else { return }

        // Scalars extracted here, on the main actor: `resolve` is nonisolated
        // and `BaseItemDto` is not Sendable.
        let type = item.type
        let title = item.name ?? ""
        let ticks = item.userData?.playbackPositionTicks ?? 0
        let played = item.userData?.isPlayed ?? false

        let target = await CardPlayTargetResolver.resolve(
            itemId: id, type: type, title: title,
            positionTicks: ticks, isPlayed: played,
            api: appState.apiClient, userId: userId
        )
        let startTime = fromStart ? nil : target.startSeconds

        #if os(tvOS)
        coordinator?.play(
            itemId: target.itemId, title: target.title, startTime: startTime,
            previousEpisode: navigation?.previous, nextEpisode: navigation?.next,
            episodeNavigator: navigation?.navigator,
            using: appState
        )
        #else
        cardActions?.present(playback: CardPlaybackRequest(
            itemId: target.itemId, title: target.title, startTime: startTime,
            previousEpisode: navigation?.previous, nextEpisode: navigation?.next,
            episodeNavigator: navigation?.navigator
        ))
        #endif
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
            NotificationCenter.default.post(name: .cinemaxItemUserDataChanged, object: nil)
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
