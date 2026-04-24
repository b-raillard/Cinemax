import UIKit
import AVKit

/// Shows a "You finished {Series Name}" overlay when the last episode of a
/// series ends with autoplay on. Gives the user a concrete completion moment
/// rather than the player sitting at the end.
///
/// Platform split mirrors `SleepTimerController`'s "Still watching?" prompt:
/// - tvOS uses `UIAlertController` because `AVPlayerViewController` locks its
///   focus environment and custom subviews aren't reachable with the Siri Remote.
/// - iOS uses a custom blur-card overlay (no focus concerns, prettier visuals).
@MainActor
final class EndOfSeriesOverlayController {
    private let loc: LocalizationManager
    private let playerVCProvider: @MainActor () -> AVPlayerViewController?
    private let onDone: @MainActor () -> Void

    private var overlay: UIView?

    init(
        loc: LocalizationManager,
        playerVCProvider: @MainActor @escaping () -> AVPlayerViewController?,
        onDone: @MainActor @escaping () -> Void
    ) {
        self.loc = loc
        self.playerVCProvider = playerVCProvider
        self.onDone = onDone
    }

    func show(seriesName: String) {
        guard overlay == nil, let vc = playerVCProvider() else { return }

        #if os(tvOS)
        // Same focus-engine reasoning as sleep-timer overlay — UIAlertController
        // owns its own focus context so the Done button is reachable with the remote.
        let alert = UIAlertController(
            title: String(format: loc.localized("player.finishedSeries.title"), seriesName),
            message: loc.localized("player.finishedSeries.subtitle"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: loc.localized("player.finishedSeries.done"),
            style: .default,
            handler: { [weak self] _ in
                guard let self else { return }
                self.overlay = nil
                self.onDone()
            }
        ))
        overlay = alert.view
        vc.present(alert, animated: true)
        #else
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        container.alpha = 0

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 20
        card.clipsToBounds = true

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        card.addSubview(blur)

        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = .systemGreen
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: Style.titleSize, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = String(format: loc.localized("player.finishedSeries.title"), seriesName)

        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: Style.subtitleSize, weight: .medium)
        subtitleLabel.textColor = .white.withAlphaComponent(0.8)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = loc.localized("player.finishedSeries.subtitle")

        var doneConfig = UIButton.Configuration.plain()
        var doneTitle = AttributedString(loc.localized("player.finishedSeries.done"))
        doneTitle.font = .systemFont(ofSize: Style.buttonSize, weight: .semibold)
        doneTitle.foregroundColor = UIColor.black
        doneConfig.attributedTitle = doneTitle
        doneConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        doneConfig.background.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        doneConfig.background.cornerRadius = 12

        let doneButton = UIButton(
            configuration: doneConfig,
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.hide()
                self.onDone()
            }
        )
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(doneButton)
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
            card.widthAnchor.constraint(equalToConstant: Style.cardWidth),

            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 36),
            icon.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: Style.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Style.iconSize),

            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            doneButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
            doneButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            doneButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])

        overlay = container

        UIView.animate(withDuration: 0.3) { container.alpha = 1 }
        #endif
    }

    func hide() {
        guard let container = overlay else { return }
        #if os(tvOS)
        if let presented = playerVCProvider()?.presentedViewController {
            presented.dismiss(animated: true)
        }
        overlay = nil
        #else
        UIView.animate(withDuration: 0.25, animations: { container.alpha = 0 }) { _ in
            container.removeFromSuperview()
        }
        overlay = nil
        #endif
    }

    /// Called from the presenter's cleanup path. Fast — just drops the retain.
    func teardown() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    // MARK: - Style

    /// Platform-adaptive sizing. Values match the originals in the presenter.
    private enum Style {
        static var cardWidth: CGFloat {
            #if os(tvOS)
            640
            #else
            340
            #endif
        }
        static var iconSize: CGFloat {
            #if os(tvOS)
            72
            #else
            48
            #endif
        }
        static var titleSize: CGFloat {
            #if os(tvOS)
            36
            #else
            22
            #endif
        }
        static var subtitleSize: CGFloat {
            #if os(tvOS)
            22
            #else
            15
            #endif
        }
        static var buttonSize: CGFloat {
            #if os(tvOS)
            24
            #else
            16
            #endif
        }
    }
}
