import UIKit
import VLCKitSPM
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "VLCPlayback")

/// Online VLC player (iOS + tvOS). VLC DirectPlays the raw Jellyfin file
/// (MKV / HEVC 10-bit / Dolby Vision) so the server performs **no transcode** —
/// eliminating the slow-transcode segment thrash that froze `AVPlayer`.
///
/// Parity: playback + resume, Jellyfin progress reporting, episode prev/next +
/// auto-play-next, audio/subtitle selection, skip intro/outro, sleep timer +
/// still-watching, end-of-series overlay, chapter navigation, single error
/// retry. AirPlay/PiP are AVKit-only (iOS native path), out of scope here.
@MainActor
final class VLCStreamPresenter: NSObject {
    private let title: String
    private let startTime: Double?
    private let loc: LocalizationManager
    private let apiClient: any PlaybackAPI & LibraryAPI
    private let userId: String
    private let autoPlayNext: Bool
    private let previousEpisode: EpisodeRef?
    private let nextEpisode: EpisodeRef?
    private let episodeNavigator: EpisodeNavigator?
    private let onDismiss: (() -> Void)?

    private weak var hostingVC: VLCStreamViewController?

    init(
        itemId: String,
        title: String,
        startTime: Double?,
        previousEpisode: EpisodeRef?,
        nextEpisode: EpisodeRef?,
        episodeNavigator: EpisodeNavigator?,
        apiClient: any PlaybackAPI & LibraryAPI,
        userId: String,
        autoPlayNext: Bool,
        loc: LocalizationManager,
        onDismiss: (() -> Void)?
    ) {
        self.title = title
        self.startTime = startTime
        self.previousEpisode = previousEpisode
        self.nextEpisode = nextEpisode
        self.episodeNavigator = episodeNavigator
        self.apiClient = apiClient
        self.userId = userId
        self.autoPlayNext = autoPlayNext
        self.loc = loc
        self.onDismiss = onDismiss
        self._initialItemId = itemId
    }

    private let _initialItemId: String

    /// Presents modally on top of the active scene and starts playback.
    func present(info: PlaybackInfo) {
        guard let topVC = Self.topMostViewController() else {
            logger.error("VLC stream present: no top VC found")
            onDismiss?()
            return
        }
        let vc = VLCStreamViewController(
            itemId: _initialItemId, info: info, title: title, startTime: startTime,
            previousEpisode: previousEpisode, nextEpisode: nextEpisode,
            episodeNavigator: episodeNavigator, apiClient: apiClient, userId: userId,
            autoPlayNext: autoPlayNext, loc: loc, onDismiss: onDismiss
        )
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        hostingVC = vc
        topVC.present(vc, animated: true)
    }

    // MARK: - Helpers

    /// libVLC can't reliably inject arbitrary HTTP headers across versions, so
    /// authenticate via Jellyfin's accepted `api_key` query param instead of the
    /// `Authorization: MediaBrowser Token=…` header AVURLAsset uses.
    static func authedURL(_ url: URL, token: String?) -> URL {
        guard let token, !token.isEmpty,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name.lowercased() == "api_key" }) {
            items.append(URLQueryItem(name: "api_key", value: token))
        }
        comps.queryItems = items
        return comps.url ?? url
    }

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

private final class VLCStreamViewController: UIViewController, VLCMediaPlayerDelegate {
    // Mutable across episode navigation.
    private var itemId: String
    private var info: PlaybackInfo
    private var previousEpisode: EpisodeRef?
    private var nextEpisode: EpisodeRef?
    private var startTime: Double?

    private let titleText: String
    private let episodeNavigator: EpisodeNavigator?
    private let apiClient: any PlaybackAPI & LibraryAPI
    private let userId: String
    private let autoPlayNext: Bool
    private let loc: LocalizationManager
    private let onDismiss: (() -> Void)?

