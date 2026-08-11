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
        // Deliberately NOT defaulted, unlike every other parameter here. The
        // others default to "feature off", so omitting one loses an entry and
        // nothing more. Omitting this one would be silently WRONG on a wide
        // card — it would lift a portrait poster instead of the backdrop the
        // finger is on. Required, so a future wide-card surface gets a compile
        // error instead of a mismatched preview.
        artwork: CardArtwork,
        navigation: CardPlaybackNavigation? = nil,
        onRemoveFromResume: (() -> Void)? = nil,
        onGoToSeries: ((String) -> Void)? = nil
    ) -> some View {
        modifier(MediaCardContextMenu(
            item: CardMenuItem(item), artwork: artwork, navigation: navigation,
            onRemoveFromResume: onRemoveFromResume, onGoToSeries: onGoToSeries
        ))
    }
}

/// Which image the iOS long-press preview lifts — the card's OWN artwork, so
/// the preview reads as the card growing rather than as a different object.
///
/// The modifier can't infer this: `.movie` and `.series` items appear both as
/// portrait posters (library, search, Home's Recently Added) and as landscape
/// wide cards (Home's Continue Watching and Next Up), so the shape is a
/// property of the call site, not of the item.
enum CardArtwork {
    /// `.primary`, 2:3 — every `PosterCard` / `LibraryPosterCard` surface.
    case poster
    /// `.backdrop`, 16:9 — the two `WideCard` rails on Home.
    case backdrop
}

/// Destination token for "Go to series". Declared here, alongside the
/// callback that produces its id, because all three host screens (Home,
/// Search, Watched History) consume it.
struct SeriesDestination: Identifiable, Hashable {
    let id: String
}

extension View {
    /// Hosts the "Go to series" destination. Each host screen owned a
    /// byte-identical copy of this three-line body; the token type is already
    /// shared, so the wiring around it had no reason not to be.
    ///
    /// **Apply this OUTSIDE every lazy container** — SwiftUI silently ignores
    /// `navigationDestination(item:)` inside a `LazyVGrid`/`LazyHStack`, and the
    /// menu entry then does nothing with no error anywhere.
    func seriesDestinationHost(_ destination: Binding<SeriesDestination?>) -> some View {
        navigationDestination(item: destination) { series in
            MediaDetailScreen(itemId: series.id, itemType: .series)
        }
    }
}

/// The scalars the menu and its preview actually read off a card's item.
///
/// Extracted once per card, deliberately: every escaping `Button` action closure
/// in the menu captures the enclosing value, and when that value held a
/// `BaseItemDto` — the SDK's widest model, with dozens of reference-counted
/// members — each of the ~7 closures meant a DTO copy and its retain traffic,
/// per card, on a grid where nobody had opened a menu. Same ids-and-scalars
/// discipline as `CardPlayTargetResolver`.
private struct CardMenuItem {
    let id: String?
    let type: BaseItemKind?
    let name: String?
    let seriesId: String?
    let isPlayed: Bool
    let isFavorite: Bool
    let positionTicks: Int
    let primaryImageTag: String?
    let backdropItemId: String?
    let backdropImageTag: String?

    init(_ item: BaseItemDto) {
        id = item.id
        type = item.type
        name = item.name
        seriesId = item.seriesID
        isPlayed = item.userData?.isPlayed ?? false
        isFavorite = item.userData?.isFavorite ?? false
        positionTicks = item.userData?.playbackPositionTicks ?? 0
        primaryImageTag = item.primaryImageTagValue
        backdropItemId = item.backdropItemID
        backdropImageTag = item.backdropImageTagValue
    }
}

/// An optimistic toggle result, paired with the server value it was derived
/// from.
///
/// Storing the base is what keeps the override from *shadowing* fresh server
/// data: nothing ever reset these mirrors, and `@State` outlives a grid reload
/// (same ids ⇒ same view identity), so toggling watched here and then unwatched
/// from the detail screen left the menu offering "Remove from watched" on an
/// unwatched item — and acting on it issued a redundant write plus a redundant
/// notification fan-out.
private struct OptimisticFlag {
    let base: Bool
    let value: Bool

    /// The override, or `nil` once the server value it was derived from has
    /// moved on — in which case the caller falls back to server truth.
    func resolved(against serverValue: Bool) -> Bool? {
        base == serverValue ? value : nil
    }
}

