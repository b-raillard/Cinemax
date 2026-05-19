import UIKit
import SwiftUI
import QuartzCore
import SwiftVLC
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "VLCPlayback")

/// Single source of truth for the ±N-second skip interval used by EVERY
/// in-app skip affordance (double-tap, ±N buttons, tvOS scrub bar, the
/// center skip glyph). Set to **10 s** to match the system Picture-in-Picture
/// overlay: AVKit hands SwiftVLC's `PiPController` a system-fixed skip
/// interval (±10 s for sample-buffer PiP) that apps cannot override, so the
/// only way to keep PiP and normal mode consistent is to align normal mode
/// to it. SF Symbols only exist for discrete values (…10/.15/.30…) — keep
/// `intervalSeconds` to one of those.
enum PlayerSkipConfig {
    static let intervalSeconds: Int = 10
    static var backwardSymbol: String { "gobackward.\(intervalSeconds)" }
    static var forwardSymbol: String { "goforward.\(intervalSeconds)" }
}

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
    private let imageBuilder: ImageURLBuilder
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
        imageBuilder: ImageURLBuilder,
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
        self.imageBuilder = imageBuilder
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
            autoPlayNext: autoPlayNext, imageBuilder: imageBuilder, loc: loc, onDismiss: onDismiss
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
    nonisolated static func authedURL(_ url: URL, token: String?) -> URL {
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

private final class VLCStreamViewController: UIViewController, UIScrollViewDelegate {
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
    private let imageBuilder: ImageURLBuilder
    private let loc: LocalizationManager
    private let onDismiss: (() -> Void)?

    // SwiftVLC engine (libVLC 4.0). `videoView` stays a plain UIView so the
    // existing gesture / HUD layout is untouched; the SwiftVLC rendering
    // surface is embedded into it via a child UIHostingController.
    private let player = Player()
    private let videoView = UIView()
    private var videoHost: UIViewController?
    private var eventsTask: Task<Void, Never>?
    /// Latest known media length in ms. SwiftVLC's `player.duration` can lag a
    /// beat after `.lengthChanged`; cache it from the events stream so the
    /// scrub bar / remaining-time math stays correct (mirrors the old
    /// `mediaPlayer.media?.length` reads).
    private var mediaLengthMs: Int32 = 0
    private var didApplyServerTrackDefaults = false
    #if os(iOS)
    private var pipController: PiPController?
    private let pipButton = UIButton(type: .system)
    #endif
    private let controlsContainer = PassthroughView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let durationLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let skipHUD = UILabel()
    private var skipHUDHide: DispatchWorkItem?

    // Shared rich-HUD elements — the iOS HUD now mirrors the tvOS transport
    // (same visual language): an always-on chapter strip, a native-style
    // center play/pause flash, and a native ±15 s skip indicator.
    private let chapterScroll = UIScrollView()
    private let chapterStack = UIStackView()
    private var chapterFetchTask: Task<Void, Never>?
    private var chapterStartTicks: [Int] = []
    private var chapterHeightConstraint: NSLayoutConstraint?
    private let centerGlyph = UIImageView()
    private var centerGlyphHide: DispatchWorkItem?
    private let skipGlyph = UIImageView()
    private var skipGlyphHide: DispatchWorkItem?

    #if os(iOS)
    private let closeButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let skipBackButton = UIButton(type: .system)
    private let skipFwdButton = UIButton(type: .system)
    private let prevButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let transportRow = UIStackView()
    private let slider = UISlider()
    private var isScrubbing = false
    #else
    // tvOS custom transport: a focusable scrub bar + a focusable control row.
    // No on-screen Play/Pause button — the Siri Remote has a physical one;
    // feedback is the center glyph flash only.
    private let tvScrub = TVScrubBar()
    private let controlBar = UIStackView()
    private let tvAudioButton = UIButton(type: .system)
    private let tvSubtitleButton = UIButton(type: .system)
    private let tvPrevButton = UIButton(type: .system)
    private let tvNextButton = UIButton(type: .system)
    #endif

    private var reporter: PlaybackReporter?
    private let remoteCommands: RemoteCommandController
    private var progressTimer: Timer?
    private var hideControlsWorkItem: DispatchWorkItem?
    private var didSeekToStart = false
    /// True once the player has reported a real (non-zero) position. The skip
    /// intro/outro button stays hidden until then — otherwise a segment that
    /// starts at 0 flashes the button during the loading spinner.
    private var hasValidTime = false
    /// Explicit HUD state so single-tap toggling never depends on mid-animation
    /// `alpha` reads.
    private var controlsVisible = true
    /// One tap recognizer disambiguates single vs double itself (no
    /// `require(toFail:)` — that was starving the single tap). A single tap's
    /// toggle is deferred briefly; a second tap inside the window cancels it
    /// and seeks instead.
    private var pendingTapWork: DispatchWorkItem?
    private var lastTapTime: TimeInterval = 0

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

    // SwiftVLC end-of-media disambiguation: `.stopped` fires for natural end,
    // teardown, AND media swap. `isTearingDown` suppresses end handling during
    // dismissal; `lastPlayStart` ignores the `.stopped` that can follow a
    // fresh `play(media)` (old media winding down).
    private var isTearingDown = false
    private var lastPlayStart = Date.distantPast

    // Polish: a track/chapter picker is up — freeze the HUD behind it.
    private var pickerPresented = false

    init(
        itemId: String, info: PlaybackInfo, title: String, startTime: Double?,
        previousEpisode: EpisodeRef?, nextEpisode: EpisodeRef?,
        episodeNavigator: EpisodeNavigator?, apiClient: any PlaybackAPI & LibraryAPI,
        userId: String, autoPlayNext: Bool, imageBuilder: ImageURLBuilder,
        loc: LocalizationManager, onDismiss: (() -> Void)?
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
        self.imageBuilder = imageBuilder
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
        isTearingDown = true
        progressTimer?.invalidate()
        progressTimer = nil
        remoteCommands.detach()
        hideControlsWorkItem?.cancel()
        pendingTapWork?.cancel()
        segmentFetchTask?.cancel()
        chapterFetchTask?.cancel()
        eventsTask?.cancel()
        eventsTask = nil
        #if os(iOS)
        pipController = nil
        #endif
        player.stop()
    }

    // MARK: - Engine bridge (SwiftVLC)

    /// Current position in ms (mirrors the old `mediaPlayer.time.intValue`).
    private var currentMs: Int32 {
        let c = player.currentTime.components
        return Int32(clamping: Int(c.seconds) * 1000
            + Int(c.attoseconds / 1_000_000_000_000_000))
    }

    /// Cached media length in ms (mirrors `mediaPlayer.media?.length.intValue`).
    private var lengthMs: Int32 { mediaLengthMs }

    /// True only while actively playing (matches VLCKit's `isPlaying`, which
    /// was false during pause/stop/buffering).
    private var enginePlaying: Bool { player.state == .playing }

    private func engineSeek(ms: Int32) {
        player.seek(to: .milliseconds(Int(max(0, ms))))
    }

    private func engineSeek(bySeconds s: Int) {
        player.seek(by: .seconds(s))
    }

    private func enginePlay() { player.resume() }
    private func enginePause() { player.pause() }

    /// Builds the authed SwiftVLC `Media` with the same network-caching option
    /// the VLCKit path used.
    private func makeMedia(_ url: URL) -> Media? {
        guard let media = try? Media(url: url) else { return nil }
        media.addOption(":network-caching=3000")
        return media
    }

    /// Consume SwiftVLC's event stream — replaces the old
    /// `VLCMediaPlayerDelegate` callbacks. One Task per presenter lifetime;
    /// rebinding media (episode nav / retry) keeps the same stream.
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
                case .tracksChanged:
                    self.applyServerTrackDefaultsIfNeeded()
                case .encounteredError:
                    self.handlePlaybackError()
                default:
                    break
                }
            }
        }
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
                return (Double(self.currentMs) / 1000.0, !self.enginePlaying)
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
        let now = Double(currentMs) / 1000.0
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
        guard hasValidTime else {
            if !skipButton.isHidden { skipButton.isHidden = true }
            activeSegmentType = nil
            return
        }
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
            engineSeek(ms: end)
            skipButton.isHidden = true
            activeSegmentType = nil
            refreshTimeUISoon()
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
        enginePause()
        let alert = UIAlertController(
            title: loc.localized("sleep.prompt.title"),
            message: loc.localized("sleep.prompt.subtitle"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: loc.localized("sleep.prompt.keepWatching"), style: .default) { [weak self] _ in
            self?.enginePlay()
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

        // SwiftVLC renders through a SwiftUI representable. Host it in a child
        // UIHostingController pinned to `videoView`. Interaction is disabled so
        // the tap recognizer on `videoView` keeps receiving HUD toggles (the
        // old VLCKit `drawable` was a plain UIView with the same behavior).
        let surface = EngineSurface(player: player) { [weak self] controller in
            #if os(iOS)
            self?.pipController = controller as? PiPController
            #endif
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

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = titleText
        #if os(iOS)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        // The title must yield to the top-right control cluster: in narrow
        // portrait a long title would otherwise win the layout and shove the
        // PiP/audio/subtitle buttons into each other. Low compression
        // resistance + truncation keeps the buttons tappable.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        #else
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        #endif
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

        // Transient HUD shown on chapter jump (both platforms).
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
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),

            skipHUD.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            skipHUD.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            skipHUD.widthAnchor.constraint(greaterThanOrEqualToConstant: hudMinW),
            skipHUD.heightAnchor.constraint(equalToConstant: hudH)
        ])

        // Native-style center play/pause flash + ±15 s skip indicator. Shared
        // across platforms so iOS and tvOS speak the same visual language.
        centerGlyph.translatesAutoresizingMaskIntoConstraints = false
        centerGlyph.tintColor = .white
        centerGlyph.contentMode = .center
        centerGlyph.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        centerGlyph.clipsToBounds = true
        centerGlyph.alpha = 0
        view.addSubview(centerGlyph)

        skipGlyph.translatesAutoresizingMaskIntoConstraints = false
        skipGlyph.tintColor = .white
        skipGlyph.contentMode = .center
        skipGlyph.alpha = 0
        skipGlyph.layer.shadowColor = UIColor.black.cgColor
        skipGlyph.layer.shadowOpacity = 0.5
        skipGlyph.layer.shadowRadius = 8
        skipGlyph.layer.shadowOffset = .zero
        view.addSubview(skipGlyph)

        #if os(tvOS)
        centerGlyph.layer.cornerRadius = 60
        skipGlyph.layer.cornerRadius = 0
        NSLayoutConstraint.activate([
            centerGlyph.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerGlyph.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            centerGlyph.widthAnchor.constraint(equalToConstant: 120),
            centerGlyph.heightAnchor.constraint(equalToConstant: 120),
            skipGlyph.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            skipGlyph.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            skipGlyph.widthAnchor.constraint(equalToConstant: 110),
            skipGlyph.heightAnchor.constraint(equalToConstant: 110)
        ])
        #else
        centerGlyph.layer.cornerRadius = 50
        NSLayoutConstraint.activate([
            centerGlyph.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerGlyph.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            centerGlyph.widthAnchor.constraint(equalToConstant: 100),
            centerGlyph.heightAnchor.constraint(equalToConstant: 100),
            skipGlyph.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            skipGlyph.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            skipGlyph.widthAnchor.constraint(equalToConstant: 100),
            skipGlyph.heightAnchor.constraint(equalToConstant: 100)
        ])
        #endif

        #if os(tvOS)
        buildTVTransport(safe: safe)
        #else
        buildIOSTransport(safe: safe)
        #endif
    }

    // MARK: - iOS transport UI

    #if os(iOS)
    /// Builds the iOS HUD with the same visual language as the tvOS transport:
    /// title top-left, a top-right cluster (audio / subtitles / Done), a
    /// centered transport row (prev / −15 / play-pause / +15 / next), a scrub
    /// bar with current time + remaining above it, and the always-on chapter
    /// strip — no stray full-screen center play button.
    private func buildIOSTransport(safe: UILayoutGuide) {
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.addTarget(self, action: #selector(scrubberTouchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubberChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubberDone), for: [.touchUpInside, .touchUpOutside])
        controlsContainer.addSubview(slider)

        // Close (✕) — part of the HUD, so it fades in/out with the controls.
        var closeConfig = UIButton.Configuration.plain()
        closeConfig.image = UIImage(systemName: "xmark",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        closeConfig.baseForegroundColor = .white
        closeConfig.background.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        closeConfig.cornerStyle = .capsule
        closeConfig.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        closeButton.configuration = closeConfig
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabel = loc.localized("action.done")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        controlsContainer.addSubview(closeButton)
        controlsContainer.bringSubviewToFront(closeButton)

        configureIOS(audioButton, "waveform", pt: 17, loc.localized("player.audio"), compact: true)
        audioButton.addTarget(self, action: #selector(openAudioMenu), for: .touchUpInside)
        controlsContainer.addSubview(audioButton)
        configureIOS(subtitleButton, "captions.bubble", pt: 17, loc.localized("player.subtitles"), compact: true)
        subtitleButton.addTarget(self, action: #selector(openSubtitleMenu), for: .touchUpInside)
        controlsContainer.addSubview(subtitleButton)
        configureIOS(pipButton, "pip.enter", pt: 17, loc.localized("player.pip"), compact: true)
        pipButton.addTarget(self, action: #selector(pipTapped), for: .touchUpInside)
        controlsContainer.addSubview(pipButton)

        transportRow.translatesAutoresizingMaskIntoConstraints = false
        transportRow.axis = .horizontal
        transportRow.alignment = .center
        transportRow.spacing = 24
        controlsContainer.addSubview(transportRow)

        configureIOS(prevButton, "backward.end.fill", pt: 24, loc.localized("player.previousEpisode"))
        prevButton.addTarget(self, action: #selector(prevEpisodeTapped), for: .touchUpInside)
        configureIOS(skipBackButton, PlayerSkipConfig.backwardSymbol, pt: 30, loc.localized("player.skipIntro"))
        skipBackButton.addTarget(self, action: #selector(iosSkipBack), for: .touchUpInside)

        var ppCfg = UIButton.Configuration.plain()
        ppCfg.image = UIImage(systemName: "pause.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .bold))
        ppCfg.baseForegroundColor = .white
        playPauseButton.configuration = ppCfg
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)

        configureIOS(skipFwdButton, PlayerSkipConfig.forwardSymbol, pt: 30, loc.localized("player.skipCredits"))
        skipFwdButton.addTarget(self, action: #selector(iosSkipForward), for: .touchUpInside)
        configureIOS(nextButton, "forward.end.fill", pt: 24, loc.localized("player.nextEpisode"))
        nextButton.addTarget(self, action: #selector(nextEpisodeTapped), for: .touchUpInside)

        if previousEpisode != nil { transportRow.addArrangedSubview(prevButton) }
        transportRow.addArrangedSubview(skipBackButton)
        transportRow.addArrangedSubview(playPauseButton)
        transportRow.addArrangedSubview(skipFwdButton)
        if nextEpisode != nil { transportRow.addArrangedSubview(nextButton) }

        chapterScroll.translatesAutoresizingMaskIntoConstraints = false
        chapterScroll.showsHorizontalScrollIndicator = false
        chapterScroll.isHidden = true
        chapterScroll.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        chapterScroll.delegate = self
        chapterStack.axis = .horizontal
        chapterStack.alignment = .top
        chapterStack.spacing = 16
        chapterStack.translatesAutoresizingMaskIntoConstraints = false
        chapterScroll.addSubview(chapterStack)
        controlsContainer.addSubview(chapterScroll)

        let chH = chapterScroll.heightAnchor.constraint(equalToConstant: 0)
        chH.isActive = true
        chapterHeightConstraint = chH

        // Anchor the top-right cluster to the container's OWN safe area (it's
        // pinned to the screen edges, so this equals the screen safe area) —
        // removes any cross-hierarchy ambiguity vs `view.safeAreaLayoutGuide`.
        let cSafe = controlsContainer.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: cSafe.trailingAnchor, constant: -12),
            closeButton.topAnchor.constraint(equalTo: cSafe.topAnchor, constant: 8),
            // Title can never run under the top-right cluster.
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pipButton.leadingAnchor, constant: -12),
            subtitleButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            subtitleButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            audioButton.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -4),
            audioButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            pipButton.trailingAnchor.constraint(equalTo: audioButton.leadingAnchor, constant: -4),
            pipButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            slider.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            slider.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -22),

            timeLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            timeLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -8),
            durationLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            durationLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -8),

            transportRow.centerXAnchor.constraint(equalTo: controlsContainer.centerXAnchor),
            transportRow.bottomAnchor.constraint(equalTo: timeLabel.topAnchor, constant: -16),

            chapterScroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            chapterScroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            chapterScroll.bottomAnchor.constraint(equalTo: transportRow.topAnchor, constant: -16),
            chapterStack.topAnchor.constraint(equalTo: chapterScroll.contentLayoutGuide.topAnchor),
            chapterStack.bottomAnchor.constraint(equalTo: chapterScroll.contentLayoutGuide.bottomAnchor),
            chapterStack.leadingAnchor.constraint(equalTo: chapterScroll.contentLayoutGuide.leadingAnchor),
            chapterStack.trailingAnchor.constraint(equalTo: chapterScroll.contentLayoutGuide.trailingAnchor),
            chapterStack.heightAnchor.constraint(equalTo: chapterScroll.frameLayoutGuide.heightAnchor)
        ])
    }

    private func configureIOS(_ b: UIButton, _ symbol: String, pt: CGFloat, _ a11y: String, compact: Bool = false) {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pt, weight: .semibold))
        cfg.baseForegroundColor = .white
        // `compact` = the top-right cluster (PiP/audio/subtitle): tighter
        // insets so four icons + a title fit in narrow portrait. Default
        // insets are for the larger center transport controls.
        cfg.contentInsets = compact
            ? NSDirectionalEdgeInsets(top: 7, leading: 7, bottom: 7, trailing: 7)
            : NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        b.configuration = cfg
        b.accessibilityLabel = a11y
        // Without this, buttons added directly to the container (audio /
        // subtitle) keep autoresizing-mask constraints that conflict with and
        // break the top-right Auto Layout chain — collapsing the close button
        // to a 0-height strip on the left.
        b.translatesAutoresizingMaskIntoConstraints = false
        // Buttons must keep their intrinsic size so the 4-icon cluster never
        // compresses/overlaps in narrow portrait — the title yields instead.
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.setContentHuggingPriority(.required, for: .horizontal)
    }

    private var audioPickerSource: UIView? { audioButton }
    private var subtitlePickerSource: UIView? { subtitleButton }
    #else
    private var audioPickerSource: UIView? { nil }
    private var subtitlePickerSource: UIView? { nil }
    #endif

    private func setupGestures() {
        #if os(iOS)
        // Recognizer lives on `videoView` (the proven-reliable spot — an
        // ancestor-level recognizer doesn't get taps through VLC's drawable
        // subview). `controlsContainer` is a PassthroughView, so empty-area
        // taps fall through here even while the HUD is visible. Single vs
        // double is resolved in `handleTap` by timing (no `require(toFail:)`,
        // which was starving the single tap).
        videoView.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        videoView.addGestureRecognizer(tap)
        #else
        // No global press gestures: presses flow through the responder chain to
        // `pressesBegan` below. The focus engine drives navigation; TVScrubBar
        // seeks left/right only while focused.
        #endif
    }

    #if os(tvOS)
    /// Any remote press while the HUD is hidden just brings the controls back
    /// (and is consumed). While visible, focus/seek work normally and every
    /// press keeps the HUD alive. Menu always exits; Play/Pause always toggles.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu { dismiss(animated: true); return }
            if press.type == .playPause {
                playPauseTapped()
                revealControls()
                return
            }
        }
        if controlsContainer.alpha == 0 {
            revealControls() // consume — first press only un-hides the HUD
            return
        }
        scheduleHideControls() // visible: any press keeps it alive
        super.pressesBegan(presses, with: event)
    }

    /// Moving focus (the user is clearly interacting) keeps the HUD alive, and
    /// the chapter strip only expands to full size while it holds focus —
    /// otherwise just its top edge peeks below the control row.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if controlsContainer.alpha > 0 { scheduleHideControls() }
        guard !chapterScroll.isHidden else { return }
        let inChapters = (context.nextFocusedItem as? UIView).map { v -> Bool in
            var cur: UIView? = v
            while let c = cur { if c === chapterScroll { return true }; cur = c.superview }
            return false
        } ?? false
        let target: CGFloat = inChapters ? chapterFullHeight : chapterPeekHeight
        if chapterHeightConstraint?.constant != target {
            chapterHeightConstraint?.constant = target
            coordinator.addCoordinatedAnimations({ self.view.layoutIfNeeded() })
        }
    }

    private let chapterPeekHeight: CGFloat = 40
    private let chapterFullHeight: CGFloat = 178 // 150 chip + 8 top inset + lift headroom

    private func revealControls() {
        showControls()
        scheduleHideControls()
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
            if delta < 0 { self.engineSeek(bySeconds: -PlayerSkipConfig.intervalSeconds); self.showSkipGlyph(forward: false) }
            else { self.engineSeek(bySeconds: PlayerSkipConfig.intervalSeconds); self.showSkipGlyph(forward: true) }
            self.refreshTimeUISoon()
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
        configureTV(tvAudioButton, "waveform", loc.localized("player.audio"))
        tvAudioButton.addTarget(self, action: #selector(openAudioMenu), for: .primaryActionTriggered)
        configureTV(tvSubtitleButton, "captions.bubble", loc.localized("player.subtitles"))
        tvSubtitleButton.addTarget(self, action: #selector(openSubtitleMenu), for: .primaryActionTriggered)
        configureTV(tvNextButton, "forward.end.fill", loc.localized("player.nextEpisode"))
        tvNextButton.addTarget(self, action: #selector(nextEpisodeTapped), for: .primaryActionTriggered)

        if previousEpisode != nil { controlBar.addArrangedSubview(tvPrevButton) }
        if nextEpisode != nil { controlBar.addArrangedSubview(tvNextButton) }
        controlBar.addArrangedSubview(tvAudioButton)
        controlBar.addArrangedSubview(tvSubtitleButton)

        // Always-on chapter strip — horizontal, focusable. Hidden only until
        // chapters are fetched (or if the media has none).
        chapterScroll.translatesAutoresizingMaskIntoConstraints = false
        chapterScroll.showsHorizontalScrollIndicator = false
        chapterScroll.isHidden = true
        // Horizontal slack so the focus engine can scroll the first/last chip
        // inward — otherwise an edge chip's lift + ring is clipped by the
        // scroll frame. Top inset gives the upward lift room too.
        chapterScroll.contentInset = UIEdgeInsets(top: 8, left: 48, bottom: 0, right: 48)
        chapterStack.axis = .horizontal
        chapterStack.alignment = .top
        chapterStack.spacing = 18
        chapterStack.translatesAutoresizingMaskIntoConstraints = false
        chapterScroll.addSubview(chapterStack)
        controlsContainer.addSubview(chapterScroll)

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
            controlBar.bottomAnchor.constraint(equalTo: chapterScroll.topAnchor, constant: -20),

            chapterScroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 64),
            chapterScroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -64),
            chapterScroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -28),
            chapterStack.topAnchor.constraint(equalTo: chapterScroll.contentLayoutGuide.topAnchor),
            chapterStack.bottomAnchor.constraint(equalTo: chapterScroll.contentLayoutGuide.bottomAnchor),
            chapterStack.leadingAnchor.constraint(equalTo: chapterScroll.contentLayoutGuide.leadingAnchor),
            chapterStack.trailingAnchor.constraint(equalTo: chapterScroll.contentLayoutGuide.trailingAnchor),
            chapterStack.heightAnchor.constraint(equalTo: chapterScroll.frameLayoutGuide.heightAnchor)
        ])
        let ch = chapterScroll.heightAnchor.constraint(equalToConstant: 0)
        ch.isActive = true
        chapterHeightConstraint = ch
    }

    private func configureTV(_ b: UIButton, _ symbol: String, _ accessibility: String) {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold))
        cfg.baseForegroundColor = .white
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        b.configuration = cfg
        b.accessibilityLabel = accessibility
        b.translatesAutoresizingMaskIntoConstraints = false
    }
    #endif

    // MARK: - Chapter strip (shared)

    /// Fetches Jellyfin chapter metadata (name + start time + thumbnail) and
    /// builds the always-on chapter strip. Jellyfin's chapter list is richer
    /// than VLC's embedded titles and exposes thumbnails.
    private func fetchChapters() {
        chapterFetchTask?.cancel()
        chapterStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chapterStartTicks = []
        chapterScroll.isHidden = true
        chapterHeightConstraint?.constant = 0
        let client = apiClient
        let builder = imageBuilder
        let id = itemId
        let uid = userId
        let token = info.authToken
        chapterFetchTask = Task { @MainActor [weak self] in
            guard let item = try? await client.getItem(userId: uid, itemId: id),
                  let chapters = item.chapters, chapters.count > 1,
                  !Task.isCancelled, let self else { return }
            self.chapterStartTicks = chapters.map { $0.startPositionTicks ?? 0 }
            for (i, ch) in chapters.enumerated() {
                let startSec = Double(ch.startPositionTicks ?? 0) / 10_000_000
                let title = (ch.name?.isEmpty == false ? ch.name : nil)
                    ?? "\(self.loc.localized("player.chapters")) \(i + 1)"
                let chip = self.makeChapterChip(index: i, title: title, time: PlayerTimeFormat.ms(Int32(startSec * 1000)))
                self.chapterStack.addArrangedSubview(chip)
            }
            #if os(tvOS)
            self.chapterHeightConstraint?.constant = self.chapterPeekHeight
            #else
            self.chapterHeightConstraint?.constant = 150
            #endif
            self.chapterScroll.isHidden = false
            self.view.layoutIfNeeded()
            // Thumbnails load lazily so the strip appears instantly. Skip the
            // request entirely when the server has no chapter image for this
            // chapter (no `imageTag`) — the chip keeps its icon placeholder.
            for (i, ch) in chapters.enumerated() {
                guard let tag = ch.imageTag, !tag.isEmpty else { continue }
                let url = builder.chapterImageURL(itemId: id, imageIndex: i, tag: tag, maxWidth: 320)
                Task { @MainActor [weak self] in
                    guard let data = await Self.loadImage(url: url, token: token),
                          let img = UIImage(data: data), let self,
                          i < self.chapterStack.arrangedSubviews.count,
                          let chip = self.chapterStack.arrangedSubviews[i] as? UIButton,
                          let iv = chip.viewWithTag(99) as? UIImageView else { return }
                    iv.image = img
                    iv.contentMode = .scaleAspectFill
                }
            }
        }
    }

    private func makeChapterChip(index: Int, title: String, time: String) -> UIButton {
        let b = ChapterChip(type: .custom)
        b.tag = index
        #if os(tvOS)
        b.alpha = 0.5 // dimmed until focused — makes the focus highlight obvious
        #else
        b.alpha = 1.0 // touch platform: no focus dimming
        #endif
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(chapterChipTapped(_:)), for: .primaryActionTriggered)

        let thumb = UIImageView()
        thumb.tag = 99
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        // Intentional placeholder until (if) a real thumbnail loads.
        thumb.image = UIImage(systemName: "film",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular))
        thumb.tintColor = UIColor.white.withAlphaComponent(0.35)
        thumb.contentMode = .center
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 8

        let titleL = UILabel()
        titleL.translatesAutoresizingMaskIntoConstraints = false
        titleL.text = title
        titleL.font = .systemFont(ofSize: 19, weight: .semibold)
        titleL.textColor = .white
        titleL.lineBreakMode = .byTruncatingTail

        let timeL = UILabel()
        timeL.translatesAutoresizingMaskIntoConstraints = false
        timeL.text = time
        timeL.font = .monospacedDigitSystemFont(ofSize: 16, weight: .regular)
        timeL.textColor = UIColor.white.withAlphaComponent(0.7)

        b.addSubview(thumb)
        b.addSubview(titleL)
        b.addSubview(timeL)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 200),
            b.heightAnchor.constraint(equalToConstant: 150),
            thumb.topAnchor.constraint(equalTo: b.topAnchor),
            thumb.leadingAnchor.constraint(equalTo: b.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: b.trailingAnchor),
            thumb.heightAnchor.constraint(equalToConstant: 100),
            titleL.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 6),
            titleL.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 2),
            titleL.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -2),
            timeL.topAnchor.constraint(equalTo: titleL.bottomAnchor, constant: 1),
            timeL.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 2),
            timeL.bottomAnchor.constraint(lessThanOrEqualTo: b.bottomAnchor)
        ])
        return b
    }

    @objc private func chapterChipTapped(_ sender: UIButton) {
        let i = sender.tag
        guard i < chapterStartTicks.count else { return }
        engineSeek(ms: Int32(chapterStartTicks[i] / 10_000))
        showSkipHUD(PlayerTimeFormat.ms(Int32(chapterStartTicks[i] / 10_000)))
        refreshTimeUISoon()
        scheduleHideControls()
    }

    /// Downloads one chapter thumbnail. Sends the token both as the
    /// `api_key` query param (what Jellyfin image endpoints expect) and as the
    /// Authorization header, so it works regardless of server hardening.
    nonisolated private static func loadImage(url: URL, token: String?) async -> Data? {
        let authed = VLCStreamPresenter.authedURL(url, token: token)
        var request = URLRequest(url: authed)
        if let token { request.setValue("MediaBrowser Token=\(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await URLSession.shared.data(for: request) else {
            #if DEBUG
            logger.debug("CINEMAX-CHAPTERIMG ▸ request failed \(redactedURL(authed))")
            #endif
            return nil
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        #if DEBUG
        logger.debug("CINEMAX-CHAPTERIMG ▸ status=\(code) bytes=\(data.count) \(redactedURL(authed))")
        #endif
        guard (200..<300).contains(code), !data.isEmpty else { return nil }
        return data
    }

    // MARK: - Center / skip glyph (shared)

    /// Brief native-style center glyph when play/pause toggles.
    private func flashCenterGlyph(playing: Bool) {
        centerGlyphHide?.cancel()
        centerGlyph.image = UIImage(
            systemName: playing ? "play.fill" : "pause.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 52, weight: .bold)
        )
        centerGlyph.alpha = 1
        centerGlyph.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        UIView.animate(withDuration: 0.2) { self.centerGlyph.transform = .identity }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.35) { self?.centerGlyph.alpha = 0 }
        }
        centerGlyphHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
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

    /// Native-style ±N s indicator (N = `PlayerSkipConfig.intervalSeconds`),
    /// briefly flashed with a small bounce.
    private func showSkipGlyph(forward: Bool) {
        skipGlyphHide?.cancel()
        skipGlyph.image = UIImage(
            systemName: forward ? PlayerSkipConfig.forwardSymbol : PlayerSkipConfig.backwardSymbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
        )
        skipGlyph.alpha = 1
        skipGlyph.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        UIView.animate(withDuration: 0.18) { self.skipGlyph.transform = .identity }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.skipGlyph.alpha = 0 }
        }
        skipGlyphHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    @objc private func prevEpisodeTapped() { if let p = previousEpisode { navigateToEpisode(p) } }
    @objc private func nextEpisodeTapped() { if let n = nextEpisode { navigateToEpisode(n) } }

    #if os(tvOS)
    private func updateScrubBar(progress: Float) {
        tvScrub.setProgress(progress)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        controlsContainer.alpha > 0 ? [tvScrub] : []
    }
    #endif

    // MARK: - Single-purpose track pickers

    private func presentPicker(_ title: String,
                               sourceView: UIView? = nil,
                               _ options: [(title: String, selected: Bool, action: () -> Void)]) {
        pickerPresented = true
        hideControlsWorkItem?.cancel()
        showControls()
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for opt in options {
            sheet.addAction(UIAlertAction(title: opt.title + (opt.selected ? "  ✓" : ""), style: .default) { [weak self] _ in
                opt.action()
                self?.endPicker()
            })
        }
        sheet.addAction(UIAlertAction(title: loc.localized("action.cancel"), style: .cancel) { [weak self] _ in
            self?.endPicker()
        })
        if let pop = sheet.popoverPresentationController, let sv = sourceView {
            pop.sourceView = sv
            pop.sourceRect = sv.bounds
        }
        present(sheet, animated: true)
    }

    private func endPicker() {
        pickerPresented = false
        showControls()
        scheduleHideControls()
    }

    /// Prefer Jellyfin's DisplayTitle (nicer than libVLC's "Track 1"), mapped
    /// by ordinal within the type; fall back to the SwiftVLC track name.
    private func displayLabel(forAudioOrdinal i: Int, track: Track) -> String {
        if i < info.audioTracks.count { return info.audioTracks[i].label }
        if let lang = track.language, !lang.isEmpty { return "\(track.name) (\(lang))" }
        return track.name
    }

    private func displayLabel(forSubtitleOrdinal i: Int, track: Track) -> String {
        if i < info.subtitleTracks.count { return info.subtitleTracks[i].label }
        if let lang = track.language, !lang.isEmpty { return "\(track.name) (\(lang))" }
        return track.name
    }

    @objc private func openAudioMenu() {
        var opts: [(String, Bool, () -> Void)] = []
        for (i, track) in player.audioTracks.enumerated() {
            let selected = player.selectedAudioTrack == track
            opts.append((displayLabel(forAudioOrdinal: i, track: track), selected, { [weak self] in
                self?.player.selectedAudioTrack = track
            }))
        }
        presentPicker(loc.localized("player.audio"), sourceView: audioPickerSource, opts)
    }

    @objc private func openSubtitleMenu() {
        var opts: [(String, Bool, () -> Void)] = []
        opts.append((loc.localized("player.subtitles.off"),
                     player.selectedSubtitleTrack == nil,
                     { [weak self] in self?.player.selectedSubtitleTrack = nil }))
        for (i, track) in player.subtitleTracks.enumerated() {
            let selected = player.selectedSubtitleTrack == track
            opts.append((displayLabel(forSubtitleOrdinal: i, track: track), selected, { [weak self] in
                self?.player.selectedSubtitleTrack = track
            }))
        }
        presentPicker(loc.localized("player.subtitles"), sourceView: subtitlePickerSource, opts)
    }

    /// Apply Jellyfin's negotiated default audio/subtitle (absolute stream
    /// index) onto SwiftVLC tracks by ordinal-within-type. Runs once per media
    /// (on `.tracksChanged`); `selectedSubtitleIndex` nil/-1 ⇒ off.
    private func applyServerTrackDefaultsIfNeeded() {
        guard !didApplyServerTrackDefaults, !player.audioTracks.isEmpty else { return }
        didApplyServerTrackDefaults = true

        if let wantAudio = info.selectedAudioIndex,
           let ordinal = info.audioTracks.firstIndex(where: { $0.id == wantAudio }),
           ordinal < player.audioTracks.count {
            player.selectedAudioTrack = player.audioTracks[ordinal]
        }

        if let wantSub = info.selectedSubtitleIndex, wantSub >= 0,
           let ordinal = info.subtitleTracks.firstIndex(where: { $0.id == wantSub }),
           ordinal < player.subtitleTracks.count {
            player.selectedSubtitleTrack = player.subtitleTracks[ordinal]
        } else {
            player.selectedSubtitleTrack = nil
        }
    }

    // MARK: - Playback

    private func startPlayback() {
        hasValidTime = false
        didApplyServerTrackDefaults = false
        mediaLengthMs = 0
        let url = VLCStreamPresenter.authedURL(info.url, token: info.authToken)
        guard let media = makeMedia(url) else { handlePlaybackError(); return }
        startEventLoop()
        lastPlayStart = Date()
        try? player.play(media)
        reporter?.reportStart(startTime: startTime)
        startProgressTimer()
        fetchSegments()
        startSleepTimerIfNeeded()
        fetchChapters()
    }

    @objc private func playPauseTapped() {
        let willPlay = !enginePlaying
        if enginePlaying { enginePause() } else { enginePlay() }
        flashCenterGlyph(playing: willPlay)
        #if os(iOS)
        setPlayPauseIcon(playing: willPlay)
        #endif
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
            self.hasValidTime = false
            self.didRetry = false
            self.didReportEnd = false
            self.didApplyServerTrackDefaults = false
            self.mediaLengthMs = 0
            self.previousEpisode = nav?.1
            self.nextEpisode = nav?.2
            self.titleLabel.text = ref.title
            let url = VLCStreamPresenter.authedURL(vlcInfo.url, token: vlcInfo.authToken)
            guard let media = self.makeMedia(url) else { self.handlePlaybackError(); return }
            self.lastPlayStart = Date()
            try? self.player.play(media)
            self.refreshTimeUISoon()
            self.reporter?.resetTicking()
            self.reporter?.reportStart(startTime: nil)
            self.startProgressTimer()
            self.fetchSegments()
            self.startSleepTimerIfNeeded()
            self.fetchChapters()
            self.remoteCommands.attach(
                previous: self.previousEpisode, next: self.nextEpisode,
                hasNavigator: true
            )
            self.showControls()
            self.scheduleHideControls()
        }
    }

    #if os(iOS)
    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    /// Native Picture-in-Picture via SwiftVLC's libVLC pixel-buffer →
    /// `AVPictureInPictureController` pipeline (works for all content incl.
    /// MKV/Dolby-Vision — no AVPlayer handoff needed).
    @objc private func pipTapped() {
        guard let pip = pipController, pip.isPossible else { return }
        pip.toggle()
    }

    /// Single tap → toggle HUD (deferred ~0.28 s so a double tap can pre-empt
    /// it). Double tap → seek ∓15 s by screen half; a hidden HUD stays hidden
    /// (skip glyph is the only feedback), a visible HUD just gets its timer
    /// reset.
    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let now = CACurrentMediaTime()
        let x = g.location(in: view).x
        if now - lastTapTime < 0.30 {
            // Second tap inside the window → double tap (seek).
            pendingTapWork?.cancel()
            pendingTapWork = nil
            lastTapTime = 0
            if x < view.bounds.width / 2 {
                engineSeek(bySeconds: -PlayerSkipConfig.intervalSeconds)
                showSkipGlyph(forward: false)
            } else {
                engineSeek(bySeconds: PlayerSkipConfig.intervalSeconds)
                showSkipGlyph(forward: true)
            }
            refreshTimeUISoon()
            if controlsVisible { scheduleHideControls() }
            return
        }
        lastTapTime = now
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastTapTime = 0
            self.pendingTapWork = nil
            if self.controlsVisible { self.hideControlsImmediately() }
            else { self.showControls(); self.scheduleHideControls() }
        }
        pendingTapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    @objc private func iosSkipBack() {
        engineSeek(bySeconds: -PlayerSkipConfig.intervalSeconds)
        showSkipGlyph(forward: false)
        refreshTimeUISoon()
        scheduleHideControls()
    }

    @objc private func iosSkipForward() {
        engineSeek(bySeconds: PlayerSkipConfig.intervalSeconds)
        showSkipGlyph(forward: true)
        refreshTimeUISoon()
        scheduleHideControls()
    }

    @objc private func scrubberTouchDown() {
        isScrubbing = true
        // Freeze the HUD for the whole drag — re-armed on touch-up.
        hideControlsWorkItem?.cancel()
    }

    @objc private func scrubberChanged() {
        isScrubbing = true
        hideControlsWorkItem?.cancel()
        let length = lengthMs
        guard length > 0 else { return }
        timeLabel.text = PlayerTimeFormat.ms(Int32(Float(length) * slider.value))
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
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .bold))
        playPauseButton.configuration = config
    }
    #endif

    // MARK: - Auto-hide

    /// Any drag of the chapter strip counts as interaction — keep the HUD alive
    /// and re-arm the hide timer once the user stops.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if controlsVisible { scheduleHideControls() }
    }

    private func scheduleHideControls() {
        hideControlsWorkItem?.cancel()
        // Never auto-hide while a track/chapter picker is up — the controls must
        // stay put behind it so focus returns somewhere sensible.
        if pickerPresented { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pickerPresented else { return }
            self.hideControlsImmediately()
        }
        hideControlsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func hideControlsImmediately() {
        controlsVisible = false
        UIView.animate(withDuration: 0.25) { self.controlsContainer.alpha = 0 }
        controlsContainer.isUserInteractionEnabled = false
        #if os(tvOS)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        #endif
    }

    private func showControls() {
        controlsVisible = true
        UIView.animate(withDuration: 0.2) { self.controlsContainer.alpha = 1 }
        controlsContainer.isUserInteractionEnabled = true
        #if os(tvOS)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        #endif
    }

    // MARK: - Engine events (was VLCMediaPlayerDelegate)

    /// SwiftVLC has no distinct `.ended` state — libVLC 4.0 end-of-media
    /// surfaces as `.stopped`. Distinguish a natural end (autoplay / overlay)
    /// from teardown / media-swap via the tear-down flag + a near-end / not-
    /// just-started guard.
    private func onEngineStateChanged(_ state: PlayerState) {
        switch state {
        case .error:
            handlePlaybackError()
        case .stopped:
            guard !isTearingDown,
                  Date().timeIntervalSince(lastPlayStart) > 1.0,
                  lengthMs > 0, currentMs >= lengthMs - 2000 else { return }
            handlePlaybackEnded()
        case .playing:
            didRetry = false
            #if os(iOS)
            setPlayPauseIcon(playing: true)
            #endif
        case .paused:
            #if os(iOS)
            setPlayPauseIcon(playing: false)
            #endif
        default: break
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
            if let media = try? Media(url: url) {
                media.addOption(":network-caching=5000")
                lastPlayStart = Date()
                try? player.play(media)
            }
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

    private func onEngineTimeChanged() {
        refreshTimeUI()
        if currentMs > 0 { hasValidTime = true }
        if !didSeekToStart, let start = startTime, start > 0, lengthMs > 0 {
            didSeekToStart = true
            engineSeek(ms: Int32(start * 1000))
        }
    }

    /// Repaints the scrub bar + time labels from the player's current position.
    /// Driven by `mediaPlayerTimeChanged` while playing, AND called explicitly
    /// after every programmatic seek — VLC doesn't emit time updates while
    /// paused, so without this a seek-while-paused wouldn't move the bar.
    private func refreshTimeUI() {
        let currentMs = self.currentMs
        let lengthMs = self.lengthMs
        #if os(iOS)
        if !isScrubbing {
            timeLabel.text = PlayerTimeFormat.ms(currentMs)
            durationLabel.text = "-" + PlayerTimeFormat.ms(max(0, lengthMs - currentMs))
            if lengthMs > 0 { slider.value = Float(currentMs) / Float(lengthMs) }
        }
        #else
        timeLabel.text = PlayerTimeFormat.ms(currentMs)
        durationLabel.text = "-" + PlayerTimeFormat.ms(max(0, lengthMs - currentMs))
        if lengthMs > 0 { updateScrubBar(progress: Float(currentMs) / Float(lengthMs)) }
        #endif
    }

    /// Refreshes now and again shortly after — VLC applies a seek asynchronously,
    /// so `mediaPlayer.time` may not reflect the new position for a beat.
    private func refreshTimeUISoon() {
        refreshTimeUI()
        for delay in [0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshTimeUI()
            }
        }
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

/// Chapter strip cell. On tvOS, custom buttons get no system focus appearance,
/// so it draws its own: a clear lift + white ring on the thumbnail + un-dimming
/// so the focused chapter is unmistakable. On iOS it never receives focus, so
/// `didUpdateFocus` simply never fires and it behaves as a plain button.
private final class ChapterChip: UIButton {
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

/// SwiftUI host for the SwiftVLC rendering surface. iOS uses `PiPVideoView`
/// (libVLC pixel-buffer → `AVPictureInPictureController`) and publishes the
/// `PiPController` back to the presenter; tvOS uses plain `VideoView` (no PiP).
@MainActor
private struct EngineSurface: View {
    let player: Player
    var onController: (AnyObject?) -> Void = { _ in }
    #if os(iOS)
    @State private var controller: PiPController?
    #endif

    var body: some View {
        #if os(iOS)
        PiPVideoView(player, controller: Binding(
            get: { controller },
            set: { controller = $0; onController($0) }
        ))
        #else
        VideoView(player)
        #endif
    }
}

/// HUD container that lets taps on its own (scrim/empty) area fall through to
/// the video view beneath — which hosts the tap recognizer. Taps that land on
/// an actual control (button / slider / chapter strip) are returned normally,
/// so the controls keep working and the tap-to-toggle never conflicts with
/// them. On tvOS it behaves like a plain `UIView` (focus, not hit-testing).
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        #if os(iOS)
        return hit === self ? nil : hit
        #else
        return hit
        #endif
    }
}
