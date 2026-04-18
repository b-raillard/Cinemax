import UIKit
import AVKit

/// Optional sleep timer (15 / 30 / 45 / 60 / 90 min) that pauses the player and
/// prompts "Still watching?" when the countdown reaches zero. Runs on playback
/// start and on episode navigation.
///
/// UI is split:
/// - A moon-pill countdown indicator (bottom-left) on both platforms.
/// - The "Still watching?" prompt uses `UIAlertController` on tvOS (focus-friendly;
///   AVPlayerViewController locks its focus environment, so custom blur cards are
///   unreachable with the Siri Remote) and a custom blur card on iOS.
@MainActor
final class SleepTimerController {
    private let loc: LocalizationManager
    private let playerVCProvider: @MainActor () -> AVPlayerViewController?
    private let onStopPlayback: @MainActor () -> Void

    private var tickTask: Task<Void, Never>?
    private var endDate: Date?
    private var indicatorContainer: UIView?
    private var indicatorLabel: UILabel?
    private var overlayContainer: UIView?

    init(
        loc: LocalizationManager,
        playerVCProvider: @MainActor @escaping () -> AVPlayerViewController?,
        onStopPlayback: @MainActor @escaping () -> Void
    ) {
        self.loc = loc
        self.playerVCProvider = playerVCProvider
        self.onStopPlayback = onStopPlayback
    }

    /// Read the effective sleep-timer duration (user setting or debug override)
    /// and start a countdown if non-zero. Called on playback start, episode
    /// navigation, and "Keep watching".
    func startIfNeeded() {
        let seconds = SleepTimerOption.currentDefaultSeconds
        guard seconds > 0 else { return }
        start(seconds: seconds)
    }

    /// Stop the countdown, hide the indicator, and dismiss any active prompt.
    func teardown() {
        stopTimer()
        hideIndicator()
        hideOverlay()
    }

    // MARK: - Timer

