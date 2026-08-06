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
        navigation: CardPlaybackNavigation? = nil,
        onRemoveFromResume: (() -> Void)? = nil,
        onGoToSeries: ((String) -> Void)? = nil
    ) -> some View {
        modifier(MediaCardContextMenu(
            item: item, navigation: navigation,
            onRemoveFromResume: onRemoveFromResume, onGoToSeries: onGoToSeries
        ))
    }
}

/// Destination token for "Go to series". Declared here, alongside the
/// callback that produces its id, because all three host screens (Home,
/// Search, Watched History) consume it.
struct SeriesDestination: Identifiable, Hashable {
    let id: String
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
    let onRemoveFromResume: (() -> Void)?
    let onGoToSeries: ((String) -> Void)?

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
        // Same presence discipline as the "Play on…" entry below, applied to
        // the LOCAL play entries too: `startPlayback` calls `coordinator?.play`
        // on tvOS and `cardActions?.present` on iOS (see the platform split
        // there), so an absent presenter on either platform must hide the
        // button rather than render a silent no-op — the file's own design
        // promise is that a dead button is not possible.
        #if os(tvOS)
        let canPlayLocally = coordinator != nil
        #else
        let canPlayLocally = cardActions != nil
        #endif

        content.contextMenu {
            if isPlayable {
                if canPlayLocally {
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
                }
                // Cold cache ⇒ show the entry (optimistic). That's what avoids a
                // permanently dead entry for someone with no Apple TV without
                // adding a probe on every menu open — a `contextMenu` builds
                // synchronously and can't await one. The sheet re-probes on
                // open and already has its own empty state (`remote.noTargets.*`).
                if let cardActions, (cardActions.knownRemoteTargetCount ?? 1) > 0 {
                    Button {
                        Task { await startRemotePlay() }
                    } label: {
                        Label(loc.localized("remote.title"), systemImage: "tv.badge.wifi")
                    }
                }
                Divider()
            }
            // The callback is supplied only by the screens that host the
            // destination outside their lazy container (SwiftUI would
            // silently ignore `navigationDestination` there) — same contract
            // as `AdminItemMenu.onSelectDestination`. Its presence is what
            // makes the entry appear, so a dead button is not possible.
            if let onGoToSeries, item.type == .episode, let seriesId = item.seriesID {
                Button {
                    onGoToSeries(seriesId)
                } label: {
                    Label(loc.localized("card.goToSeries"), systemImage: "rectangle.stack")
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
            // The presence of the callback proves the host screen knows how to
            // drop the card from its own row — only Home's Continue Watching
            // rail provides it. The resume position is the business condition:
            // without one, the item isn't in that row.
            if let onRemoveFromResume, (item.userData?.playbackPositionTicks ?? 0) > 0 {
                Divider()
                Button(role: .destructive) {
                    onRemoveFromResume()
                } label: {
                    Label(loc.localized("home.continueWatching.remove"), systemImage: "minus.circle")
                }
            }
        }
    }

    /// Starts playback. tvOS goes through `VideoPlayerCoordinator` (already a
    /// root presenter, exactly what `PlayLink` does); iOS goes through the
    /// `fullScreenCover` hosted by `AppNavigation`, because a menu button
    /// inside a lazy container can't push a `NavigationLink`.
    private func startPlayback(fromStart: Bool) async {
        guard let target = await resolvedCardPlayTarget() else { return }
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

    /// Sends to another session what "Play" would have started here, going
    /// through the same resolver — so a series sends its next-up episode and a
    /// half-watched movie resumes where it left off.
    private func startRemotePlay() async {
        guard let target = await resolvedCardPlayTarget() else { return }
        cardActions?.present(remotePlay: RemotePlayIntent(
            itemId: target.itemId,
            title: target.title,
            startPositionTicks: target.startSeconds.map { Int($0 * 10_000_000) },
            // A card carries no version choice — that's the detail screen's
            // "Version" row's decision.
            mediaSourceId: nil
        ))
    }

    /// Shared by `startPlayback` and `startRemotePlay`: resolves what either
    /// "play locally" or "play on…" should open for the item on this card,
    /// via the same resolver so both stay in lockstep with a series' next-up
    /// episode / a movie's resume position. `nil` when there's no signed-in
    /// user or the item carries no id — both callers no-op in that case.
    private func resolvedCardPlayTarget() async -> CardPlayTarget? {
        guard let userId = appState.currentUserId, let id = item.id else { return nil }

        // Scalars extracted here, on the main actor: `resolve` is nonisolated
        // and `BaseItemDto` is not Sendable.
        let type = item.type
        let title = item.name ?? ""
        let ticks = item.userData?.playbackPositionTicks ?? 0
        let played = item.userData?.isPlayed ?? false

        return await CardPlayTargetResolver.resolve(
            itemId: id, type: type, title: title,
            positionTicks: ticks, isPlayed: played,
            api: appState.apiClient, userId: userId
        )
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
