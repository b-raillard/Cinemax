import Foundation

/// VoiceOver strings for the VLC player's UIKit HUD.
///
/// Built once per player from a `localize` closure — the presenter passes
/// `loc.localized`, the tests an explicit fr / en bundle — so the labels can be
/// asserted non-empty and localized without a live engine, and without writing
/// the app-wide language setting a parallel test might read.
///
/// **Every icon-only HUD control reads its label from here.** Two were wrong
/// before this existed: the iOS ±10 s buttons announced « Passer l'intro » /
/// « Passer le générique » (they borrowed the skip-SEGMENT keys, a different
/// control), and play/pause carried no label at all.
struct PlayerHUDAccessibility {
    let skipBack: String
    let skipForward: String
    let play: String
    let pause: String
    let loading: String
    let scrubBar: String
    let previousEpisode: String
    let nextEpisode: String
    let audio: String
    let subtitles: String
    let speed: String
    let pictureInPicture: String
    let stats: String
    let close: String
    private let positionFormat: String

    init(localize: (String) -> String) {
        skipBack = String(format: localize("player.a11y.skipBack"), PlayerSkipConfig.intervalSeconds)
        skipForward = String(format: localize("player.a11y.skipForward"), PlayerSkipConfig.intervalSeconds)
        play = localize("player.a11y.play")
        pause = localize("player.a11y.pause")
        loading = localize("player.a11y.loading")
        scrubBar = localize("player.scrubBar")
        previousEpisode = localize("player.previousEpisode")
        nextEpisode = localize("player.nextEpisode")
        audio = localize("player.audio")
        subtitles = localize("player.subtitles")
        speed = localize("player.speed")
        pictureInPicture = localize("player.pip")
        stats = localize("player.stats")
        close = localize("action.done")
        positionFormat = localize("player.a11y.position")
    }

    /// Every control label — what `PlayerAccessibilityTests` walks.
    var controlLabels: [String] {
        [skipBack, skipForward, play, pause, loading, scrubBar, previousEpisode,
         nextEpisode, audio, subtitles, speed, pictureInPicture, stats, close]
    }

    /// The scrub control's VoiceOver value — « 12 minutes et 4 secondes sur
    /// 1 heure et 45 minutes ». `total` is `nil` while the runtime is unknown.
    func position(elapsed: String, total: String?) -> String {
        guard let total else { return elapsed }
        return String(format: positionFormat, elapsed, total)
    }
}

/// Which chapter the playhead is in — drives the `.selected` trait on the
/// chapter strip, so VoiceOver can say where in the film the viewer is, the
/// way the option panel's rows already say which track is playing.
enum PlayerChapterSelection {
    /// Index of the last chapter starting at or before `positionTicks`, `nil`
    /// when there are no chapters. A position before the first start counts as
    /// the first chapter (a film whose chapter 1 begins a few seconds in).
    static func currentIndex(startTicks: [Int], positionTicks: Int) -> Int? {
        guard !startTicks.isEmpty else { return nil }
        return startTicks.lastIndex(where: { $0 <= positionTicks }) ?? 0
    }
}