    private let mediaPlayer = VLCMediaPlayer()
    private let videoView = UIView()
    private let controlsContainer = UIView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let durationLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let skipHUD = UILabel()
    #if os(iOS)
    private let doneButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let tracksButton = UIButton(type: .system)
    private let slider = UISlider()
    private var isScrubbing = false
    #else
    // tvOS custom transport: a focusable scrub bar + a focusable control row.
    private let tvScrub = TVScrubBar()
    private let controlBar = UIStackView()
    private let tvPlayButton = UIButton(type: .system)
    private let tvAudioButton = UIButton(type: .system)
    private let tvSubtitleButton = UIButton(type: .system)
    private let tvChaptersButton = UIButton(type: .system)
    private let tvPrevButton = UIButton(type: .system)
    private let tvNextButton = UIButton(type: .system)
    private var skipHUDHide: DispatchWorkItem?
    #endif

    private var reporter: PlaybackReporter?
    private let remoteCommands: RemoteCommandController
    private var progressTimer: Timer?
    private var hideControlsWorkItem: DispatchWorkItem?
    private var didSeekToStart = false

    // P3: skip intro/outro
    private var segments: [MediaSegmentDto] = []
    private var segmentFetchTask: Task<Void, Never>?
    private var activeSegmentType: MediaSegmentType?
    private let skipButton = UIButton(type: .system)

    // P3: sleep timer
    private var sleepRemaining: TimeInterval = 0
    private var sleepActive = false

    // P3: end-of-series / error
    private var didReportEnd = false
    private var didRetry = false

    init(
        itemId: String, info: PlaybackInfo, title: String, startTime: Double?,
        previousEpisode: EpisodeRef?, nextEpisode: EpisodeRef?,
        episodeNavigator: EpisodeNavigator?, apiClient: any PlaybackAPI & LibraryAPI,
        userId: String, autoPlayNext: Bool, loc: LocalizationManager,
        onDismiss: (() -> Void)?
    ) {
        self.itemId = itemId
        self.info = info
        self.titleText = title
        self.startTime = startTime
        self.previousEpisode = previousEpisode
        self.nextEpisode = nextEpisode
        self.episodeNavigator = episodeNavigator
        self.apiClient = apiClient
        self.userId = userId
        self.autoPlayNext = autoPlayNext
        self.loc = loc
        self.onDismiss = onDismiss
        var navTarget: ((EpisodeRef) -> Void)?
        self.remoteCommands = RemoteCommandController(onNavigate: { ref in navTarget?(ref) })
        super.init(nibName: nil, bundle: nil)
        navTarget = { [weak self] ref in self?.navigateToEpisode(ref) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideoView()
        setupControls()
        setupSkipButton()
        setupGestures()
        setupReporter()
        startPlayback()
        scheduleHideControls()
    }

    #if os(iOS)
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    #endif

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed {
            reporter?.reportStop()
            teardown()
            onDismiss?()
        }
    }

    private func teardown() {
        progressTimer?.invalidate()
        progressTimer = nil
        remoteCommands.detach()
        hideControlsWorkItem?.cancel()
        mediaPlayer.stop()
        mediaPlayer.delegate = nil
    }

    // MARK: - Reporter

    private func setupReporter() {
        reporter = PlaybackReporter(
            apiClient: apiClient,
            userId: userId,
            context: { [weak self] in
                guard let self else { return nil }
                return PlaybackReporter.Context(itemId: self.itemId, info: self.info, player: nil)
            },
            timeSource: { [weak self] in
                guard let self else { return (0, true) }
                return (Double(self.mediaPlayer.time.intValue) / 1000.0, !self.mediaPlayer.isPlaying)
            }
        )
        let center = remoteCommands
        center.attach(previous: previousEpisode, next: nextEpisode, hasNavigator: episodeNavigator != nil)
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onSecondTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
    }

    /// Single 1 s heartbeat: progress reporting + skip-segment check + sleep countdown.
    private func onSecondTick() {
        reporter?.onTick()
        let now = Double(mediaPlayer.time.intValue) / 1000.0
        updateSkipButton(currentTime: now)
        if sleepActive {
            sleepRemaining -= 1
            if sleepRemaining <= 0 { fireSleepTimer() }
        }
    }

