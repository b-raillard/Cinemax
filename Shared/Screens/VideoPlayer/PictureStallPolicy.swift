import Foundation

/// Decides whether the picture has stopped — a wedged video decoder, or a
/// whole pipeline stalled — in the middle of a playback that every other
/// signal still calls healthy.
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
/// **RULE — the clock does NOT have to be advancing; the engine STATE is the
/// gate.** Whether the clock moves or not, *the engine says `.playing` and no
/// picture comes out* is never legitimate: a pause is `.paused`, a rebuffer is
/// `.buffering` (and shows the spinner), the end of media is `.stopped`, a seek
/// has its own settle window — all four already leave through the `guard`
/// below. This used to demand a moving clock, on the grounds that "frozen
/// pictures and frozen clock" always had another owner. It does not: measured
/// on the same Apple TV on 2026-09-15 (Pat' Patrouille in the afternoon, a
/// Punisher episode in the evening), the picture AND the SOUND stopped, no
/// spinner showed, a −10 s seek raised the spinner and never landed — the
/// input no longer serviced anything — and the server received no diagnostic
/// document, i.e. this guard saw the frozen clock and stood down. Nothing else
/// owns a pipeline that stalls while libVLC still reports `.playing`: the open
/// watchdog covers the OPEN phase, `PlaybackEndPolicy` needs a `.stopped`, and
/// no error is ever emitted. The rebuild is the same cure for both shapes — a
/// fresh player opens a fresh connection as well as a fresh decoder.
/// `stallClockMoved` says which of the two a given recovery was, so the
/// document tells them apart.
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
    /// Whether the clock advanced during the current run of frozen pictures:
    /// `true` is the wedged decoder of 2026-09-13 (sound and clock went on),
    /// `false` the whole pipeline of 2026-09-15 (sound stopped too). Read when
    /// an outcome is logged; reset with the run.
    private(set) var stallClockMoved = false
    private var healthySeconds = 0
    private(set) var recoveriesLeft: Int

    init() {
        recoveriesLeft = Self.recoveryBudget
    }

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
        stallClockMoved = false
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
            stallClockMoved = false
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
            stallClockMoved = false
            healthySeconds += 1
            if healthySeconds >= Self.budgetRenewSeconds {
                healthySeconds = 0
                recoveriesLeft = Self.recoveryBudget
            }
            return .healthy
        }

        // Frames are not moving while the engine says it is playing — with or
        // without the clock, see the RULE above.
        if stalledSeconds == 0 { stallClockMoved = false }
        if positionMs > previousPosition { stallClockMoved = true }

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

/// Watches the INPUT rather than the picture: bytes stop arriving while the
/// engine still plays from what it has already buffered.
///
/// **This sees the fault ~20 s before `PictureStallPolicy` can**, and that gap
/// is the whole point. Measured on an Apple TV on 2026-09-20 (« Just Play
/// Dead », a 6,6 Go MKV in DirectStream through the reverse-proxied server, two
/// freezes eight minutes apart, both uploaded as `playback-freeze`): the origin
/// cancelled the long-lived HTTP/2 stream mid-film — `peer stream 27 error:
/// Cancellation (0x8)` at 17:41:47, `peer stream 25 error` at 17:48:55, the
/// first preceded by a read that timed out — and libVLC's own HTTP access has
/// **no mid-stream reconnect**, so nothing was ever fed to the demuxer again.
/// The picture ran on from the buffer (18 s the second time), so every picture-
/// keyed guard was still seeing a healthy stream; only once the buffer drained
/// did `PictureStallPolicy` fire, i.e. after the viewer had been staring at a
/// frozen frame. The transparent reconnect the app owns lives in
/// `CinemaxStreamProxy`, and a direct stream never goes through it.
///
/// So this watchdog keys on `readBytes`, the input counter, and fires while the
/// picture is STILL PLAYING — which is what makes the cure cheap: a re-anchor
/// seek, which is the one thing that makes libVLC open a fresh connection
/// (`VLCStreamPresenter.reanchorAfterFeedStall`). If that does not restore the
/// feed, the picture stops a few seconds later and `PictureStallPolicy` rebuilds
/// the player exactly as before — the escalation costs no state of its own.
///
/// **Four refusals, and each one answers a way the input legitimately goes
/// quiet**: an adaptive (HLS) stream fetches in per-segment bursts, so silence
/// between two segments is normal; a source whose every byte has been read has
/// nothing left to fetch (a short trailer buffers whole, and any file does near
/// its end); a settling seek owns its own wait; and before `mediaConfirmedOpen`
/// the open watchdog owns every failure. `readBytes == nil` (no statistics) is
/// "cannot tell", never a stall — same discipline as the picture counter.
struct FeedStallPolicy {
    /// Consecutive seconds without a single new byte before re-anchoring. A
    /// playing stream reads roughly a second of media per second, so five
    /// silent seconds is already far outside the jitter of a healthy feed.
    static let stallSeconds = 5

