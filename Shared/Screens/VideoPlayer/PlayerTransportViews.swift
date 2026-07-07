import UIKit

// Leaf UIKit views for the VLC stream presenter's custom transport. Relocated
// out of VLCStreamPresenter.swift (was a 1.7k-line file) — these are
// self-contained UIView/UIButton subclasses with no coupling to the view
// controller's playback/HUD state, only their own closures and properties.

#if os(tvOS)
/// Focusable tvOS scrub bar. Left/right seek ±10 s ONLY while this view holds
/// focus — every other press (up/down to move focus to the control buttons,
/// Play/Pause, Menu) is passed to `super` so the focus engine keeps working.
/// This is what lets the user reach the Audio/Subtitles/episode buttons; the
/// previous view-level arrow gestures swallowed left/right globally.
final class TVScrubBar: UIView {
    /// Discrete clickpad arrow press → ±1 step (caller maps to ±10 s).
    var onSeek: ((Int) -> Void)?
    var onSelect: (() -> Void)?
    /// Live position [0,1] while the user slides on the Siri Remote touch
    /// surface — caller updates the time labels only (no engine seek yet).
    var onScrubPreview: ((Float) -> Void)?
    /// Final position [0,1] when the slide ends — caller commits the seek.
    var onScrubCommit: ((Float) -> Void)?

    private let track = UIView()
    private let fill = UIView()
    private let knob = UIView()
    private var progressValue: Float = 0
    private var scrubProgress: Float = 0
    private var isScrubbing = false
    /// Finger travel (points) accumulated since the pan began but BEFORE the
    /// dead-zone is crossed — reset every gesture. See `activationThreshold`.
    private var pendingPanTravel: CGFloat = 0

    /// Touch-surface gain: fraction of the *whole timeline* covered per one
    /// full bar-width of finger travel on the remote. Lower = less sensitive /
    /// finer control. 0.2 ⇒ a full swipe ≈ a fifth of the movie. Tune here.
    /// (Was 0.5 — the Siri Remote 2nd-gen touch surface made that too fast, a
    /// small thumb slide jumped several minutes.)
    private let scrubGain: Float = 0.2

    /// Dead-zone: the finger must travel this many points on the touch surface
    /// before a scrub actually engages. The Siri Remote 2nd-gen fires a pan on
    /// the faintest contact, so without this a resting thumb starts scrubbing
    /// the instant it touches down AND swallows the ±N clickpad presses (`pressesBegan`
    /// bails while `isScrubbing`). Below the threshold the gesture is a no-op.
    private let activationThreshold: CGFloat = 30

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        track.layer.cornerRadius = 4
        track.clipsToBounds = true
        fill.backgroundColor = .white
        fill.layer.cornerRadius = 4
        knob.backgroundColor = .white
        knob.layer.cornerRadius = 11
        knob.alpha = 0
        addSubview(track)
        track.addSubview(fill)
        addSubview(knob)

        // Siri Remote touch-surface slide → variable scrubbing. tvOS delivers
        // indirect (remote touchpad) pans to the *focused* view's recognizers,
        // so this only fires while the bar holds focus — same contract as the
        // ±10 s clickpad presses below. Restricted to indirect touches so it
        // never competes with the focus engine's directional clicks.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        addGestureRecognizer(pan)

        // VoiceOver: expose the bar as an adjustable element so a swipe-up /
        // swipe-down seeks ±1 step (the caller maps to ±10 s). Label + value
        // (current playhead) are set by the presenter, which owns the strings.
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func accessibilityIncrement() { onSeek?(1) }
    override func accessibilityDecrement() { onSeek?(-1) }

    func setProgress(_ p: Float) {
        progressValue = max(0, min(1, p))
        setNeedsLayout()
    }

    override var canBecomeFocused: Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        let focused = isFocused
        let h: CGFloat = focused ? 12 : 8
        track.frame = CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        track.layer.cornerRadius = h / 2
        let w = bounds.width * CGFloat(progressValue)
        fill.frame = CGRect(x: 0, y: 0, width: w, height: h)
        fill.layer.cornerRadius = h / 2
        knob.frame = CGRect(x: w - 11, y: bounds.midY - 11, width: 22, height: 22)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({
            self.knob.alpha = self.isFocused ? 1 : 0
            self.setNeedsLayout()
            self.layoutIfNeeded()
        })
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A slide that ends in a click would otherwise also fire a ±10 s jump
        // on top of the scrub — ignore presses while a scrub is in flight.
        if isScrubbing { return }
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:  onSeek?(-1); handled = true
            case .rightArrow: onSeek?(1);  handled = true
            case .select:     onSelect?(); handled = true
            default: break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            // Do NOT engage scrubbing yet — wait until the finger has travelled
            // past the dead-zone (`activationThreshold`). Just arm the counter.
            pendingPanTravel = 0
        case .changed:
            // Incremental, not absolute: consume the delta each frame and
            // reset the recognizer. Avoids the "jump then snap to current"
            // glitch (no stale absolute baseline) and keeps motion fluid.
            let dx = Float(g.translation(in: self).x)
            g.setTranslation(.zero, in: self)
            if !isScrubbing {
                // Still inside the dead-zone: accumulate travel; a resting or
                // faintly-drifting thumb never crosses it, so ±N clicks keep
                // working. A deliberate slide crosses it within a few frames.
                pendingPanTravel += CGFloat(abs(dx))
                guard pendingPanTravel >= activationThreshold else { return }
                // Threshold crossed → take over the bar from the real playhead.
                // The caller suppresses the periodic tick so nothing fights it.
                isScrubbing = true
                scrubProgress = progressValue
                onScrubPreview?(scrubProgress)
            }
            scrubProgress += (dx / Float(max(bounds.width, 1))) * scrubGain
            scrubProgress = max(0, min(1, scrubProgress))
            setProgress(scrubProgress)
            onScrubPreview?(scrubProgress)
        case .ended, .cancelled, .failed:
            // Commit only if the dead-zone was crossed — a sub-threshold touch
            // is a no-op so it can't nudge the playhead or fight a clickpad press.
            defer { pendingPanTravel = 0 }
            guard isScrubbing else { return }
            isScrubbing = false
            onScrubCommit?(scrubProgress)
        default:
            break
        }
    }
}
#endif

/// Chapter strip cell. On tvOS, custom buttons get no system focus appearance,
/// so it draws its own: a clear lift + white ring on the thumbnail + un-dimming
/// so the focused chapter is unmistakable. On iOS it never receives focus, so
/// `didUpdateFocus` simply never fires and it behaves as a plain button.
final class ChapterChip: UIButton {
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        let thumb = viewWithTag(99)
        coordinator.addCoordinatedAnimations({
            self.alpha = focused ? 1.0 : 0.5
            self.transform = focused ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
            thumb?.layer.borderWidth = focused ? 3 : 0
            thumb?.layer.borderColor = UIColor.white.cgColor
        })
    }
}

/// HUD container that lets taps on its own (scrim/empty) area fall through to
/// the video view beneath — which hosts the tap recognizer. Taps that land on
/// an actual control (button / slider / chapter strip) are returned normally,
/// so the controls keep working and the tap-to-toggle never conflicts with
/// them. On tvOS it behaves like a plain `UIView` (focus, not hit-testing).
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        #if os(iOS)
        return hit === self ? nil : hit
        #else
        return hit
        #endif
    }
}
