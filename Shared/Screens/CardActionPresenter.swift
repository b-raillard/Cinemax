import SwiftUI
import CinemaxKit

/// What a playback launched from a poster card needs to carry — exactly the
/// arguments `VideoPlayerView` takes. No `mediaSourceId`: version selection is
/// a detail-screen decision (its "Version" row), a card carries no such
/// choice.
struct CardPlaybackRequest: Identifiable {
    let id = UUID()
    let itemId: String
    let title: String
    let startTime: Double?
    let previousEpisode: EpisodeRef?
    let nextEpisode: EpisodeRef?
    let episodeNavigator: EpisodeNavigator?
}

/// The prev / next / navigator trio `PlayLink` already takes, grouped so the
/// menu modifier doesn't have to thread three separate parameters. Home's
/// rails carry it (`resumeNavigation` / `nextUpNavigation`); everywhere else
/// it's `nil` and the player shows no episode-nav buttons — the same
/// degradation already in effect for rails that omit them.
struct CardPlaybackNavigation {
    let previous: EpisodeRef?
    let next: EpisodeRef?
    let navigator: EpisodeNavigator?
}

/// Carries requests a context menu can't present by itself.
///
/// A `contextMenu` hangs off a card living inside a `LazyVGrid` / `LazyHStack`:
/// SwiftUI silently ignores `navigationDestination(item:)` there, and a
/// presentation attached to a lazy child dies with the recycled cell. Same
/// reason and same shape as `AddToPlaylistPresenter` — a minimal model, hosted
/// once on `AppNavigation`.
///
/// **iOS only for `playback`**: on tvOS the menu calls `VideoPlayerCoordinator`
/// directly, which is already a root presenter.
@MainActor
@Observable
final class CardActionPresenter {
    var playback: CardPlaybackRequest?
    var remotePlay: RemotePlayIntent?
    /// Target count known from the last real poll, `nil` until one has
    /// happened. No speculative poll is triggered here.
    var knownRemoteTargetCount: Int?

    func present(playback request: CardPlaybackRequest) {
        playback = request
    }

    func present(remotePlay intent: RemotePlayIntent) {
        remotePlay = intent
    }
}

#if os(iOS)
/// Hosts the player at the root. `VideoPlayerView` is only a loading shell:
/// the real player is presented on top via a UIKit modal, and dismissing it
/// calls `dismiss()` — which closes this cover just as it would pop a push.
/// Environment objects are re-injected, same as `AddToPlaylistPresentation`.
struct CardPlaybackPresentation: ViewModifier {
    @Binding var request: CardPlaybackRequest?
    let appState: AppState
    let themeManager: ThemeManager
    let loc: LocalizationManager
    let toast: ToastCenter

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $request) { request in
            VideoPlayerView(
                itemId: request.itemId,
                title: request.title,
                startTime: request.startTime,
                previousEpisode: request.previousEpisode,
                nextEpisode: request.nextEpisode,
                episodeNavigator: request.episodeNavigator
            )
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toast)
        }
    }
}
#endif
