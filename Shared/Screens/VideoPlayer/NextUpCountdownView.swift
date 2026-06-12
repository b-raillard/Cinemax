import UIKit

/// Netflix-style "Next episode in Ns" card shown during the outro segment when
/// auto-play-next is armed. Self-contained leaf view (same contract style as
/// `TVScrubBar`): the presenter drives `update(secondsRemaining:)` from its 1s
/// tick and reacts to the two closures. Focusable on tvOS (custom player —
/// plain UIButtons receive focus); plain taps on iOS.
final class NextUpCountdownView: UIView {
    var onPlayNow: (() -> Void)?
    var onCancel: (() -> Void)?

    private let countdownLabel = UILabel()
    private let episodeLabel = UILabel()
    let playButton = UIButton(type: .system)
    let cancelButton = UIButton(type: .system)
    private let countdownFormat: String

    /// - Parameters:
    ///   - countdownFormat: localized format with one %d (seconds).
    ///   - episodeTitle: next episode's display title.
    ///   - playTitle / cancelTitle: localized button labels.
    init(countdownFormat: String, episodeTitle: String, playTitle: String, cancelTitle: String) {
        self.countdownFormat = countdownFormat
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        layer.cornerRadius = 14
        clipsToBounds = true

        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownLabel.textColor = .white
        episodeLabel.translatesAutoresizingMaskIntoConstraints = false
        episodeLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        episodeLabel.lineBreakMode = .byTruncatingTail
        episodeLabel.text = episodeTitle

        #if os(tvOS)
        countdownLabel.font = .systemFont(ofSize: 28, weight: .bold)
        episodeLabel.font = .systemFont(ofSize: 22, weight: .regular)
        #else
        countdownLabel.font = .systemFont(ofSize: 16, weight: .bold)
        episodeLabel.font = .systemFont(ofSize: 13, weight: .regular)
        #endif

        var playCfg = UIButton.Configuration.filled()
        playCfg.cornerStyle = .capsule
        playCfg.baseBackgroundColor = .white
        playCfg.baseForegroundColor = .black
        playCfg.title = playTitle
        playCfg.image = UIImage(systemName: "play.fill")
        playCfg.imagePadding = 6
        playButton.configuration = playCfg
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addTarget(self, action: #selector(playTapped), for: .primaryActionTriggered)

        var cancelCfg = UIButton.Configuration.filled()
        cancelCfg.cornerStyle = .capsule
        cancelCfg.baseBackgroundColor = UIColor.white.withAlphaComponent(0.18)
        cancelCfg.baseForegroundColor = .white
        cancelCfg.title = cancelTitle
        cancelButton.configuration = cancelCfg
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .primaryActionTriggered)

        let buttons = UIStackView(arrangedSubviews: [playButton, cancelButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.axis = .horizontal
        buttons.spacing = 12

        addSubview(countdownLabel)
        addSubview(episodeLabel)
        addSubview(buttons)
        #if os(tvOS)
        let pad: CGFloat = 32
        let maxW: CGFloat = 560
        #else
        let pad: CGFloat = 16
        let maxW: CGFloat = 320
        #endif
        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: maxW),
            countdownLabel.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            countdownLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            countdownLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            episodeLabel.topAnchor.constraint(equalTo: countdownLabel.bottomAnchor, constant: 4),
            episodeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            episodeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            buttons.topAnchor.constraint(equalTo: episodeLabel.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad)
        ])
        isHidden = true
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

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
