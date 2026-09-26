import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cinemax", category: "VLCPlayback")

/// The VLC player's seek state, extracted from `VLCStreamViewController` (#193)
/// so the parts that decide WHEN a seek fires and WHEN it has landed are
/// testable without a live engine. The pure math it builds on stays in
/// `SeekCoalescer` / `SeekSettleTracker`; this type owns the state and the
/// timers around them:
///
/// - the **pending target** — what the HUD shows while a seek is on its way,
///   so the periodic tick cannot snap the bar back to the pre-seek position;
/// - the **coalesced ±N commit** — N presses, ONE engine seek, `commitDelay`
///   after the last press;
/// - the **settle window** — the spinner held until the playhead is seen
///   moving again, shown only if the wait outlasts `spinnerDelay`;
/// - the **`engineSeek` funnel** every seek path goes through, and its
///   near-end clamp.
///
/// It knows nothing of UIKit, libVLC or SyncPlay: it reads the engine through
/// three closures and acts through five callbacks the controller wires up. The
/// controller keeps the spinner itself, the labels, and the decision of who
/// performs a USER seek (the group or the engine).
@MainActor
final class SeekMachine {
    /// The engine's state as far as a settling seek cares. The cases mirror
    /// libVLC's; anything else carries its own name for the logs.
    enum EngineState: Equatable, CustomStringConvertible {
        case opening, buffering, playing, paused
        case other(String)

        var description: String {
            switch self {
            case .opening: "opening"
            case .buffering: "buffering"
            case .playing: "playing"
            case .paused: "paused"
            case .other(let name): name
            }
        }
    }

    /// Debounce for coalesced ±N skips / chapter jumps. Don't "fix" it away:
    /// the HUD jumps to the projected position at once, so it reads as
    /// responsive, and the delay is what collapses N byte-range re-opens into
    /// one against a self-hosted origin.
    static let commitDelay: TimeInterval = 0.3
    /// Grace period before the post-seek spinner appears: a seek that lands
    /// instantly (cached / local range) must not flash a spinner, only one that
    /// actually makes the user wait should.
    static let spinnerDelay: TimeInterval = 0.35
    /// Forward progress that counts as "frames are flowing again". libVLC ticks
    /// ~4×/s while playing; while re-buffering the position doesn't advance.
    static let landedProgressMs: Int32 = 120
    /// Backstop so a missed engine signal can never leave the spinner turning
    /// forever over a picture that is actually playing.
    static let maxHold: TimeInterval = 30
    /// How close the live position must come to the pending target before the
    /// HUD stops holding the target and follows the engine again.
    static let targetReachedToleranceMs = 1200

    // MARK: Engine readings

    private let currentMs: () -> Int32
    private let lengthMs: () -> Int32
    private let engineState: () -> EngineState
    private let now: () -> Date
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void

    // MARK: Callbacks (wired by the controller)

    /// The raw engine seek, already clamped. Nothing else.
    var performSeek: (Int32) -> Void = { _ in }
    /// A coalesced skip is due. The controller routes it as a USER seek — to
    /// the SyncPlay group when in one, else back through `engineSeek` — and
    /// repaints.
    var commitUserSeek: (Int32) -> Void = { _ in }
    /// Paint a position into the HUD (position ms, length ms).
    var paint: (Int32, Int32) -> Void = { _, _ in }
    /// The settle window outlasted `spinnerDelay`: show the spinner. Hiding it
    /// stays with the controller, behind its own open gate.
    var showSpinner: () -> Void = {}
    /// A settle window closed (landed or backstop). The flag is whether the
    /// engine is playing — what a SyncPlay `Ready` report carries.
    var onSettled: (_ isPlaying: Bool) -> Void = { _ in }

    // MARK: State

    /// Set on scrub release / coalesced skip: VLC applies a seek
    /// asynchronously, so until the live position reaches this the HUD must
    /// keep showing the target instead of the stale pre-seek position.
    private(set) var pendingTargetMs: Int32?
    private var commitWork: DispatchWorkItem?