    // MARK: - Skip intro / outro (P3)

    private func setupSkipButton() {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        config.baseForegroundColor = .white
        config.image = UIImage(systemName: "forward.fill")
        config.imagePadding = 8
        skipButton.configuration = config
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.isHidden = true
        skipButton.addTarget(self, action: #selector(skipSegmentTapped), for: .primaryActionTriggered)
        view.addSubview(skipButton)
        NSLayoutConstraint.activate([
            skipButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            skipButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -64)
        ])
    }

    private func fetchSegments() {
        segmentFetchTask?.cancel()
        segments = []
        activeSegmentType = nil
        skipButton.isHidden = true
        let client = apiClient
        let id = itemId
        segmentFetchTask = Task { [weak self] in
            let fetched = (try? await client.getMediaSegments(itemId: id, includeSegmentTypes: [.intro, .outro])) ?? []
            guard !Task.isCancelled else { return }
            self?.segments = fetched
        }
    }

    private func updateSkipButton(currentTime: Double) {
        for segment in segments {
            let start = Double(segment.startTicks ?? 0) / 10_000_000
            let end = Double(segment.endTicks ?? 0) / 10_000_000
            guard end > start, currentTime >= start, currentTime < end - 1 else { continue }
            if activeSegmentType != segment.type {
                activeSegmentType = segment.type
                let key = segment.type == .intro ? "player.skipIntro" : "player.skipCredits"
                skipButton.configuration?.title = loc.localized(key)
                skipButton.isHidden = false
                #if os(tvOS)
                setNeedsFocusUpdate()
                #endif
            }
            return
        }
        if activeSegmentType != nil {
            activeSegmentType = nil
            skipButton.isHidden = true
        }
    }

    @objc private func skipSegmentTapped() {
        for segment in segments where segment.type == activeSegmentType {
            let end = Int32(Double(segment.endTicks ?? 0) / 10_000_000 * 1000)
            mediaPlayer.time = VLCTime(int: end)
            skipButton.isHidden = true
            activeSegmentType = nil
            return
        }
    }

    // MARK: - Sleep timer (P3)

    private func startSleepTimerIfNeeded() {
        let seconds = SleepTimerOption.currentDefaultSeconds
        guard seconds > 0 else { sleepActive = false; return }
        sleepRemaining = seconds
        sleepActive = true
    }

