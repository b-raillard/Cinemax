import UIKit
import CinemaxKit

// MARK: - Watch Together HUD pieces
//
// Three views the VLC presenter adds to its own chrome during a SyncPlay
// session. All of them are **information, never commands**:
//
//   RULE — none of these may become focusable. Every focus defect this player
//   has had came from adding a focusable to the HUD, and none of these three
//   asks the user for anything. They all set `isUserInteractionEnabled = false`
//   for the same reason `loadingIndicator` has to (a bare `UIView` and a
//   `UIActivityIndicatorView` both default to `true`, and an overlay that wins
//   the hit-test turns its own rectangle into a dead zone for swipe-to-dismiss,
//   tap-to-toggle and hold-to-2×).

extension UIColor {
    /// `0xRRGGBB` → colour. The design system's own hex initialiser is
    /// file-private to `CinemaGlassTheme.swift`, and the player is UIKit — so
    /// the two chrome files that need one share this instead of each rolling
    /// their own.
    static func cinemaHex(_ hex: UInt, alpha: CGFloat = 1.0) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

/// Per-person colour, derived from the name so the same participant reads the
/// same on every device in the room. Jellyfin sends usernames and nothing else
/// — no avatar, no colour — so this is deterministic rather than arbitrary.
private func participantColor(for name: String) -> UIColor {
    let palette: [UInt] = [0x4CAF82, 0xE5A54B, 0x6E9BE8, 0xC77BC0, 0x5FC9C1, 0xE8836E]
    var hash: UInt64 = 5381
    for byte in name.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(byte) }
    return .cinemaHex(palette[Int(hash % UInt64(palette.count))])
}

private func initial(for name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
}

// MARK: - Presence strip

/// One chip per participant, in the HUD beside the title.
///
/// It replaces a pill that said "Ensemble · 3" — a count that never said who,
/// on the one screen where knowing who is the entire point of the feature.
///
/// **The state ring is GROUP-level, not per person.** Jellyfin's
/// `GroupStateUpdate` is `{ State, Reason }`: it says the group is waiting, it
/// never says who for. Ringing one participant differently from another would
/// be inventing information the protocol does not carry.
final class SyncPlayPresenceStrip: UIView {
    private let stack = UIStackView()

    /// Chips drawn before collapsing the rest into a "+N". A six-person group is
    /// legitimate and its names would otherwise run off an iPhone's right edge —
    /// the strip carries only leading + top constraints, and each name label
    /// takes its full intrinsic width.
    private let maxChips = 4

    #if os(tvOS)
    private let avatarSize: CGFloat = 44
    private let nameFont: CGFloat = 18
    private let initialFont: CGFloat = 20
    private let spacing: CGFloat = 14
    #else
    private let avatarSize: CGFloat = 28
    private let nameFont: CGFloat = 10
    private let initialFont: CGFloat = 13
    private let spacing: CGFloat = 8
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        stack.axis = .horizontal
        stack.spacing = spacing
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `you` is matched against the participant list so the viewer's own chip
    /// can be labelled rather than showing them their own username.
    func update(participants: [String], state: SyncPlayGroupState, you: String?, youLabel: String, accent: UIColor) {
        isHidden = participants.isEmpty
        guard !participants.isEmpty else { return }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // The viewer first: their own chip is the anchor for reading the rest.
        let ordered = participants.sorted { a, _ in a == you }
        for name in ordered.prefix(maxChips) {
            stack.addArrangedSubview(chip(name: name, isYou: name == you, youLabel: youLabel, state: state, accent: accent))
        }
        let overflow = ordered.count - maxChips
        if overflow > 0 {
            stack.addArrangedSubview(chip(name: "+\(overflow)", isYou: false, youLabel: youLabel, state: state, accent: accent))
        }
    }

    private func chip(name: String, isYou: Bool, youLabel: String, state: SyncPlayGroupState, accent: UIColor) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 3