    /// Target of the engine seek currently settling, or nil when none is.
    /// libVLC echoes the target as a time update the instant the seek is
    /// issued — long before it has re-opened the byte range and re-buffered —
    /// so the time tick alone would clear the spinner while the picture is
    /// still frozen (the "no loader after a fast-forward" bug).
    private var settlingTargetMs: Int32?
    private var settle = SeekSettleTracker()
    /// Consecutive samples that showed forward progress. While the engine still
    /// reports `.opening`/`.buffering` two in a row are required.
    private var progressTicks = 0
    private var settleStartedAt = Date.distantPast
    private var spinnerWork: DispatchWorkItem?

    /// Whether a seek is still settling — the test the auto-skip, the stall
    /// watchdog and the SyncPlay readiness gate all read.
    var isSettling: Bool { settlingTargetMs != nil }

    init(
        currentMs: @escaping () -> Int32,
        lengthMs: @escaping () -> Int32,
        engineState: @escaping () -> EngineState,
        now: @escaping () -> Date = Date.init,
        schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.currentMs = currentMs
        self.lengthMs = lengthMs
        self.engineState = engineState
        self.now = now
        self.schedule = schedule
    }

    // MARK: The funnel

    /// Every seek path ends here: scrub release, coalesced skips, chapter
    /// jumps, skip intro/outro, the resume seek, the SyncPlay echo, an inbound
    /// remote Seek, a track switch's re-anchor.
    ///
    /// The near-end guard belongs HERE, not one level up. `SeekCoalescer.clamp`
    /// once had a SINGLE caller — the ±N skip path — while the other entries
    /// went through unbounded. At the right edge `slider.value == 1.0`, so a
    /// drag targeted `lengthMs` EXACTLY; libVLC refuses that
    /// (`INPUT_CONTROL_SET_TIME @… failed`) and the input never recovers —
    /// frozen picture under a HUD still reading "playing", the spinner held to
    /// its 30 s backstop, and every later seek dead too (measured on device
    /// 2026-08-21: `target=2503936` on a `lengthMs` of 2503936). The ±N path
    /// clamps a second time — idempotent, and it keeps its own call because it
    /// also PAINTS the clamped target before the debounced commit.
    func engineSeek(_ ms: Int32) {
        let target = SeekCoalescer.clamp(target: ms, lengthMs: lengthMs())
        // Diagnostics: every seek path funnels here.
        logger.info("""
            seek-fire target=\(target, privacy: .public) \
            from=\(self.currentMs(), privacy: .public) \
            state=\(self.engineState().description, privacy: .public)
            """)
        beginSettle(target: target)
        performSeek(target)
    }

    // MARK: Coalesced seeking
    //
    // A ±N skip used to fire an immediate relative `player.seek(by:)` on every
    // press, which storms a self-hosted / reverse-proxied origin with
    // byte-range open/cancel churn and can stall the stream. Instead an
    // ABSOLUTE target accumulates and ONE engine seek commits a beat after the
    // last press; the HUD jumps to the projected position immediately.

    /// Accumulate a ±N skip: advance the pending target from the last target
    /// (or the live position if none) and re-arm the debounced commit.
    func skip(bySeconds delta: Int) {
        accumulate(toAbsoluteMs: SeekCoalescer.relativeTarget(
            deltaSeconds: delta, pendingMs: pendingTargetMs, currentMs: currentMs()))
    }