    private func fireSleepTimer() {
        sleepActive = false
        mediaPlayer.pause()
        let alert = UIAlertController(
            title: loc.localized("sleep.prompt.title"),
            message: loc.localized("sleep.prompt.subtitle"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: loc.localized("sleep.prompt.keepWatching"), style: .default) { [weak self] _ in
            self?.mediaPlayer.play()
            self?.startSleepTimerIfNeeded()
        })
        alert.addAction(UIAlertAction(title: loc.localized("sleep.prompt.stop"), style: .destructive) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    // MARK: - UI

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

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = titleText
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        controlsContainer.addSubview(titleLabel)

        #if os(tvOS)
        let timeFont: CGFloat = 26
        let hudFont: CGFloat = 34
        let titleTop: CGFloat = 48
        let titleLead: CGFloat = 64
        let hudMinW: CGFloat = 220
        let hudH: CGFloat = 80
        #else
        let timeFont: CGFloat = 14
        let hudFont: CGFloat = 20
        let titleTop: CGFloat = 16
        let titleLead: CGFloat = 24
        let hudMinW: CGFloat = 140
        let hudH: CGFloat = 56
        #endif

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.text = "0:00"
        timeLabel.font = .monospacedDigitSystemFont(ofSize: timeFont, weight: .semibold)
        timeLabel.textColor = .white
        controlsContainer.addSubview(timeLabel)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.text = "0:00"
        durationLabel.font = .monospacedDigitSystemFont(ofSize: timeFont, weight: .semibold)
        durationLabel.textColor = .white
        controlsContainer.addSubview(durationLabel)

        // Transient HUD shown on ±15 s skip (both platforms).
        skipHUD.translatesAutoresizingMaskIntoConstraints = false
        skipHUD.font = .systemFont(ofSize: hudFont, weight: .bold)
        skipHUD.textColor = .white
        skipHUD.textAlignment = .center
        skipHUD.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        skipHUD.layer.cornerRadius = 16
        skipHUD.clipsToBounds = true
        skipHUD.alpha = 0
        view.addSubview(skipHUD)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: titleTop),
            titleLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: titleLead),
            titleLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),

            skipHUD.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            skipHUD.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            skipHUD.widthAnchor.constraint(greaterThanOrEqualToConstant: hudMinW),
            skipHUD.heightAnchor.constraint(equalToConstant: hudH)
        ])

        #if os(tvOS)
        buildTVTransport(safe: safe)
        #else
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        controlsContainer.addSubview(progress)
        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            timeLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -24),
            durationLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            durationLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -24),
            progress.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            progress.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor)
        ])

        var doneConfig = UIButton.Configuration.plain()
        doneConfig.title = loc.localized("action.done")
        doneConfig.baseForegroundColor = .white
        doneButton.configuration = doneConfig
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        controlsContainer.addSubview(doneButton)

        var trackConfig = UIButton.Configuration.plain()
        trackConfig.image = UIImage(systemName: "captions.bubble")
        trackConfig.baseForegroundColor = .white
        tracksButton.configuration = trackConfig
        tracksButton.translatesAutoresizingMaskIntoConstraints = false
        tracksButton.addTarget(self, action: #selector(openTrackMenu), for: .touchUpInside)
        controlsContainer.addSubview(tracksButton)

        var playConfig = UIButton.Configuration.plain()
        playConfig.image = UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 56, weight: .bold))
        playConfig.baseForegroundColor = .white
        playPauseButton.configuration = playConfig
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        controlsContainer.addSubview(playPauseButton)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.addTarget(self, action: #selector(scrubberChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubberDone), for: [.touchUpInside, .touchUpOutside])
        controlsContainer.addSubview(slider)
        progress.isHidden = true

        NSLayoutConstraint.activate([
            doneButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            doneButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            tracksButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),
            tracksButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -12),
            slider.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor)
        ])
        #endif
    }

    private func setupGestures() {
        #if os(iOS)
        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        videoView.addGestureRecognizer(tap)
        videoView.isUserInteractionEnabled = true
        #else
        // Focus engine drives navigation between the scrub bar and the control
        // buttons. Left/right seeking is handled by TVScrubBar ONLY while it is
        // focused, so it never blocks moving focus to the menu buttons. We only
        // intercept the dedicated Play/Pause and Menu presses globally.
        addPress(.playPause, #selector(playPauseTapped))
        addPress(.menu, #selector(menuPressed))
        #endif
    }

    #if os(tvOS)
    private func addPress(_ type: UIPress.PressType, _ action: Selector) {
        let g = UITapGestureRecognizer(target: self, action: action)
        g.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(g)
    }

    @objc private func menuPressed() {
        dismiss(animated: true)
    }

    // MARK: tvOS transport UI

    private func buildTVTransport(safe: UILayoutGuide) {
        // Bottom scrim so white text/controls stay legible over bright video.
        let scrim = UIView()
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        controlsContainer.insertSubview(scrim, at: 0)

        // Focusable scrub bar: left/right seek ±15 s ONLY while it holds focus,
        // so the focus engine can move left/right between the control buttons
        // when the bar is not focused.
        tvScrub.translatesAutoresizingMaskIntoConstraints = false
        tvScrub.onSeek = { [weak self] delta in
            guard let self else { return }
            if delta < 0 { self.mediaPlayer.jumpBackward(15); self.showSkipHUD("−15s") }
            else { self.mediaPlayer.jumpForward(15); self.showSkipHUD("+15s") }
            self.scheduleHideControls()
        }
        tvScrub.onSelect = { [weak self] in self?.playPauseTapped() }
        controlsContainer.addSubview(tvScrub)

        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.axis = .horizontal
        controlBar.alignment = .center
        controlBar.spacing = 8
        controlsContainer.addSubview(controlBar)

        configureTV(tvPrevButton, "backward.end.fill", loc.localized("player.previousEpisode"))
        tvPrevButton.addTarget(self, action: #selector(prevEpisodeTapped), for: .primaryActionTriggered)
        configureTV(tvPlayButton, "pause.fill", loc.localized("player.playPause"))
        tvPlayButton.addTarget(self, action: #selector(playPauseTapped), for: .primaryActionTriggered)
        configureTV(tvAudioButton, "waveform", loc.localized("player.audio"))
        tvAudioButton.addTarget(self, action: #selector(openAudioMenu), for: .primaryActionTriggered)
        configureTV(tvSubtitleButton, "captions.bubble", loc.localized("player.subtitles"))
        tvSubtitleButton.addTarget(self, action: #selector(openSubtitleMenu), for: .primaryActionTriggered)
        configureTV(tvChaptersButton, "list.bullet", loc.localized("player.chapters"))
        tvChaptersButton.addTarget(self, action: #selector(openChapterMenu), for: .primaryActionTriggered)
        configureTV(tvNextButton, "forward.end.fill", loc.localized("player.nextEpisode"))
        tvNextButton.addTarget(self, action: #selector(nextEpisodeTapped), for: .primaryActionTriggered)

        if previousEpisode != nil { controlBar.addArrangedSubview(tvPrevButton) }
        controlBar.addArrangedSubview(tvPlayButton)
        if nextEpisode != nil { controlBar.addArrangedSubview(tvNextButton) }
        controlBar.addArrangedSubview(tvAudioButton)
        controlBar.addArrangedSubview(tvSubtitleButton)
        tvChaptersButton.isHidden = true
        controlBar.addArrangedSubview(tvChaptersButton)

        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor),
            scrim.topAnchor.constraint(equalTo: tvScrub.topAnchor, constant: -56),

            timeLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 64),
            timeLabel.bottomAnchor.constraint(equalTo: tvScrub.topAnchor, constant: -14),
            durationLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -64),
            durationLabel.bottomAnchor.constraint(equalTo: tvScrub.topAnchor, constant: -14),

            tvScrub.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 64),
            tvScrub.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -64),
            tvScrub.heightAnchor.constraint(equalToConstant: 24),
            tvScrub.bottomAnchor.constraint(equalTo: controlBar.topAnchor, constant: -28),

            controlBar.centerXAnchor.constraint(equalTo: controlsContainer.centerXAnchor),
            controlBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -36)
        ])
    }

    private func configureTV(_ b: UIButton, _ symbol: String, _ accessibility: String) {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold))
        cfg.baseForegroundColor = .white
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        b.configuration = cfg
        b.accessibilityLabel = accessibility
    }

    private func setTVPlayIcon(playing: Bool) {
        configureTV(tvPlayButton, playing ? "pause.fill" : "play.fill", loc.localized("player.playPause"))
    }

    private func showSkipHUD(_ text: String) {
        skipHUDHide?.cancel()
        skipHUD.text = "  \(text)  "
        skipHUD.alpha = 1
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.skipHUD.alpha = 0 }
        }
        skipHUDHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func updateScrubBar(progress: Float) {
        tvScrub.setProgress(progress)
    }

    @objc private func prevEpisodeTapped() { if let p = previousEpisode { navigateToEpisode(p) } }
    @objc private func nextEpisodeTapped() { if let n = nextEpisode { navigateToEpisode(n) } }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        controlsContainer.alpha > 0 ? [tvScrub] : []
    }
    #endif

    // MARK: - Single-purpose track / chapter menus

    private func presentPicker(_ title: String, _ build: (UIAlertController) -> Void) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        build(sheet)
        sheet.addAction(UIAlertAction(title: loc.localized("action.cancel"), style: .cancel))
        present(sheet, animated: true)
    }

    @objc private func openAudioMenu() {
        presentPicker(loc.localized("player.audio")) { sheet in
            let idx = mediaPlayer.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
            let names = mediaPlayer.audioTrackNames.compactMap { $0 as? String }
            for (i, name) in names.enumerated() where i < idx.count {
                let track = idx[i]
                let on = track == mediaPlayer.currentAudioTrackIndex
                sheet.addAction(UIAlertAction(title: name + (on ? "  ✓" : ""), style: .default) { [weak self] _ in
                    self?.mediaPlayer.currentAudioTrackIndex = track
                })
            }
        }
    }

    @objc private func openSubtitleMenu() {
        presentPicker(loc.localized("player.subtitles")) { sheet in
            let idx = mediaPlayer.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
            let names = mediaPlayer.videoSubTitlesNames.compactMap { $0 as? String }
            for (i, name) in names.enumerated() where i < idx.count {
                let track = idx[i]
                let on = track == mediaPlayer.currentVideoSubTitleIndex
                sheet.addAction(UIAlertAction(title: name + (on ? "  ✓" : ""), style: .default) { [weak self] _ in
                    self?.mediaPlayer.currentVideoSubTitleIndex = track
                })
            }
        }
    }

    @objc private func openChapterMenu() {
        presentPicker(loc.localized("player.chapters")) { sheet in
            sheet.addAction(UIAlertAction(title: loc.localized("player.chapter.previous"), style: .default) { [weak self] _ in
                self?.mediaPlayer.previousChapter()
            })
            sheet.addAction(UIAlertAction(title: loc.localized("player.chapter.next"), style: .default) { [weak self] _ in
                self?.mediaPlayer.nextChapter()
            })
        }
    }

    // MARK: - Playback

    private func startPlayback() {
        let url = VLCStreamPresenter.authedURL(info.url, token: info.authToken)
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=3000")
        mediaPlayer.media = media
        mediaPlayer.delegate = self
        mediaPlayer.play()
        reporter?.reportStart(startTime: startTime)
        startProgressTimer()
        fetchSegments()
        startSleepTimerIfNeeded()
    }

    @objc private func playPauseTapped() {
        if mediaPlayer.isPlaying { mediaPlayer.pause() } else { mediaPlayer.play() }
        scheduleHideControls()
    }

    // MARK: - Episode navigation

    private func navigateToEpisode(_ ref: EpisodeRef) {
        guard let navigator = episodeNavigator else { return }
        reporter?.reportStop()
        progressTimer?.invalidate()
        Task { [weak self] in
            guard let self else { return }
            // Navigator yields the new prev/next graph (its PlaybackInfo is
            // negotiated for the native engine, so we re-negotiate for VLC).
            let nav = await navigator(ref.id)
            guard let vlcInfo = try? await self.apiClient.getPlaybackInfo(
                itemId: ref.id, userId: self.userId, engine: .vlc
            ) else {
                logger.error("VLC episode nav: failed to negotiate \(ref.id, privacy: .public)")
                return
            }
            self.itemId = ref.id
            self.info = vlcInfo
            self.startTime = nil
            self.didSeekToStart = true // new episode starts at 0
            self.didRetry = false
            self.didReportEnd = false
            self.previousEpisode = nav?.1
            self.nextEpisode = nav?.2
            self.titleLabel.text = ref.title
            let url = VLCStreamPresenter.authedURL(vlcInfo.url, token: vlcInfo.authToken)
            let media = VLCMedia(url: url)
            media.addOption(":network-caching=3000")
            self.mediaPlayer.media = media
            self.mediaPlayer.play()
            self.reporter?.resetTicking()
            self.reporter?.reportStart(startTime: nil)
            self.startProgressTimer()
            self.fetchSegments()
            self.startSleepTimerIfNeeded()
            self.remoteCommands.attach(
                previous: self.previousEpisode, next: self.nextEpisode,
                hasNavigator: true
            )
            self.showControls()
            self.scheduleHideControls()
        }
    }

    // MARK: - Track selection (audio / subtitle)

    @objc private func openTrackMenu() {
        let sheet = UIAlertController(title: loc.localized("player.tracks.title"), message: nil, preferredStyle: .actionSheet)

        let audioIdx = mediaPlayer.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let audioNames = mediaPlayer.audioTrackNames.compactMap { $0 as? String }
        for (i, name) in audioNames.enumerated() where i < audioIdx.count {
            let idx = audioIdx[i]
            let selected = idx == mediaPlayer.currentAudioTrackIndex
            sheet.addAction(UIAlertAction(title: "🔊 \(name)\(selected ? " ✓" : "")", style: .default) { [weak self] _ in
                self?.mediaPlayer.currentAudioTrackIndex = idx
            })
        }

        let subIdx = mediaPlayer.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let subNames = mediaPlayer.videoSubTitlesNames.compactMap { $0 as? String }
        for (i, name) in subNames.enumerated() where i < subIdx.count {
            let idx = subIdx[i]
            let selected = idx == mediaPlayer.currentVideoSubTitleIndex
            sheet.addAction(UIAlertAction(title: "💬 \(name)\(selected ? " ✓" : "")", style: .default) { [weak self] _ in
                self?.mediaPlayer.currentVideoSubTitleIndex = idx
            })
        }

        // Chapters (embedded in the container — VLC enumerates them natively).
        if mediaPlayer.numberOfChapters(forTitle: mediaPlayer.currentTitleIndex) > 1 {
            sheet.addAction(UIAlertAction(title: "⏮ " + loc.localized("player.chapter.previous"), style: .default) { [weak self] _ in
                self?.mediaPlayer.previousChapter()
            })
            sheet.addAction(UIAlertAction(title: "⏭ " + loc.localized("player.chapter.next"), style: .default) { [weak self] _ in
                self?.mediaPlayer.nextChapter()
            })
        }

        sheet.addAction(UIAlertAction(title: loc.localized("action.cancel"), style: .cancel))
        present(sheet, animated: true)
    }

    #if os(iOS)
    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    @objc private func viewTapped() {
        if controlsContainer.alpha > 0 { hideControlsImmediately() }
        else { showControls(); scheduleHideControls() }
    }

    @objc private func scrubberChanged() {
        isScrubbing = true
        let length = mediaPlayer.media?.length.intValue ?? 0
        guard length > 0 else { return }
        timeLabel.text = Self.formatMs(Int32(Float(length) * slider.value))
    }

    @objc private func scrubberDone() {
        let length = mediaPlayer.media?.length.intValue ?? 0
        guard length > 0 else { isScrubbing = false; return }
        mediaPlayer.time = VLCTime(int: Int32(Float(length) * slider.value))
        isScrubbing = false
        scheduleHideControls()
    }

    private func setPlayPauseIcon(playing: Bool) {
        var config = playPauseButton.configuration ?? UIButton.Configuration.plain()
        config.image = UIImage(systemName: playing ? "pause.fill" : "play.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 56, weight: .bold))
        playPauseButton.configuration = config
    }
    #endif

    // MARK: - Auto-hide

    private func scheduleHideControls() {
        hideControlsWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideControlsImmediately() }
        hideControlsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func hideControlsImmediately() {
        UIView.animate(withDuration: 0.25) { self.controlsContainer.alpha = 0 }
        #if os(tvOS)
        controlsContainer.isUserInteractionEnabled = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        #endif
    }

    private func showControls() {
        UIView.animate(withDuration: 0.2) { self.controlsContainer.alpha = 1 }
        #if os(tvOS)
        controlsContainer.isUserInteractionEnabled = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        #endif
    }

    // MARK: - VLCMediaPlayerDelegate

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.mediaPlayer.state {
            case .error:
                self.handlePlaybackError()
            case .ended:
                self.handlePlaybackEnded()
            case .playing:
                self.didRetry = false
                #if os(iOS)
                self.setPlayPauseIcon(playing: true)
                #else
                self.setTVPlayIcon(playing: true)
                #endif
            case .paused:
                #if os(iOS)
                self.setPlayPauseIcon(playing: false)
                #else
                self.setTVPlayIcon(playing: false)
                #endif
            default: break
            }
        }
    }

    private func handlePlaybackEnded() {
        guard !didReportEnd else { return }
        didReportEnd = true
        if autoPlayNext, let next = nextEpisode, episodeNavigator != nil {
            didReportEnd = false
            navigateToEpisode(next)
            return
        }
        reporter?.reportStop()
        if episodeNavigator != nil {
            showEndOfSeriesOverlay()
        } else {
            dismiss(animated: true)
        }
    }

    private func showEndOfSeriesOverlay() {
        Task { [weak self] in
            guard let self else { return }
            let item = try? await self.apiClient.getItem(userId: self.userId, itemId: self.itemId)
            let seriesName = item?.seriesName ?? item?.name ?? self.titleText
            let alert = UIAlertController(
                title: String(format: self.loc.localized("player.finishedSeries.title"), seriesName),
                message: self.loc.localized("player.finishedSeries.subtitle"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: self.loc.localized("player.finishedSeries.done"), style: .default) { [weak self] _ in
                self?.dismiss(animated: true)
            })
            self.present(alert, animated: true)
        }
    }

    private func handlePlaybackError() {
        if !didRetry {
            didRetry = true
            logger.error("VLC stream error for \(self.itemId, privacy: .public) — retrying once")
            let url = VLCStreamPresenter.authedURL(info.url, token: info.authToken)
            let media = VLCMedia(url: url)
            media.addOption(":network-caching=5000")
            mediaPlayer.media = media
            mediaPlayer.play()
            return
        }
        logger.error("VLC stream error for \(self.itemId, privacy: .public) — giving up")
        let alert = UIAlertController(
            title: loc.localized("playback.error.title"),
            message: loc.localized("playback.error.generic"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: loc.localized("playback.error.close"), style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let currentMs = self.mediaPlayer.time.intValue
            let lengthMs = self.mediaPlayer.media?.length.intValue ?? 0
            #if os(iOS)
            if !self.isScrubbing {
                self.timeLabel.text = Self.formatMs(currentMs)
                self.durationLabel.text = Self.formatMs(lengthMs)
                if lengthMs > 0 { self.slider.value = Float(currentMs) / Float(lengthMs) }
            }
            #else
            self.timeLabel.text = Self.formatMs(currentMs)
            self.durationLabel.text = "-" + Self.formatMs(max(0, lengthMs - currentMs))
            if lengthMs > 0 { self.updateScrubBar(progress: Float(currentMs) / Float(lengthMs)) }
            if self.tvChaptersButton.isHidden,
               self.mediaPlayer.numberOfChapters(forTitle: self.mediaPlayer.currentTitleIndex) > 1 {
                self.tvChaptersButton.isHidden = false
            }
            #endif
            if !self.didSeekToStart, let start = self.startTime, start > 0, lengthMs > 0 {
                self.didSeekToStart = true
                self.mediaPlayer.time = VLCTime(int: Int32(start * 1000))
            }
        }
    }

    private static func formatMs(_ ms: Int32) -> String {
        let total = Int(max(0, ms) / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

#if os(tvOS)
/// Focusable tvOS scrub bar. Left/right seek ±15 s ONLY while this view holds
/// focus — every other press (up/down to move focus to the control buttons,
/// Play/Pause, Menu) is passed to `super` so the focus engine keeps working.
/// This is what lets the user reach the Audio/Subtitles/episode buttons; the
/// previous view-level arrow gestures swallowed left/right globally.
private final class TVScrubBar: UIView {
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
