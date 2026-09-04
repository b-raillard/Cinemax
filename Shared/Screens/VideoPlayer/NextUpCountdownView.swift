import UIKit

/// When the "next episode in N s" card may replace the skip-credits button.
///
/// The card counts down to the END OF THE MEDIA, because that is when
/// auto-play fires — the outro segment only says when to start showing it.
/// The two disagree whenever the segment is wrong, and plugin-detected outros
/// are wrong often enough: on a series the Intro Skipper plugin opened one 13
/// minutes before the end, and the card read « Épisode suivant dans 788 s »
/// (measured on device 2026-09-04). A count a viewer cannot read as a countdown
/// is a nag, and 788 s is not a credits sequence on any series.
///
/// So an episode's card is admitted only inside `episodeMaxSeconds` of the end;
/// before that the segment is treated like any other and the ordinary "Skip
/// credits" button stands, exactly as it does when auto-play is off. A FILM
/// reaches this only through a collection's « Tout lire », where its credits
/// can legitimately run ten minutes and the count is how long they run — no
/// cap there. Unknown kind counts as an episode: the conservative reading, and
/// the card exists for series first.
///
/// Pure and separate from the presenter for the same reason as
/// `PlaybackEndPolicy`: `VLCStreamViewController` cannot be unit-tested, this
/// decision can. Locked by `NextUpCountdownPolicyTests`.
enum NextUpCountdownPolicy {
    /// The longest count an episode's card will show. Two minutes covers a
    /// long credits sequence with a next-episode preview; anything beyond is
    /// not credits, whatever the segment says.
    static let episodeMaxSeconds: Double = 120

    static func shouldShowCard(secondsRemaining: Double, isEpisode: Bool) -> Bool {
        guard secondsRemaining > 0 else { return false }
        return isEpisode ? secondsRemaining <= episodeMaxSeconds : true
    }
}

/// Netflix-style "Next episode in Ns" card shown during the outro segment when
/// auto-play-next is armed. Self-contained leaf view (same contract style as
/// `TVScrubBar`): the presenter drives `update(secondsRemaining:)` from its 1s
/// tick and reacts to the two closures. Focusable on tvOS (custom player —
/// plain UIButtons receive focus); plain taps on iOS.
///
/// On tvOS the card wears the player's own chrome — the dark blur of the option
/// panel and the end-of-series card — and its two buttons are `.custom`
/// rows that draw their own resting fill, like `TVOptionRow`. The first version
/// used `.system` buttons with a `.filled()` configuration, and tvOS ignored
/// every colour in it: the cancel button came up in the system's blue tint and
/// the focused play button as a sharp white rectangle. Both are also pinned to
/// ONE line at a fixed width: the card used to size its buttons from their
/// intrinsic width inside a 560 pt ceiling, and « Lire maintenant » at the
/// system's tvOS button size did not fit beside « Annuler », so it wrapped
/// onto three lines (« Lire / mainte- / nant », measured on device 2026-09-04).
final class NextUpCountdownView: UIView {
    var onPlayNow: (() -> Void)?
    var onCancel: (() -> Void)?

    private let countdownLabel = UILabel()
    private let episodeLabel = UILabel()
    let playButton: UIButton
    let cancelButton: UIButton
    private let countdownFormat: String