    /// Set an absolute pending target, paint it immediately, and (re)arm the
    /// single debounced engine seek. Shared by ±N skips and chapter jumps.
    func accumulate(toAbsoluteMs target: Int32) {
        let len = lengthMs()
        let clamped = SeekCoalescer.clamp(target: target, lengthMs: len)
        pendingTargetMs = clamped // also holds the bar until VLC catches up
        paint(clamped, len)
        commitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitPending() }
        commitWork = work
        schedule(Self.commitDelay, work)
    }

    /// Hold the HUD at `target` until the engine reaches it — the tvOS scrub
    /// release, which paints and seeks on its own.
    func hold(at target: Int32) {
        pendingTargetMs = target
    }

    /// Drop any uncommitted skip (scrub takeover, media reload, teardown) so a
    /// stale target can't seek the wrong position / a freshly-loaded episode.
    func cancelPending() {
        commitWork?.cancel()
        commitWork = nil
        pendingTargetMs = nil
        endSettle() // a superseded seek must not keep holding the spinner
    }

    /// The position the HUD should show now: the pending target until the live
    /// position comes within `targetReachedToleranceMs` of it (at which point
    /// the target is dropped), the live position otherwise.
    func displayPosition() -> Int32 {
        let live = currentMs()
        if let target = pendingTargetMs {
            if abs(Int(live) - Int(target)) <= Self.targetReachedToleranceMs {
                pendingTargetMs = nil
            } else {
                return target
            }
        }
        return live
    }

    /// Fire the one accumulated seek. The pending target stays set so the HUD
    /// keeps showing it until the engine's position reaches it.
    private func commitPending() {
        commitWork = nil
        guard let target = pendingTargetMs else { return }
        commitUserSeek(target)
    }

    // MARK: Settle window
    //
    // A seek tears down and re-opens libVLC's HTTP byte range, so on a slow /
    // self-hosted origin the picture stays frozen on the pre-seek frame for
    // several seconds while VLC already reports the new position.

    /// Arm the settle window for a seek that just fired. The spinner only shows
    /// if the seek hasn't produced real frames within `spinnerDelay`.
    private func beginSettle(target: Int32) {
        settlingTargetMs = target
        settle.reset()
        progressTicks = 0
        settleStartedAt = now()
        spinnerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Re-check rather than trusting the window is still open: a seek
            // that already resumed (or settled into pause) must not flash a
            // spinner.
            guard let self, self.sampleSettle() else { return }
            self.showSpinner()
        }
        spinnerWork = work
        schedule(Self.spinnerDelay, work)
    }

    /// Drop the settle window (landed, superseded, or no frames expected any
    /// more). Doesn't touch the spinner — the caller owns that.
    func endSettle() {
        spinnerWork?.cancel()
        spinnerWork = nil
        settlingTargetMs = nil
        settle.reset()
        progressTicks = 0
    }

    /// Re-evaluates a settling seek against the live position. Returns true
    /// while the spinner must stay up; clears the window (and returns false) as
    /// soon as the playhead is moving again, the player has settled into pause,
    /// or the backstop expires. Called from the time tick, the 1 s heartbeat
    /// and the `.playing` state change — every path that would otherwise hide
    /// the spinner.
    @discardableResult
    func sampleSettle() -> Bool {
        guard settlingTargetMs != nil else { return false }
        let position = currentMs()
        let state = engineState()
        // The tracker keeps its baseline until progress is actually confirmed.
        // Comparing against the PREVIOUS sample instead made this dependent on
        // how often it is called: the time tick fires several times per 100 ms,
        // so every comparison spanned far less than the threshold and a seek
        // that had already resumed at full speed never counted as landed.
        let moved = settle.noteProgress(positionMs: position, thresholdMs: Self.landedProgressMs)
        progressTicks = moved ? progressTicks + 1 : 0

        let landed: Bool
        switch state {
        case .paused:
            // Nothing more to wait for: VLC emits no time updates while paused,
            // and the frame at the seek target is exactly what was asked for.
            landed = true
        case .opening, .buffering:
            // The engine says it's still loading, so demand sustained progress:
            // a single jump can be the demuxer resettling on a distant
            // keyframe, not frames reaching the screen.
            landed = progressTicks >= 2
        default:
            landed = moved // the playhead is moving again: real frames
        }
        let elapsed = now().timeIntervalSince(settleStartedAt)
        // Logged only while a window is open, but that is still ~4 lines a
        // second for as long as a seek takes to land — `.debug` keeps it
        // available under a live `log stream` without persisting it.
        logger.debug("""
            seek-settle state=\(state.description, privacy: .public) \
            now=\(position, privacy: .public) moved=\(moved, privacy: .public) \
            ticks=\(self.progressTicks, privacy: .public) \
            landed=\(landed, privacy: .public) \
            since=\(elapsed, format: .fixed(precision: 2), privacy: .public)
            """)
        // Backstop: a missed engine signal must never strand the spinner.
        let expired = elapsed > Self.maxHold
        guard landed || expired else { return true }
        endSettle()
        // The one moment a SyncPlay group in `Waiting` can hear that this
        // participant arrived: libVLC emits no state change when a seek settles
        // on an already-open stream. The backstop reports too — a stranded
        // group is worse than a report made a beat late.
        onSettled(state == .playing)
        return false
    }
}