    /// How many times ONE playback may re-anchor itself. Bounded like every
    /// other self-healing path here: a link that dies again immediately must
    /// surface as a frozen picture (and the rebuild that follows), never as a
    /// silent loop of seeks against the server.
    static let reanchorBudget = 2

    /// Seconds of a feed that is actually delivering that renew the budget —
    /// proof the re-anchor worked, the same reasoning as the picture policy's.
    static let budgetRenewSeconds = 60

    /// Slack under the source size within which "everything is read" holds.
    /// The server's reported size and libVLC's byte count need not agree to the
    /// byte (headers, the range the access actually issued), so the comparison
    /// is deliberately loose — being late to fire on a nearly-finished file
    /// costs nothing, firing on a fully-buffered one costs a needless seek.
    static let fullyReadSlackBytes: UInt64 = 4 * 1024 * 1024

    enum Outcome: Equatable {
        case healthy
        /// Silent for this many consecutive seconds, with no re-anchor spent —
        /// either below the threshold, or the budget is exhausted.
        case stalling(seconds: Int)
        /// Re-anchor playback at the current position to force a fresh
        /// connection.
        case reanchor
    }

    private var lastBytes: UInt64?
    private var stalledSeconds = 0
    private var healthySeconds = 0
    private(set) var reanchorsLeft: Int

    init() {
        reanchorsLeft = Self.reanchorBudget
    }

    /// Called at every fresh open. Clears the window; **keeps the budget**, for
    /// the reason `PictureStallPolicy.resetWindow` spells out — the re-anchor
    /// itself reopens the input, so restoring the allowance here would remove
    /// the bound entirely.
    mutating func resetWindow() {
        lastBytes = nil
        stalledSeconds = 0
        healthySeconds = 0
    }

    /// One sample per second, from the player's existing 1 s heartbeat.
    ///
    /// - Parameters:
    ///   - readBytes: libVLC's count of bytes read from the input.
    ///   - sourceSizeBytes: the server's size for the source, when it reports
    ///     one. Once `readBytes` reaches it the input is DONE, not dead.
    ///   - isPlaying: the engine's state is `.playing`.
    ///   - isAdaptiveStream: an HLS stream — its input is bursty by design.
    ///   - seekSettling: a seek window is open; `updateSeekLoading` owns it.
    ///   - mediaConfirmedOpen: a demuxer exists.
    mutating func sample(
        readBytes: UInt64?,
        sourceSizeBytes: Int64?,
        isPlaying: Bool,
        isAdaptiveStream: Bool,
        seekSettling: Bool,
        mediaConfirmedOpen: Bool
    ) -> Outcome {
        guard isPlaying, mediaConfirmedOpen, !seekSettling, !isAdaptiveStream,
              let bytes = readBytes, !Self.isFullyRead(bytes, sourceSizeBytes) else {
            lastBytes = nil
            stalledSeconds = 0
            return .healthy
        }

        defer { lastBytes = bytes }

        guard let previous = lastBytes else {
            return .healthy          // first sample of a window: nothing to compare
        }

        if bytes > previous {
            stalledSeconds = 0
            healthySeconds += 1
            if healthySeconds >= Self.budgetRenewSeconds {
                healthySeconds = 0
                reanchorsLeft = Self.reanchorBudget
            }
            return .healthy
        }

        stalledSeconds += 1
        healthySeconds = 0
        if stalledSeconds >= Self.stallSeconds, reanchorsLeft > 0 {
            reanchorsLeft -= 1
            stalledSeconds = 0
            return .reanchor
        }
        return .stalling(seconds: stalledSeconds)
    }

    /// Whether the whole source has been read, i.e. the input has nothing left
    /// to fetch and its silence is the ordinary end of its work.
    static func isFullyRead(_ readBytes: UInt64, _ sourceSizeBytes: Int64?) -> Bool {
        guard let size = sourceSizeBytes, size > 0 else { return false }
        return readBytes + fullyReadSlackBytes >= UInt64(size)
    }
}
