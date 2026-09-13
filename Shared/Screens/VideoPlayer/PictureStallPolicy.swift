import Foundation

/// Decides whether the VIDEO DECODER has wedged in the middle of a playback
/// that every other signal still calls healthy.
///
/// **The state this exists for is invisible to every other guard in the
/// player.** Measured on an Apple TV on 2026-09-13 (« La Pat' Patrouille : Le
/// film mission Dino », a 4K HDR10+ HEVC MKV in DirectPlay): the picture froze
/// twice, ~35 min in and ~8 min after resuming, and *nothing* in the app
/// reacted — because from the app's point of view nothing was wrong. libVLC
/// stayed `.playing`, so the loading spinner never showed (it is armed by
/// `.opening` / `.buffering`); the clock kept advancing, so `PlaybackReporter`
/// went on reporting a position that climbed — the user watched it climb from
/// his phone while the television was frozen; no `.stopped` was ever emitted,
/// so `PlaybackEndPolicy` had nothing to judge; and the open watchdog covers
/// the OPEN phase only, which had long since succeeded. A ±10 s seek did not
/// recover it, which is the tell: a seek re-anchors the demuxer, it does not
/// rebuild the decoder.
///
/// So the detector cannot key on time, on state, or on errors — it has to key
/// on the one fact that actually stopped: **libVLC's `displayedPictures`
/// counter**, which the stats HUD already reads and nothing else consults.
///
/// **RULE — the clock MUST be advancing for this to fire.** "Frames frozen AND
/// clock frozen" is somebody else's case in every instance: paused (no state
/// change), buffering (the spinner owns it, and libVLC reports `.buffering`),
/// end of media (`PlaybackEndPolicy`), a dead input (the same). Firing there
/// would put a costly re-negotiation on top of a path that already has an
/// owner. The signature this type recognises is precisely the contradictory
/// one — *the clock says we are playing and the picture says we are not* — and
/// that pair is never legitimate.
///
/// Recovery is `reResolveAndResume`, the wake path: it re-negotiates
/// `PlaybackInfo`, hands the previous server session back and rebuilds the
/// player from scratch at the current position. Rebuilding is the point — it is
/// the only thing that gives the wedged decoder a new one, which is exactly
/// what the user's ±10 s seek could not do.
///
/// It is a NET, not a cure: it restores playback without knowing why
/// videotoolbox stopped. That is why every fire logs the counters and the
/// selected module chain (`VLCEngineFacts`), so a recurrence is diagnosable
/// from a log instead of needing to be reproduced on demand.
struct PictureStallPolicy {

    /// Consecutive seconds of "clock moving, no new picture" before recovering.
    /// Long enough that a hiccup never costs a re-negotiation, short enough
    /// that the viewer has not yet reached for the remote.
    static let stallSeconds = 8

    /// How many times ONE playback may rebuild itself. Bounded for the same
    /// reason `didRetry` is: a file or a decoder that wedges immediately every
    /// time must surface as a problem, not as a silent loop of re-negotiations
    /// against the server.
    static let recoveryBudget = 2

    /// Seconds of healthy frames that renew the budget. Same discipline as
    /// `noteMediaOpened` renewing `didRetry`: a long playback that hiccups once
    /// an hour recovers every time, while a wedge-immediately loop depletes it.
    static let budgetRenewSeconds = 60

    enum Outcome: Equatable {
        case healthy
        /// Stalling for this many consecutive seconds, with no recovery spent —
        /// either below the threshold, or the budget is exhausted. The caller
        /// logs the single sample where `seconds == stallSeconds`.
        case stalling(seconds: Int)
        /// Rebuild the player at the current position.
        case recover
    }

    private var lastPictures: UInt64?
    private var lastPositionMs: Int32?
    private var stalledSeconds = 0
    private var healthySeconds = 0
    private(set) var recoveriesLeft = PictureStallPolicy.recoveryBudget

    init() {}

    /// Called at every fresh open (`beginOpenLoading`). Clears the sampling
    /// window — the counters describe a stream that no longer exists — and
    /// deliberately **does NOT restore the budget**.
    ///
    /// **RULE — the budget must survive a reopen, because the recovery IS a
    /// reopen.** `reResolveAndResume` goes through `beginOpenLoading`, so a
    /// reset that restored the budget here would hand every recovery a fresh
    /// allowance and turn the bound into no bound at all: a decoder that wedges
    /// again immediately would re-negotiate against the server for ever, which
    /// is precisely the silent loop `didRetry` was tightened to prevent on the
    /// open path. The only thing that gives the budget back is
    /// `budgetRenewSeconds` of healthy frames — i.e. proof that the recovery
    /// actually worked.
    mutating func resetWindow() {
        lastPictures = nil
        lastPositionMs = nil
        stalledSeconds = 0
        healthySeconds = 0
    }

    /// One sample per second, from the player's existing 1 s heartbeat.
    ///
    /// - Parameters:
    ///   - displayedPictures: libVLC's own count of pictures sent to the vout.
    ///     `nil` (no statistics yet) is treated as "cannot tell", never as a stall.
    ///   - positionMs: the playhead the app would report right now.
    ///   - isPlaying: the engine's state is `.playing`.
    ///   - hasVideoTrack: there is a video track at all — an audio-only source
    ///     legitimately displays no pictures for its whole duration.
    ///   - seekSettling: a seek window is open; the picture is expected to hold
    ///     while the demuxer re-anchors, and `updateSeekLoading` owns that wait.
    ///   - mediaConfirmedOpen: a demuxer exists. Before that the open watchdog
    ///     owns every failure mode.
    mutating func sample(
        displayedPictures: UInt64?,
        positionMs: Int32,
        isPlaying: Bool,
        hasVideoTrack: Bool,
        seekSettling: Bool,
        mediaConfirmedOpen: Bool
    ) -> Outcome {
        guard isPlaying, hasVideoTrack, mediaConfirmedOpen, !seekSettling,
              let pictures = displayedPictures else {
            // Not a state this type judges. Drop the sampling window — the next
            // comparison must not span the gap — but keep the budget, which
            // belongs to the playback and not to the window.
            lastPictures = nil
            lastPositionMs = nil
            stalledSeconds = 0
            return .healthy
        }

        defer {
            lastPictures = pictures
            lastPositionMs = positionMs
        }

        guard let previousPictures = lastPictures,
              let previousPosition = lastPositionMs else {
            return .healthy          // first sample of a window: nothing to compare
        }

        if pictures > previousPictures {
            stalledSeconds = 0
            healthySeconds += 1
            if healthySeconds >= Self.budgetRenewSeconds {
                healthySeconds = 0
                recoveriesLeft = Self.recoveryBudget
            }
            return .healthy
        }

        // Frames are not moving. Unless the CLOCK is, this is somebody else's
        // case — see the RULE above.
        guard positionMs > previousPosition else {
            stalledSeconds = 0
            return .healthy
        }

        stalledSeconds += 1
        healthySeconds = 0
        if stalledSeconds >= Self.stallSeconds, recoveriesLeft > 0 {
            recoveriesLeft -= 1
            stalledSeconds = 0
            return .recover
        }
        return .stalling(seconds: stalledSeconds)
    }
}
