import UIKit
import AVKit
import AVFoundation
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Playback.Skip")

/// Drives the Skip Intro / Skip Credits affordance.
///
/// Pure time-based UX: the skip button is visible iff `currentTime ∈ segment`.
/// No "already skipped" memory — if the user rewinds back into a segment, the
/// button reappears.
///
/// Platform split (see `showSkipButton` / `hideSkipButton`):
/// - iOS: a floating `UIButton` added directly to `AVPlayerViewController.view`.
///   Touch reaches it natively.
/// - tvOS: the native `AVPlayerViewController.contextualActions` API. It's the
///   only mechanism that produces a focusable action button that coexists with
///   the transport-bar focus context.
@MainActor
final class SkipSegmentController {
    private let apiClient: any APIClientProtocol
    private let loc: LocalizationManager
    private let playerVCProvider: @MainActor () -> AVPlayerViewController?

    private var segments: [MediaSegmentDto] = []
    private var activeSegmentType: MediaSegmentType?
    private var fetchTask: Task<Void, Never>?

    #if os(iOS)
    private var skipButton: UIButton?
    #endif

    init(
        apiClient: any APIClientProtocol,
        loc: LocalizationManager,
        playerVCProvider: @MainActor @escaping () -> AVPlayerViewController?
    ) {
        self.apiClient = apiClient
        self.loc = loc
        self.playerVCProvider = playerVCProvider
    }

    /// Load segments for a given episode/movie. Cancels any in-flight fetch,
    /// clears previous segments and hides the button.
    func load(for itemId: String) {
        teardown()
        let client = apiClient
        fetchTask = Task { [weak self] in
            do {
                let fetched = try await client.getMediaSegments(
                    itemId: itemId,
                    includeSegmentTypes: [.intro, .outro]
                )
                guard !Task.isCancelled else { return }
                self?.segments = fetched
            } catch {
                logger.info("Media segments unavailable for \(itemId): \(error.localizedDescription)")
            }
        }
    }

    /// Call once per second from the presenter's shared time observer.
    /// Shows / hides the button based on whether `currentTime` is inside any
    /// intro / outro segment. Re-entry is allowed.
    func onTick(currentTime: Double) {
        for segment in segments {
            let start = Double(segment.startTicks ?? 0) / 10_000_000
            let end = Double(segment.endTicks ?? 0) / 10_000_000
            guard end > start else { continue }

            if currentTime >= start && currentTime < end - 1 {
                if activeSegmentType != segment.type {
                    activeSegmentType = segment.type
                    showSkipButton(for: segment)
                }
                return
            }
        }

        if activeSegmentType != nil {
            activeSegmentType = nil
            hideSkipButton()
        }
    }

    /// Cancel in-flight fetch, clear segments, hide the button.
    func teardown() {
        fetchTask?.cancel()
        fetchTask = nil
        segments = []
        activeSegmentType = nil
        hideSkipButton()
    }

    // MARK: - Button rendering

    private func showSkipButton(for segment: MediaSegmentDto) {
        guard let vc = playerVCProvider() else { return }

        let title: String
        switch segment.type {
        case .intro:
            title = loc.localized("player.skipIntro")
        case .outro:
            title = loc.localized("player.skipCredits")
        default:
            return
        }

        let endSeconds = Double(segment.endTicks ?? 0) / 10_000_000

        #if os(tvOS)
        let action = UIAction(
            title: title,
            image: UIImage(systemName: "forward.fill")
        ) { [weak self] _ in
            guard let player = self?.playerVCProvider()?.player else { return }
            player.seek(
                to: CMTime(seconds: endSeconds, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
        }
        vc.contextualActions = [action]
        #else
        hideSkipButton() // idempotent

        var config = UIButton.Configuration.plain()
        var attrTitle = AttributedString("  \(title)  ▶▶")
        attrTitle.font = .systemFont(ofSize: buttonFontSize, weight: .semibold)
        attrTitle.foregroundColor = UIColor.white
        config.attributedTitle = attrTitle
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: buttonPaddingH, bottom: 0, trailing: buttonPaddingH)

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = buttonCornerRadius
        blur.clipsToBounds = true
        config.background.customView = blur
        config.background.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        config.background.cornerRadius = buttonCornerRadius

        let action = UIAction { [weak self] _ in
            guard let player = self?.playerVCProvider()?.player else { return }
            player.seek(
                to: CMTime(seconds: endSeconds, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
        }
        let button = UIButton(configuration: config, primaryAction: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alpha = 0
        self.skipButton = button

        let targetView = vc.view!
        targetView.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: targetView.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: targetView.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        UIView.animate(withDuration: 0.3) { button.alpha = 1 }
        #endif
    }

    private func hideSkipButton() {
        #if os(tvOS)
        playerVCProvider()?.contextualActions = []
        #else
        guard let button = skipButton else { return }
        UIView.animate(withDuration: 0.25, animations: { button.alpha = 0 }) { _ in
            button.removeFromSuperview()
        }
        skipButton = nil
        #endif
    }

    // MARK: - Button styling

    private var buttonFontSize: CGFloat {
        #if os(tvOS)
        28
        #else
        16
        #endif
    }

    private var buttonCornerRadius: CGFloat {
        #if os(tvOS)
        14
        #else
        10
        #endif
    }

    private var buttonPaddingH: CGFloat {
        #if os(tvOS)
        32
        #else
        20
        #endif
    }
}