private struct MediaCardContextMenu: ViewModifier {
    // Read HERE, in the attached view's own hierarchy, and forwarded onto the
    // menu/preview below. SwiftUI hosts `contextMenu` content in a separate
    // presentation context that does NOT carry these injected `@Observable`
    // objects, so a child `View` reading them itself resolves nothing and a
    // non-optional read traps ("No Observable object of type AppState found").
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast
    @Environment(AddToPlaylistPresenter.self) private var playlists: AddToPlaylistPresenter?
    @Environment(CardActionPresenter.self) private var cardActions: CardActionPresenter?
    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator: VideoPlayerCoordinator?
    #endif

    let item: CardMenuItem
    let artwork: CardArtwork
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
    // reload. `@State` is per-card-identity, so it never leaks across items;
    // it lives here rather than in `CardMenuContent` so it survives the menu
    // being dismissed and re-opened.
    @State private var playedOverride: OptimisticFlag?
    @State private var favoriteOverride: OptimisticFlag?

    /// **Both closures below must stay cheap to CONSTRUCT.** `contextMenu`'s
    /// builders are non-escaping, so SwiftUI invokes them synchronously for
    /// every card the lazy container instantiates — it cannot defer them. What
    /// it *does* defer is a child view's `body`, which is why the menu and the
    /// preview are `View` types rather than `@ViewBuilder` properties here: the
    /// localized lookups, the `imageURL` build and the `knownRemoteTargetCount`
    /// read all moved into their `body`, i.e. onto the long-press, instead of
    /// being paid ~48× per tvOS grid fill for a menu nobody opened.
    func body(content: Content) -> some View {
        #if os(iOS)
        // An explicit preview lifts the ARTWORK ALONE. The default one lifts the
        // whole attached view, and on a `PosterCard` that view is the poster
        // *plus* its title and subtitle — text with no background of its own,
        // which ends up floating over the next row's header. `LibraryPosterCard`
        // never showed the bug because its link wraps only the poster; this makes
        // every surface behave the way that one already did.
        content.contextMenu {
            forwardingEnvironment(menuContent)
        } preview: {
            forwardingEnvironment(CardArtworkPreview(item: item, artwork: artwork))
        }
        #else
        // tvOS has no `preview:` overload, and no lift to correct.
        content.contextMenu { forwardingEnvironment(menuContent) }
        #endif
    }

    /// Re-injects the objects the menu's own presentation context drops.
    private func forwardingEnvironment(_ view: some View) -> some View {
        view
            .environment(appState)
            .environment(loc)
            .environment(toast)
            .environment(playlists)
            .environment(cardActions)
        #if os(tvOS)
            .environment(coordinator)
        #endif
    }

    private var menuContent: CardMenuContent {
        CardMenuContent(
            item: item, navigation: navigation,
            onRemoveFromResume: onRemoveFromResume, onGoToSeries: onGoToSeries,
            playedOverride: $playedOverride, favoriteOverride: $favoriteOverride
        )
    }
}

/// The menu's entries. A `View` rather than a `@ViewBuilder` property on the
/// modifier so SwiftUI evaluates all of this on long-press — see the note on
/// `MediaCardContextMenu.body(content:)`.
private struct CardMenuContent: View {
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

    let item: CardMenuItem
    let navigation: CardPlaybackNavigation?
    let onRemoveFromResume: (() -> Void)?
    let onGoToSeries: ((String) -> Void)?
    @Binding var playedOverride: OptimisticFlag?
    @Binding var favoriteOverride: OptimisticFlag?