        let avatar = UILabel()
        avatar.text = initial(for: name)
        avatar.font = .systemFont(ofSize: initialFont, weight: .bold)
        avatar.textColor = .cinemaHex(0x0E0E0E)
        avatar.textAlignment = .center
        avatar.backgroundColor = participantColor(for: name)
        avatar.layer.cornerRadius = avatarSize / 2
        avatar.clipsToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: avatarSize)
        ])

        // The ring is what carries the group's state.
        switch state {
        case .playing:
            avatar.layer.borderColor = accent.cgColor
            avatar.layer.borderWidth = 2
            avatar.alpha = 1
        case .waiting:
            avatar.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
            avatar.layer.borderWidth = 2
            avatar.alpha = 1
            addPulse(to: avatar)
        case .paused, .idle:
            avatar.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
            avatar.layer.borderWidth = 2
            avatar.alpha = 0.6
        }

        let label = UILabel()
        label.text = isYou ? youLabel : name
        label.font = .systemFont(ofSize: nameFont, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.75)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: avatarSize * 2).isActive = true

        container.addArrangedSubview(avatar)
        container.addArrangedSubview(label)
        container.isAccessibilityElement = true
        container.accessibilityLabel = isYou ? youLabel : name
        return container
    }

    private func addPulse(to view: UIView) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.4
        animation.duration = 0.7
        animation.autoreverses = true
        animation.repeatCount = .infinity
        view.layer.add(animation, forKey: "syncplay.pulse")
    }
}

// MARK: - Waiting overlay

/// Shown while the group is `Waiting` — i.e. somebody is buffering and everyone
/// else's picture is held.
///
/// Without it the wait is indistinguishable from a freeze, which is the exact
/// defect the seek settle window closed on the other side of this player: an
/// unexplained pause reads as a bug, every time.
///
/// It deliberately does NOT name a participant: `GroupStateUpdate` carries no
/// username, so "waiting for Paul" would be a guess dressed as a fact.
final class SyncPlayWaitingOverlay: UIView {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let bar = UIView()
    private let barFill = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        backgroundColor = UIColor.black.withAlphaComponent(0.55)

        #if os(tvOS)
        let titleSize: CGFloat = 34, subtitleSize: CGFloat = 22, barWidth: CGFloat = 320
        #else
        let titleSize: CGFloat = 19, subtitleSize: CGFloat = 13, barWidth: CGFloat = 200
        #endif

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: titleSize, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        subtitleLabel.font = .systemFont(ofSize: subtitleSize, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2

        bar.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        bar.layer.cornerRadius = 2
        bar.clipsToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        barFill.backgroundColor = .white
        barFill.layer.cornerRadius = 2
        bar.addSubview(barFill)
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: barWidth),
            bar.heightAnchor.constraint(equalToConstant: 4)
        ])

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(bar)
        stack.setCustomSpacing(18, after: subtitleLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if barFill.frame.width == 0 {
            barFill.frame = CGRect(x: 0, y: 0, width: bar.bounds.width * 0.35, height: 4)
        }
    }

    func configure(title: String, subtitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        guard (alpha > 0) != visible else { return }
        if visible { startBar() } else { barFill.layer.removeAllAnimations() }
        UIView.animate(withDuration: animated ? 0.3 : 0) { self.alpha = visible ? 1 : 0 }
    }

    private func startBar() {
        layoutIfNeeded()
        let travel = bar.bounds.width
        barFill.frame = CGRect(x: -travel * 0.35, y: 0, width: travel * 0.35, height: 4)
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -travel * 0.2
        animation.toValue = travel * 1.2
        animation.duration = 1.3
        animation.repeatCount = .infinity
        barFill.layer.add(animation, forKey: "syncplay.bar")
    }
}

// MARK: - Event line

/// A transient line — "Marie a rejoint" — top-left of the player.
///
/// Deliberately NOT a toast: a two-hour session produces a steady trickle of
/// these and none of them asks the user to decide anything, so stacking them in
/// the app's toast queue would bury the messages that do.
final class SyncPlayEventLine: UIView {
    private let label = UILabel()
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        backgroundColor = UIColor.black.withAlphaComponent(0.62)
        clipsToBounds = true

        #if os(tvOS)
        let fontSize: CGFloat = 22, inset: CGFloat = 20, height: CGFloat = 52
        #else
        let fontSize: CGFloat = 12, inset: CGFloat = 12, height: CGFloat = 30
        #endif
        layer.cornerRadius = height / 2

        label.font = .systemFont(ofSize: fontSize, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func flash(_ text: String) {
        label.text = text
        hideWork?.cancel()
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    func cancel() {
        hideWork?.cancel()
        hideWork = nil
        alpha = 0
    }
}
