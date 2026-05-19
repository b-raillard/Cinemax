#if os(iOS)
import UIKit
import SwiftUI
import SwiftVLC
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "VLCPlayback")

/// Plays offline files AVKit can't demux (MKV / AVI / WebM / HEVC-in-Matroska)
/// using libVLC (SwiftVLC / libVLC 4.0). Same role `NativeVideoPresenter`
/// plays for streaming — instantiate, call `present(localURL:)`, lifetime is
/// managed by the modal it puts up.
///
/// Built deliberately small: a black-background view controller, a tap-to-
/// toggle controls overlay, scrubber + time labels, a Done button, and (now,
/// for free via SwiftVLC) a Picture-in-Picture button.
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

// MARK: - SwiftUI rendering surface (libVLC pixel-buffer → AVKit PiP)

@MainActor
private struct OfflineEngineSurface: View {
    let player: Player
    var onController: (AnyObject?) -> Void = { _ in }
    @State private var controller: PiPController?

    var body: some View {
        PiPVideoView(player, controller: Binding(
            get: { controller },
            set: { controller = $0; onController($0) }
        ))
    }
}

// MARK: - View controller

private final class VLCPlayerViewController: UIViewController {
    private let localURL: URL
    private let titleText: String
    private let startTime: Double?
    private let loc: LocalizationManager
    private let onDismiss: (() -> Void)?

    private let player = Player()
    private let videoView = UIView()
    private var videoHost: UIViewController?
    private var eventsTask: Task<Void, Never>?
    private var pipController: PiPController?
    private let controlsContainer = UIView()
    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let durationLabel = UILabel()

    /// Hides the chrome after 3 s of no interaction. Tap restores it.
    private var hideControlsWorkItem: DispatchWorkItem?
    /// Once the first time event reports a non-zero length we know the media
    /// is loaded; only then is it safe to seek to `startTime`. Done once.
    private var didSeekToStart = false
    private var isScrubbing = false
    private var isTearingDown = false
    private var lastPlayStart = Date.distantPast
    /// Latest media length in ms (SwiftVLC `duration` can lag `.lengthChanged`).
    private var mediaLengthMs: Int32 = 0

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
        if isBeingDismissed {
            isTearingDown = true
            eventsTask?.cancel()
            eventsTask = nil
            pipController = nil
            player.stop()
            hideControlsWorkItem?.cancel()
            onDismiss?()
        }
    }

    // MARK: - Engine bridge (SwiftVLC)

    private var currentMs: Int32 {
        let c = player.currentTime.components
        return Int32(clamping: Int(c.seconds) * 1000
            + Int(c.attoseconds / 1_000_000_000_000_000))
    }
    private var lengthMs: Int32 { mediaLengthMs }
    private var enginePlaying: Bool { player.state == .playing }

    private func engineSeek(ms: Int32) {
        player.seek(to: .milliseconds(Int(max(0, ms))))
    }

    private func startEventLoop() {
        guard eventsTask == nil else { return }
        eventsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.player.events {
                switch event {
                case .lengthChanged(let d):
                    let c = d.components
                    self.mediaLengthMs = Int32(clamping: Int(c.seconds) * 1000
                        + Int(c.attoseconds / 1_000_000_000_000_000))
                case .timeChanged:
                    self.onEngineTimeChanged()
                case .stateChanged(let state):
                    self.onEngineStateChanged(state)
                case .encounteredError:
                    logger.error("VLC offline error for \(self.localURL.lastPathComponent, privacy: .public)")
                    self.dismiss(animated: true)
                default:
                    break
                }
            }
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

        let surface = OfflineEngineSurface(player: player) { [weak self] controller in
            self?.pipController = controller as? PiPController
        }
        let host = UIHostingController(rootView: surface)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        videoView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: videoView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: videoView.bottomAnchor)
        ])
        host.didMove(toParent: self)
        videoHost = host
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

        // PiP button (top-right)
        var pipConfig = UIButton.Configuration.plain()
        pipConfig.image = UIImage(systemName: "pip.enter",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        pipConfig.baseForegroundColor = .white
        pipButton.configuration = pipConfig
        pipButton.accessibilityLabel = loc.localized("player.pip")
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        pipButton.addTarget(self, action: #selector(pipTapped), for: .touchUpInside)
        controlsContainer.addSubview(pipButton)

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
            pipButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            pipButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: doneButton.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pipButton.leadingAnchor, constant: -16),

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
        guard let media = try? Media(url: localURL) else {
            logger.error("VLC offline: failed to open \(self.localURL.lastPathComponent, privacy: .public)")
            dismiss(animated: true)
            return
        }
        // File-cache option speeds up scrubbing through large MKV files; VLC's
        // default makes the slider feel laggy on multi-GB downloads.
        media.addOption(":file-caching=3000")
        startEventLoop()
        lastPlayStart = Date()
        try? player.play(media)
    }

    // MARK: - Controls

    @objc private func doneTapped() {
        player.stop()
        dismiss(animated: true)
    }

    @objc private func pipTapped() {
        guard let pip = pipController, pip.isPossible else { return }
        pip.toggle()
    }

    @objc private func playPauseTapped() {
        if enginePlaying {
            player.pause()
            setPlayPauseIcon(playing: false)
        } else {
            player.resume()
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

    @objc private func scrubberChanged() {
        isScrubbing = true
        let length = lengthMs
        guard length > 0 else { return }
        let targetMs = Int32(Float(length) * slider.value)
        timeLabel.text = Self.formatMs(targetMs)
    }

    @objc private func scrubberDone() {
        let length = lengthMs
        guard length > 0 else { isScrubbing = false; return }
        engineSeek(ms: Int32(Float(length) * slider.value))
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

    // MARK: - Engine events (was VLCMediaPlayerDelegate)

    private func onEngineStateChanged(_ state: PlayerState) {
        switch state {
        case .error:
            logger.error("VLC media player entered error state for \(self.localURL.lastPathComponent, privacy: .public)")
            dismiss(animated: true)
        case .stopped:
            // libVLC 4.0 has no distinct `.ended`; treat a near-end stop that
            // isn't teardown / a fresh start as end-of-media.
            guard !isTearingDown,
                  Date().timeIntervalSince(lastPlayStart) > 1.0,
                  lengthMs > 0, currentMs >= lengthMs - 2000 else { return }
            dismiss(animated: true)
        case .paused:
            setPlayPauseIcon(playing: false)
        case .playing:
            setPlayPauseIcon(playing: true)
        default:
            break
        }
    }

    private func onEngineTimeChanged() {
        guard !isScrubbing else { return }
        let cur = currentMs
        let len = lengthMs
        timeLabel.text = Self.formatMs(cur)
        durationLabel.text = Self.formatMs(len)
        if len > 0 {
            slider.value = Float(cur) / Float(len)
        }
        if !didSeekToStart, let start = startTime, start > 0, len > 0 {
            didSeekToStart = true
            engineSeek(ms: Int32(start * 1000))
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