    private func start(seconds: TimeInterval) {
        stopTimer()
        endDate = Date().addingTimeInterval(seconds)
        showIndicator()
        updateIndicator(remaining: seconds)

        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let end = self.endDate else { return }
                let remaining = end.timeIntervalSinceNow
                if remaining <= 0 {
                    self.stopTimer()
                    self.hideIndicator()
                    self.trigger()
                    return
                }
                self.updateIndicator(remaining: remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopTimer() {
        tickTask?.cancel()
        tickTask = nil
        endDate = nil
    }

    private func trigger() {
        playerVCProvider()?.player?.pause()
        showOverlay()
    }

    private func handleKeepWatching() {
        hideOverlay()
        playerVCProvider()?.player?.play()
        startIfNeeded()
    }

    private func handleStop() {
        hideOverlay()
        onStopPlayback()
    }

    // MARK: - Indicator

    private func showIndicator() {
        guard indicatorContainer == nil, let vc = playerVCProvider() else { return }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = indicatorCornerRadius
        container.clipsToBounds = true
        container.alpha = 0

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        container.addSubview(blur)

        let icon = UIImageView(image: UIImage(systemName: "moon.zzz.fill"))
        icon.tintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: indicatorFontSize, weight: .semibold)
        label.textColor = .white
        label.text = ""

        container.addSubview(icon)
        container.addSubview(label)

        let targetView = vc.view!
        targetView.addSubview(container)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indicatorPaddingH),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: indicatorIconSize),
            icon.heightAnchor.constraint(equalToConstant: indicatorIconSize),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -indicatorPaddingH),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            container.heightAnchor.constraint(equalToConstant: indicatorHeight),
        ])

        #if os(tvOS)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: targetView.safeAreaLayoutGuide.leadingAnchor, constant: 80),
            container.bottomAnchor.constraint(equalTo: targetView.safeAreaLayoutGuide.bottomAnchor, constant: -80),
        ])
        #else
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: targetView.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            container.bottomAnchor.constraint(equalTo: targetView.safeAreaLayoutGuide.bottomAnchor, constant: -80),
        ])
        #endif

        self.indicatorContainer = container
        self.indicatorLabel = label

        UIView.animate(withDuration: 0.3) { container.alpha = 1 }
    }

    private func updateIndicator(remaining: TimeInterval) {
        guard let label = indicatorLabel else { return }
        let seconds = max(0, Int(remaining.rounded(.up)))
        let hh = seconds / 3600
        let mm = (seconds % 3600) / 60
        let ss = seconds % 60
        let formatted: String
        if hh > 0 {
            formatted = String(format: "%d:%02d:%02d", hh, mm, ss)
        } else {
            formatted = String(format: "%d:%02d", mm, ss)
        }
        label.text = String(format: loc.localized("sleep.indicator"), formatted)
    }

    private func hideIndicator() {
        guard let container = indicatorContainer else { return }
        UIView.animate(withDuration: 0.25, animations: { container.alpha = 0 }) { _ in
            container.removeFromSuperview()
        }
        indicatorContainer = nil
        indicatorLabel = nil
    }

    // MARK: - Overlay prompt

    private func showOverlay() {
        #if os(tvOS)
        guard overlayContainer == nil, let vc = playerVCProvider() else { return }

        let alert = UIAlertController(
            title: loc.localized("sleep.prompt.title"),
            message: loc.localized("sleep.prompt.subtitle"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: loc.localized("sleep.prompt.keepWatching"),
            style: .default,
            handler: { [weak self] _ in
                self?.overlayContainer = nil
                self?.handleKeepWatching()
            }
        ))
        alert.addAction(UIAlertAction(
            title: loc.localized("sleep.prompt.stop"),
            style: .destructive,
            handler: { [weak self] _ in
                self?.overlayContainer = nil
                self?.handleStop()
            }
        ))

        overlayContainer = alert.view
        vc.present(alert, animated: true)
        return
        #else
        guard overlayContainer == nil, let vc = playerVCProvider() else { return }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        container.alpha = 0

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 20
        card.clipsToBounds = true

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        card.addSubview(blur)

        let icon = UIImageView(image: UIImage(systemName: "moon.zzz.fill"))
        icon.tintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: overlayTitleSize, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = loc.localized("sleep.prompt.title")

        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: overlaySubtitleSize, weight: .medium)
        subtitleLabel.textColor = .white.withAlphaComponent(0.8)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = loc.localized("sleep.prompt.subtitle")

        var keepConfig = UIButton.Configuration.plain()
        var keepTitle = AttributedString(loc.localized("sleep.prompt.keepWatching"))
        keepTitle.font = .systemFont(ofSize: overlayButtonSize, weight: .semibold)
        keepTitle.foregroundColor = UIColor.black
        keepConfig.attributedTitle = keepTitle
        keepConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        keepConfig.background.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        keepConfig.background.cornerRadius = 12

        let keepWatchingButton = UIButton(
            configuration: keepConfig,
            primaryAction: UIAction { [weak self] _ in self?.handleKeepWatching() }
        )
        keepWatchingButton.translatesAutoresizingMaskIntoConstraints = false

        var stopConfig = UIButton.Configuration.plain()
        var stopTitle = AttributedString(loc.localized("sleep.prompt.stop"))
        stopTitle.font = .systemFont(ofSize: overlayButtonSize, weight: .semibold)
        stopTitle.foregroundColor = UIColor.white
        stopConfig.attributedTitle = stopTitle
        stopConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        stopConfig.background.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        stopConfig.background.cornerRadius = 12

        let stopButton = UIButton(
            configuration: stopConfig,
            primaryAction: UIAction { [weak self] _ in self?.handleStop() }
        )
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(keepWatchingButton)
        card.addSubview(stopButton)
        container.addSubview(card)

        let targetView = vc.view!
        targetView.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: targetView.topAnchor),
            container.bottomAnchor.constraint(equalTo: targetView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: targetView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: targetView.trailingAnchor),

            card.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: overlayCardWidth),

            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 36),
            icon.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: overlayIconSize),
            icon.heightAnchor.constraint(equalToConstant: overlayIconSize),

            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            keepWatchingButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
            keepWatchingButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            keepWatchingButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            stopButton.topAnchor.constraint(equalTo: keepWatchingButton.bottomAnchor, constant: 12),
            stopButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stopButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stopButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])

        self.overlayContainer = container
        UIView.animate(withDuration: 0.3) { container.alpha = 1 }
        #endif
    }

    private func hideOverlay() {
        guard let container = overlayContainer else { return }
        #if os(tvOS)
        if let presented = playerVCProvider()?.presentedViewController {
            presented.dismiss(animated: true)
        }
        overlayContainer = nil
        return
        #else
        UIView.animate(withDuration: 0.25, animations: { container.alpha = 0 }) { _ in
            container.removeFromSuperview()
        }
        overlayContainer = nil
        #endif
    }

    // MARK: - Styling

    private var indicatorCornerRadius: CGFloat {
        #if os(tvOS)
        14
        #else
        10
        #endif
    }

    private var indicatorFontSize: CGFloat {
        #if os(tvOS)
        26
        #else
        14
        #endif
    }

    private var indicatorIconSize: CGFloat {
        #if os(tvOS)
        26
        #else
        16
        #endif
    }

    private var indicatorHeight: CGFloat {
        #if os(tvOS)
        56
        #else
        36
        #endif
    }

    private var indicatorPaddingH: CGFloat {
        #if os(tvOS)
        24
        #else
        14
        #endif
    }

    private var overlayCardWidth: CGFloat {
        #if os(tvOS)
        640
        #else
        340
        #endif
    }

    private var overlayIconSize: CGFloat {
        #if os(tvOS)
        72
        #else
        48
        #endif
    }

    private var overlayTitleSize: CGFloat {
        #if os(tvOS)
        36
        #else
        22
        #endif
    }

    private var overlaySubtitleSize: CGFloat {
        #if os(tvOS)
        22
        #else
        15
        #endif
    }

    private var overlayButtonSize: CGFloat {
        #if os(tvOS)
        24
        #else
        16
        #endif
    }
}
