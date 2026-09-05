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
    /// One thin mark per chapter boundary, as fractions of the timeline.
    ///
    /// The strip below the bar already lists the chapters, but it says nothing
    /// about WHERE they fall — so the bar answered "how far in am I?" and the
    /// strip answered "what are the parts?", with nothing joining the two. The
    /// marks are drawn as layers rather than subviews so a 40-chapter film adds
    /// no views to the focus engine's hit-testing.
    private var chapterMarks: [Float] = []
    private var chapterLayers: [CALayer] = []
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

    /// Chapter boundaries as fractions of the timeline, in any order.
    ///
    /// The first mark is dropped when it sits at the very start: every film's
    /// first chapter begins at 0, and a tick welded to the left edge of the bar
    /// reads as a rendering artefact rather than as a boundary.
    func setChapterMarks(_ fractions: [Float]) {
        let cleaned = fractions
            .filter { $0 > 0.001 && $0 < 0.999 }
            .sorted()
        guard cleaned != chapterMarks else { return }
        chapterMarks = cleaned
        rebuildChapterLayers()
        setNeedsLayout()
    }

    private func rebuildChapterLayers() {
        chapterLayers.forEach { $0.removeFromSuperlayer() }
        chapterLayers = chapterMarks.map { _ in
            let mark = CALayer()
            mark.backgroundColor = UIColor.white.withAlphaComponent(0.55).cgColor
            track.layer.addSublayer(mark)
            return mark
        }
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

        // Marks sit ABOVE the fill (added to `track.layer`, `fill` is a
        // subview added before them), so a boundary already passed stays
        // visible against the white fill.
        let markWidth: CGFloat = 2
        CATransaction.begin()
        // The bar animates its height on focus; the marks must move with it in
        // one step rather than drift across an implicit animation of their own.
        CATransaction.setDisableActions(true)
        for (mark, fraction) in zip(chapterLayers, chapterMarks) {
            let x = (track.bounds.width * CGFloat(fraction)) - markWidth / 2
            mark.frame = CGRect(x: x, y: 0, width: markWidth, height: h)
        }
        CATransaction.commit()
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

#if os(tvOS)
/// The player's option panel: audio tracks, subtitles, speed, audio/subtitle
/// delay. One glass sheet with focusable rows, in place of the system
/// `UIAlertController` action sheet those five pickers used to raise.
///
/// The action sheet was the wrong shape here in three ways. It renders as a
/// system-styled slab that shares nothing with the player's own chrome — the
/// info panel three points away is a `UIVisualEffectView`. It marks the current
/// track by appending a literal `"  ✓"` to the label, which reads as part of
/// the track name. And it is a separate presentation context, so it dimmed the
/// picture behind it and took the Menu button out of the presenter's own peel
/// order, where every other layer of this player is handled.
///
/// A leaf view like `TVScrubBar`: it owns its focus and its layout, and talks
/// to the presenter through closures only.
final class TVOptionPanel: UIView {
    struct Option {
        let title: String
        let isSelected: Bool
        let action: () -> Void
    }

    /// Fired when a row is chosen. The presenter decides whether that closes
    /// the panel — a delay nudge keeps it open and re-renders in place.
    ///
    /// There is no cancel closure and no cancel row: the panel is part of the
    /// player's own Menu peel order now, where the action sheet it replaces was
    /// a separate presentation context that needed its own way out.
    var onSelect: ((Int) -> Void)?

    private let titleLabel = UILabel()
    private let rowStack = UIStackView()
    private let scroll = UIScrollView()

    /// The row the focus engine should land on when the panel appears or is
    /// re-rendered. Preserved across a re-render so a repeated delay nudge does
    /// not throw focus back to the first row on every press.
    private var preferredIndex: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        addSubview(blur)
        layer.cornerRadius = 20
        clipsToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.axis = .vertical
        rowStack.spacing = 4
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(rowStack)
        addSubview(scroll)
        // Faded in by the presenter; without this the panel would snap in at
        // full opacity while only its scrim animated.
        alpha = 0

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),

            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),

            rowStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rowStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rowStack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Renders a fresh set of options. Safe to call on an already-visible
    /// panel: that is how a delay nudge updates its running value in the title
    /// without the picker blinking out and back.
    ///
    /// **A re-render keeps the row the user is standing on.** Deriving the
    /// index afresh every time looks harmless but is not: a delay picker's four
    /// nudge rows are all unselected, so "first selected, else 0" sent focus to
    /// −250 ms after a +50 ms press — a second press would then apply the
    /// opposite delta. Only a first render picks the selected row.
    func render(title: String, options: [Option]) {
        let isRerender = !rowStack.arrangedSubviews.isEmpty
        titleLabel.text = title
        // `Option.action` is deliberately not stored: the presenter owns the
        // actions and invokes them by index, so keeping a second copy here
        // would pin a `Track` per audio row for the panel's lifetime.

        if !isRerender {
            preferredIndex = options.firstIndex(where: { $0.isSelected }) ?? 0
        }
        preferredIndex = min(max(preferredIndex, 0), max(options.count - 1, 0))

        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, opt) in options.enumerated() {
            rowStack.addArrangedSubview(makeRow(index: i, option: opt))
        }
    }

    /// The row the panel wants focused. The presenter forwards this from its own
    /// `preferredFocusEnvironments`.
    var preferredRow: UIView? {
        let views = rowStack.arrangedSubviews
        guard !views.isEmpty else { return nil }
        return views[min(max(preferredIndex, 0), views.count - 1)]
    }

    private func makeRow(index: Int, option: Option) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.title = option.title
        cfg.baseForegroundColor = .white
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 40, bottom: 16, trailing: 40)
        // The selection mark is an IMAGE beside the label, not a "  ✓" glued to
        // the end of it — appended to the string it reads as part of the track's
        // own name, which on a list of language labels is genuinely confusing.
        // Always an image, transparent when unselected, so the selected row's
        // label does not shift sideways relative to its neighbours.
        //
        // The transparency has to be baked INTO the image (`.alwaysOriginal`
        // over a clear tint): a `UIButton.Configuration` paints a template
        // image with `baseForegroundColor`, never with the button's
        // `tintColor`, so the first version — `tintColor = .clear` on the
        // unselected rows — drew a white check on EVERY row, the delay row
        // included, and the picker could not say which track was playing
        // (measured on device 2026-09-04).
        let check = UIImage(systemName: "checkmark")
        cfg.image = option.isSelected
            ? check
            : check?.withTintColor(.clear, renderingMode: .alwaysOriginal)
        cfg.imagePlacement = .leading
        cfg.imagePadding = 16
        cfg.titleAlignment = .leading
        let button = TVOptionRow(type: .custom)
        button.configuration = cfg
        button.contentHorizontalAlignment = .leading
        button.tag = index
        // The former "  ✓" suffix was at least SPOKEN; a `cfg.image` is not, so
        // selection has to be carried explicitly or VoiceOver loses it.
        button.accessibilityLabel = option.title
        button.accessibilityTraits = option.isSelected ? [.button, .selected] : .button
        button.addTarget(self, action: #selector(rowTapped(_:)), for: .primaryActionTriggered)
        return button
    }

    @objc private func rowTapped(_ sender: UIButton) {
        // Remember where the user was, so a re-render (a delay nudge) comes
        // back under their thumb rather than at the top of the list.
        preferredIndex = sender.tag
        onSelect?(sender.tag)
    }
}

/// A panel row. Focus is the app's row level — an accent-free white wash and no
/// scale, since a row that grows shifts its own label sideways.
private final class TVOptionRow: UIButton {
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = self.isFocused
                ? UIColor.white.withAlphaComponent(0.22)
                : .clear
            self.layer.cornerRadius = 12
        })
    }
}
#endif