    /// - Parameters:
    ///   - countdownFormat: localized format with one %d (seconds).
    ///   - episodeTitle: next episode's display title.
    ///   - playTitle / cancelTitle: localized button labels.
    init(countdownFormat: String, episodeTitle: String, playTitle: String, cancelTitle: String) {
        self.countdownFormat = countdownFormat
        #if os(tvOS)
        playButton = NextUpCardButton(restingFill: UIColor.white.withAlphaComponent(0.22))
        cancelButton = NextUpCardButton(restingFill: UIColor.white.withAlphaComponent(0.10))
        #else
        playButton = UIButton(type: .system)
        cancelButton = UIButton(type: .system)
        #endif
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 20
        clipsToBounds = true

        #if os(tvOS)
        // The same surface as the option panel and the end-of-series card, so
        // the three overlays this player can raise read as one family.
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        #else
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        layer.cornerRadius = 14
        #endif

        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownLabel.textColor = .white
        episodeLabel.translatesAutoresizingMaskIntoConstraints = false
        episodeLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        episodeLabel.lineBreakMode = .byTruncatingTail
        episodeLabel.text = episodeTitle

        #if os(tvOS)
        countdownLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        episodeLabel.font = .systemFont(ofSize: 24, weight: .regular)
        #else
        countdownLabel.font = .systemFont(ofSize: 16, weight: .bold)
        episodeLabel.font = .systemFont(ofSize: 13, weight: .regular)
        #endif

        Self.configure(playButton, title: playTitle, symbol: "play.fill", primary: true)
        Self.configure(cancelButton, title: cancelTitle, symbol: nil, primary: false)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addTarget(self, action: #selector(playTapped), for: .primaryActionTriggered)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .primaryActionTriggered)

        let buttons = UIStackView(arrangedSubviews: [playButton, cancelButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.axis = .horizontal

        addSubview(countdownLabel)
        addSubview(episodeLabel)
        addSubview(buttons)
        #if os(tvOS)
        // A FIXED width, and two equal buttons filling it on one line each: the
        // card's size is decided here, never by how long a localized label is.
        let pad: CGFloat = 32
        buttons.spacing = 16
        buttons.distribution = .fillEqually
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 640),
            playButton.heightAnchor.constraint(equalToConstant: 68)
        ])
        #else
        let pad: CGFloat = 16
        buttons.spacing = 12
        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])
        #endif
        NSLayoutConstraint.activate([
            countdownLabel.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            countdownLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            countdownLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            episodeLabel.topAnchor.constraint(equalTo: countdownLabel.bottomAnchor, constant: 4),
            episodeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            episodeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            buttons.topAnchor.constraint(equalTo: episodeLabel.bottomAnchor, constant: 20),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad)
        ])
        #if os(tvOS)
        buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad).isActive = true
        #endif
        isHidden = true
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// One configuration per platform. tvOS keeps the configuration to text
    /// and glyph only — colours live on the button (`NextUpCardButton`), since
    /// the system focus appearance repaints a configured button anyway and the
    /// configuration's own colours were not honoured at rest.
    private static func configure(_ button: UIButton, title: String, symbol: String?, primary: Bool) {
        #if os(tvOS)
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.titleLineBreakMode = .byTruncatingTail
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 26, weight: .semibold)
            return attributes
        }
        cfg.baseForegroundColor = .white
        if let symbol {
            cfg.image = UIImage(systemName: symbol,
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
            cfg.imagePadding = 12
        }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)
        button.configuration = cfg
        #else
        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .capsule
        cfg.title = title
        if primary {
            cfg.baseBackgroundColor = .white
            cfg.baseForegroundColor = .black
        } else {
            cfg.baseBackgroundColor = UIColor.white.withAlphaComponent(0.18)
            cfg.baseForegroundColor = .white
        }
        if let symbol {
            cfg.image = UIImage(systemName: symbol)
            cfg.imagePadding = 6
        }
        button.configuration = cfg
        #endif
    }

    func update(secondsRemaining: Int) {
        countdownLabel.text = String(format: countdownFormat, max(0, secondsRemaining))
    }

    func show() {
        guard isHidden else { return }
        isHidden = false
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
    }

    func hide() {
        guard !isHidden else { return }
        UIView.animate(withDuration: 0.2) { self.alpha = 0 } completion: { _ in
            self.isHidden = true
        }
    }

    @objc private func playTapped() { onPlayNow?() }
    @objc private func cancelTapped() { onCancel?() }
}

#if os(tvOS)
/// A card button. A `.custom` button gets no system focus appearance (see
/// `ChapterChip`), so it draws both states itself: a translucent capsule at
/// rest, a white capsule with a dark label under focus — the same white lift
/// every other focused control in this player shows, so the card does not
/// invent a third look for it.
private final class NextUpCardButton: UIButton {
    private let restingFill: UIColor

    init(restingFill: UIColor) {
        self.restingFill = restingFill
        super.init(frame: .zero)
        backgroundColor = restingFill
        // The label goes dark on the white focused fill. Done through the
        // configuration rather than left to the system: whether tvOS repaints
        // a `.custom` button's foreground on focus is not something to bet
        // white-on-white text on.
        configurationUpdateHandler = { button in
            guard var cfg = button.configuration else { return }
            cfg.baseForegroundColor = button.isFocused ? .black : .white
            button.configuration = cfg
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        setNeedsUpdateConfiguration()
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = self.isFocused ? UIColor.white.withAlphaComponent(0.9) : self.restingFill
        })
    }
}
#endif