    @ViewBuilder
    var body: some View {
        let isPlayed = playedOverride?.resolved(against: item.isPlayed) ?? item.isPlayed
        let isFavorite = favoriteOverride?.resolved(against: item.isFavorite) ?? item.isFavorite
        let isPlayable = item.type == .movie || item.type == .series || item.type == .episode
        // Only computed for the types whose card carries the useful userData —
        // a series card doesn't know its next-up episode's, so its label stays
        // "Play" and "Play from beginning" doesn't show.
        let localResume: Bool = {
            guard item.type == .movie || item.type == .episode else { return false }
            return CardPlayTargetResolver.isResumable(
                positionTicks: item.positionTicks,
                isPlayed: item.isPlayed
            )
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

        Group {
            if isPlayable {
                if canPlayLocally {
                    Button {
                        Task { await startPlayback(fromStart: false) }
                    } label: {
                        Label(
                            // `detail.*` rather than a card-scoped twin: these are
                            // the same two labels the detail screen's Play buttons
                            // use, word for word. A second key would be a second
                            // translation to keep in sync for no gain.
                            loc.localized(localResume ? "card.resume" : "detail.play"),
                            systemImage: "play.fill"
                        )
                    }
                    if localResume {
                        Button {
                            Task { await startPlayback(fromStart: true) }
                        } label: {
                            Label(loc.localized("detail.playFromBeginning"), systemImage: "gobackward")
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
            if let onGoToSeries, item.type == .episode, let seriesId = item.seriesId {
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
            if let onRemoveFromResume, item.positionTicks > 0 {
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
            // Never a bare `Int(seconds * 10_000_000)`: that conversion TRAPS on
            // non-finite or overflowing input, which is exactly why
            // `PlaybackReporter` owns a guarded version of it.
            startPositionTicks: target.startSeconds.map { PlaybackReporter.positionTicks(fromSeconds: $0) },
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

        // `CardMenuItem` is already scalars-only, which is what lets this hand
        // straight to a `nonisolated` resolver — the extraction that used to
        // happen here (because `BaseItemDto` is not Sendable) now happens once
        // per card at the modifier's entry point instead of once per call.
        return await CardPlayTargetResolver.resolve(
            itemId: id, type: item.type, title: item.name ?? "",
            positionTicks: item.positionTicks, isPlayed: item.isPlayed,
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
            playedOverride = OptimisticFlag(base: item.isPlayed, value: !isPlayed)
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
            favoriteOverride = OptimisticFlag(base: item.isFavorite, value: !isFavorite)
            toast.success(loc.localized(isFavorite ? "card.unfavorited" : "card.favorited"))
            NotificationCenter.default.post(name: .cinemaxFavoritesChanged, object: nil)
        } catch {
            logger.error("Card favorite toggle failed: \(error.localizedDescription, privacy: .public)")
            toast.error(loc.userFacingMessage(for: error))
        }
    }
}

#if os(iOS)
/// The lifted artwork, and nothing else.
///
/// A `View` rather than a `@ViewBuilder` property on the modifier so the URL is
/// built on long-press instead of once per card during a grid fill — see the
/// note on `MediaCardContextMenu.body(content:)`.
///
/// **The URL must be byte-identical to the one the card itself requested**
/// — same `maxWidth`, same `tag`. Nuke keys its cache on the URL, so a
/// near-miss doesn't reuse the image the card already decoded: it starts a
/// fresh download and the preview appears blank for a beat. Every poster
/// surface requests `.primary` at 300 with `primaryImageTagValue`, and both
/// wide rails request `.backdrop` at 600 with `backdropImageTagValue` off
/// `backdropItemID`, so these two branches cover all nine call sites
/// exactly. Same discipline as `PosterPrefetcher`.
private struct CardArtworkPreview: View {
    @Environment(AppState.self) private var appState

    let item: CardMenuItem
    let artwork: CardArtwork

    var body: some View {
        switch artwork {
        case .poster:
            previewArtwork(
                url: item.id.map {
                    appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTag)
                },
                width: Self.previewPosterWidth,
                height: Self.previewPosterWidth * 3 / 2
            )
        case .backdrop:
            previewArtwork(
                url: item.backdropItemId.map {
                    appState.imageBuilder.imageURL(itemId: $0, imageType: .backdrop, maxWidth: 600, tag: item.backdropImageTag)
                },
                width: Self.previewBackdropWidth,
                height: Self.previewBackdropWidth * 9 / 16
            )
        }
    }

    /// No `clipShape` here on purpose — the system platter already rounds the
    /// preview, and a second corner radius inside it reads as a double border.
    private func previewArtwork(url: URL?, width: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .background(CinemaColor.surfaceContainerLow)
            .overlay { CinemaLazyImage(url: url, fallbackIcon: "film") }
            .clipped()
    }

    private static let previewPosterWidth: CGFloat = 220
    private static let previewBackdropWidth: CGFloat = 320
}
#endif
