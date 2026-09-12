import Foundation
import JellyfinAPI

/// Whether the player should skip a media segment ON ITS OWN, and how.
///
/// The skip button is time-based and memoryless (it reappears whenever the
/// playhead is inside a segment). Auto-skip is the opposite: it acts at most
/// ONCE per segment per media, or a rewind into the intro would loop the
/// viewer straight back out of it. The "already skipped" memory lives with the
/// caller (`skippedSegmentKeys`, reset at each media open); this type only
/// reads it.
///
/// Both toggles are OPT-IN (default off, Settings → Playback): with them off
/// every input maps to `.none` and the presenters behave exactly as before.
///
/// Three refusals are load-bearing:
/// - **paused**: a paused playhead sitting in the intro is not "watching the
///   intro"; skipping under a pause would move the picture while nothing is
///   playing.
/// - **SyncPlay group**: the group owns the playhead; a local seek would go out
///   as a server Seek request and drag every participant.
/// - **unknown segment type**: only intro / outro are ever fetched, anything
///   else is left alone rather than guessed at.
///
/// An outro with autoplay armed hands off to the next episode immediately
/// (`.handOffToNext`) instead of seeking to the end and waiting for the engine
/// to report EOF — same destination, one fewer hop through the end-of-media
/// disambiguation. Without a next episode it seeks to the segment's end like
/// an intro, and the ordinary end-of-playback path takes over.
nonisolated enum AutoSkipPolicy {
    enum Action: Equatable {
        case none
        case seekToEnd
        case handOffToNext
    }

    /// The identity of a segment for the "already skipped" memory: type plus
    /// start. `MediaSegmentDto.id` is optional on the wire and two plugins can
    /// disagree on it; type + start is what the viewer experiences.
    static func key(type: MediaSegmentType?, startTicks: Int?) -> String {
        "\(type?.rawValue ?? "?")@\(startTicks ?? -1)"
    }

    static func decide(
        segmentType: MediaSegmentType?,
        autoSkipIntro: Bool,
        autoSkipCredits: Bool,
        alreadySkipped: Bool,
        isPlaying: Bool,
        inSyncPlayGroup: Bool,
        canHandOffToNext: Bool
    ) -> Action {
        guard isPlaying, !inSyncPlayGroup, !alreadySkipped else { return .none }
        switch segmentType {
        case .intro:
            return autoSkipIntro ? .seekToEnd : .none
        case .outro:
            guard autoSkipCredits else { return .none }
            return canHandOffToNext ? .handOffToNext : .seekToEnd
        default:
            return .none
        }
    }
}

/// The two toggles, read once per media open by each presenter.
///
/// Read through `object(forKey:)`, not `bool(forKey:)`: an absent key must
/// resolve to the documented default, and `bool(forKey:)` reads absent as
/// `false` — which happens to match today's default, but the pattern is what
/// `HomeRailPreferences` established and a flipped default must not turn into
/// a silent behaviour change.
nonisolated struct AutoSkipPreferences: Equatable {
    var intro: Bool
    var credits: Bool

    static let off = AutoSkipPreferences(intro: false, credits: false)

    static func current(defaults: UserDefaults = .standard) -> AutoSkipPreferences {
        AutoSkipPreferences(
            intro: defaults.object(forKey: SettingsKey.autoSkipIntro) as? Bool ?? SettingsKey.Default.autoSkipIntro,
            credits: defaults.object(forKey: SettingsKey.autoSkipCredits) as? Bool ?? SettingsKey.Default.autoSkipCredits
        )
    }
}
