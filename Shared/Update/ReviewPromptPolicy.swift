import Foundation

/// The pure decisions behind the App Store rating request.
///
/// Asked only of somebody who has actually watched something with the app —
/// ten unpaused minutes is past the trailer, the wrong episode and the
/// « does it even play? » check, and three such sessions is a habit rather
/// than a first impression. The system already caps the sheet at three
/// appearances a year; `minimumInterval` keeps our own requests well inside
/// that, so a user who dismissed one is not asked again next week. Locked by
/// `ReviewPromptTests`, the same arrangement as `AppUpdatePolicy`.
enum ReviewPromptPolicy {
    /// A session counts as engaged playback from 10 minutes watched.
    static let minimumWatchedSeconds = 600
    /// Engaged sessions before the first request.
    static let playbacksBeforePrompt = 3
    /// Never ask twice within this window even across versions (the system caps
    /// at 3 / 365 days on its own; this keeps our own calls sparse).
    static let minimumInterval: TimeInterval = 90 * 24 * 60 * 60

    static func qualifies(watchedSeconds: Int) -> Bool {
        watchedSeconds >= minimumWatchedSeconds
    }

    /// True when the request may go out now: once per app version, at least
    /// `minimumInterval` since the last request, and enough engaged sessions.
    static func shouldPrompt(
        qualifyingPlaybacks: Int,
        installedVersion: String,
        lastPromptedVersion: String?,
        lastPromptedAt: Date?,
        now: Date
    ) -> Bool {
        guard qualifyingPlaybacks >= playbacksBeforePrompt else { return false }
        guard lastPromptedVersion != installedVersion else { return false }
        guard let lastPromptedAt else { return true }
        // A clock moved backwards (timezone edit, NTP correction) counts as
        // « long ago » rather than muzzling the request until the future
        // catches up — same reading as `AppUpdatePolicy.shouldQueryStore`.
        if lastPromptedAt > now { return true }
        return now.timeIntervalSince(lastPromptedAt) >= minimumInterval
    }
}
