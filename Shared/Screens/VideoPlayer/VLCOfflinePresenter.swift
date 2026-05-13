#if os(iOS)
import UIKit
import VLCKitSPM
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "VLCPlayback")

/// Plays offline files AVKit can't demux (MKV / AVI / WebM / HEVC-in-Matroska)
/// using libVLC. Same role `NativeVideoPresenter` plays for streaming —
/// instantiate, call `present(localURL:title:startTime:)`, lifetime is
/// managed by the modal it puts up.
///
/// Built deliberately small: a black-background view controller, a tap-to-
/// toggle controls overlay, scrubber + time labels, and a Done button. The
/// rich AVKit chrome (subtitles UI, chapter markers, sleep timer prompt) is
/// out of scope here — the VLC path exists so the file *plays at all*, and
/// users with AVKit-compatible libraries still get the polished AVPlayer
/// experience.
@MainActor
final class VLCOfflinePresenter: NSObject {
    private let title: String
    private let startTime: Double?
    private let loc: LocalizationManager
    private let onDismiss: (() -> Void)?

    private weak var hostingVC: VLCPlayerViewController?

    init(title: String, startTime: Double?, loc: LocalizationManager, onDismiss: (() -> Void)?) {
        self.title = title
        self.startTime = startTime
        self.loc = loc
        self.onDismiss = onDismiss
    }

    /// Presents the player modally on top of the active scene. Plays
    /// immediately; the controls overlay autohides after 3 s of inactivity.
    func present(localURL: URL) {
        guard let topVC = Self.topMostViewController() else {
            logger.error("VLC present: no top VC found")
            onDismiss?()
            return
        }
        let vc = VLCPlayerViewController(localURL: localURL, title: title, startTime: startTime, loc: loc, onDismiss: onDismiss)
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        hostingVC = vc
        topVC.present(vc, animated: true)
    }

    // MARK: - Helpers

    private static func topMostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        var top: UIViewController = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - View controller

private final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate {
    private let localURL: URL
    private let titleText: String
    private let startTime: Double?
    private let loc: LocalizationManager
    private let onDismiss: (() -> Void)?

    private let mediaPlayer = VLCMediaPlayer()
    private let videoView = UIView()
    private let controlsContainer = UIView()
    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let durationLabel = UILabel()

    /// Hides the chrome after 3 s of no interaction. Tap restores it.
    private var hideControlsWorkItem: DispatchWorkItem?
    /// Once the first time observer reports a non-zero position we know the
    /// media is loaded; only then is it safe to seek to `startTime`.
    private var didSeekToStart = false

    init(localURL: URL, title: String, startTime: Double?, loc: LocalizationManager, onDismiss: (() -> Void)?) {
        self.localURL = localURL
        self.titleText = title
        self.startTime = startTime
        self.loc = loc
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideoView()
        setupControls()
        setupGestures()
        startPlayback()
        scheduleHideControls()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        mediaPlayer.stop()
        mediaPlayer.delegate = nil
        hideControlsWorkItem?.cancel()
        if isBeingDismissed {
            onDismiss?()
        }
    }

    // MARK: - UI setup

    private func setupVideoView() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.backgroundColor = .black
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        mediaPlayer.drawable = videoView
    }

