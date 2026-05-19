import UIKit

// Leaf UIKit views for the VLC stream presenter's custom transport. Relocated
// out of VLCStreamPresenter.swift (was a 1.7k-line file) — these are
// self-contained UIView/UIButton subclasses with no coupling to the view
// controller's playback/HUD state, only their own closures and properties.

#if os(tvOS)
/// Focusable tvOS scrub bar. Left/right seek ±15 s ONLY while this view holds
/// focus — every other press (up/down to move focus to the control buttons,
/// Play/Pause, Menu) is passed to `super` so the focus engine keeps working.
/// This is what lets the user reach the Audio/Subtitles/episode buttons; the
/// previous view-level arrow gestures swallowed left/right globally.
final class TVScrubBar: UIView {
    var onSeek: ((Int) -> Void)?
    var onSelect: (() -> Void)?

    private let track = UIView()
    private let fill = UIView()
    private let knob = UIView()
    private var progressValue: Float = 0

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

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