    private func setupControls() {
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.backgroundColor = .black.withAlphaComponent(0.45)
        view.addSubview(controlsContainer)
        NSLayoutConstraint.activate([
            controlsContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsContainer.topAnchor.constraint(equalTo: view.topAnchor),
            controlsContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Done button
        var doneConfig = UIButton.Configuration.plain()
        doneConfig.title = loc.localized("action.done")
        doneConfig.baseForegroundColor = .white
        doneButton.configuration = doneConfig
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        controlsContainer.addSubview(doneButton)

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = titleText
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        controlsContainer.addSubview(titleLabel)

        // Play/pause centre button
        var playConfig = UIButton.Configuration.plain()
        playConfig.image = UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .bold))
        playConfig.baseForegroundColor = .white
        playPauseButton.configuration = playConfig
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        controlsContainer.addSubview(playPauseButton)

        // Bottom bar: scrubber + time labels
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.addTarget(self, action: #selector(scrubberChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubberDone), for: [.touchUpInside, .touchUpOutside])
        controlsContainer.addSubview(slider)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.text = "0:00"
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .white
        controlsContainer.addSubview(timeLabel)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.text = "0:00"
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        durationLabel.textColor = .white
        controlsContainer.addSubview(durationLabel)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            doneButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            doneButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: doneButton.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),

            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            timeLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            timeLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
            durationLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            durationLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
            slider.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -12),
            slider.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor)
        ])
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        // Tap on the video itself toggles chrome — gestures on the controls
        // (buttons / slider) win because UIControl consumes touches first.
        videoView.addGestureRecognizer(tap)
        videoView.isUserInteractionEnabled = true
    }

    // MARK: - Playback

    private func startPlayback() {
        let media = VLCMedia(url: localURL)
        // File-cache option speeds up scrubbing through large MKV files; VLC's
        // default (300 ms) makes the slider feel laggy on multi-GB downloads.
        media.addOption(":file-caching=3000")
        mediaPlayer.media = media
        mediaPlayer.delegate = self
        mediaPlayer.play()
    }

    // MARK: - Controls

    @objc private func doneTapped() {
        mediaPlayer.stop()
        dismiss(animated: true)
    }

    @objc private func playPauseTapped() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
            setPlayPauseIcon(playing: false)
        } else {
            mediaPlayer.play()
            setPlayPauseIcon(playing: true)
        }
        scheduleHideControls()
    }

    @objc private func viewTapped() {
        if controlsContainer.alpha > 0 {
            hideControlsImmediately()
        } else {
            showControls()
            scheduleHideControls()
        }
    }

    /// Tracks whether the user is actively dragging the scrubber so the
    /// playback time observer doesn't fight their thumb.
    private var isScrubbing = false

    @objc private func scrubberChanged() {
        isScrubbing = true
        let length = mediaPlayer.media?.length.intValue ?? 0
        guard length > 0 else { return }
        let targetMs = Int32(Float(length) * slider.value)
        // Live time label update for nicer feedback during drag.
        timeLabel.text = Self.formatMs(targetMs)
    }

    @objc private func scrubberDone() {
        let length = mediaPlayer.media?.length.intValue ?? 0
        guard length > 0 else { isScrubbing = false; return }
        let target = VLCTime(int: Int32(Float(length) * slider.value))
        mediaPlayer.time = target
        isScrubbing = false
        scheduleHideControls()
    }

    private func setPlayPauseIcon(playing: Bool) {
        var config = playPauseButton.configuration ?? UIButton.Configuration.plain()
        config.image = UIImage(systemName: playing ? "pause.fill" : "play.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .bold))
        playPauseButton.configuration = config
    }

    // MARK: - Auto-hide chrome

    private func scheduleHideControls() {
        hideControlsWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideControlsImmediately() }
        hideControlsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func hideControlsImmediately() {
        UIView.animate(withDuration: 0.25) {
            self.controlsContainer.alpha = 0
        }
    }

    private func showControls() {
        UIView.animate(withDuration: 0.2) {
            self.controlsContainer.alpha = 1
        }
    }

    // MARK: - VLCMediaPlayerDelegate

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = self.mediaPlayer.state
            switch state {
            case .error:
                logger.error("VLC media player entered error state for \(self.localURL.lastPathComponent, privacy: .public)")
                self.dismiss(animated: true)
            case .ended:
                self.dismiss(animated: true)
            case .paused:
                self.setPlayPauseIcon(playing: false)
            case .playing:
                self.setPlayPauseIcon(playing: true)
            default:
                break
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.isScrubbing else { return }
            let currentMs = self.mediaPlayer.time.intValue
            let lengthMs = self.mediaPlayer.media?.length.intValue ?? 0
            self.timeLabel.text = Self.formatMs(currentMs)
            self.durationLabel.text = Self.formatMs(lengthMs)
            if lengthMs > 0 {
                self.slider.value = Float(currentMs) / Float(lengthMs)
            }
            // Seek to the requested start once VLC has populated `length` and
            // we can trust the seekability. Done exactly once per session.
            if !self.didSeekToStart, let start = self.startTime, start > 0, lengthMs > 0 {
                self.didSeekToStart = true
                self.mediaPlayer.time = VLCTime(int: Int32(start * 1000))
            }
        }
    }

    // MARK: - Format

    private static func formatMs(_ ms: Int32) -> String {
        let total = Int(max(0, ms) / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
#endif
