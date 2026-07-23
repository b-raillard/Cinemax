import UIKit
import SwiftUI
import QuartzCore
import AVFAudio
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

/// VLC player (iOS + tvOS) for online streaming. VLC DirectPlays the raw
/// Jellyfin file (MKV / HEVC 10-bit / Dolby Vision) so the server performs **no
/// transcode** — eliminating the slow-transcode segment thrash that froze
/// `AVPlayer`.
///
/// Feature parity: playback + resume, Jellyfin progress reporting, episode
/// prev/next + auto-play-next, audio/subtitle selection, skip intro/outro,
/// sleep timer + still-watching, end-of-series overlay, chapter navigation,
/// single error retry.
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
    private let _initialItemId: String
    /// The `render4K`-derived ceiling the INITIAL play negotiated with. Carried
    /// so the wake re-resolve re-uses the SAME ceiling — otherwise it falls back
    /// to the API's 40 Mbps default and a >40 Mbps 4K remux that DirectPlayed on
    /// launch would get force-transcoded on resume.
    private let maxBitrate: Int

    private weak var hostingVC: VLCStreamViewController?

    /// Stream init — online playback negotiated through Jellyfin's PlaybackInfo
    /// flow with VLC's broad DirectPlay profile.
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
        maxBitrate: Int,
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
        self.maxBitrate = maxBitrate
        self.imageBuilder = imageBuilder
        self.loc = loc
        self.onDismiss = onDismiss
        self._initialItemId = itemId
    }

    /// Presents modally on top of the active scene and starts streaming.
    func present(info: PlaybackInfo) {
        guard let topVC = Self.topMostViewController() else {
            logger.error("VLC stream present: no top view controller")
            onDismiss?()
            return
        }
        let vc = VLCStreamViewController(
            itemId: _initialItemId, info: info, title: title, startTime: startTime,
            previousEpisode: previousEpisode, nextEpisode: nextEpisode,
            episodeNavigator: episodeNavigator, apiClient: apiClient, userId: userId,
            autoPlayNext: autoPlayNext, maxBitrate: maxBitrate,
            imageBuilder: imageBuilder, loc: loc, onDismiss: onDismiss
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

private final class VLCStreamViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
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
    /// Bitrate ceiling the current negotiation uses — reused on wake re-resolve
    /// so resume keeps the same DirectPlay/transcode verdict. Mutable because the
    /// in-player quality selector overrides it per session (see `openQualityMenu`).
    private var maxBitrate: Int
    /// The `render4K`-derived ceiling the INITIAL play negotiated with — the
    /// "Auto" quality option restores it. Per-session only, never persisted.
    private let initialMaxBitrate: Int
    /// False once the user pins a specific bitrate ceiling from the quality menu.
    private var bitrateIsAuto = true
    /// Bitrate ceilings offered by the in-player quality selector (bits/s),
    /// alongside "Auto" (= `initialMaxBitrate`).
    private static let bitrateOptions: [Int] = [20_000_000, 8_000_000, 4_000_000, 2_000_000]
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
    // center play/pause flash, and a native ±10 s skip indicator.
    private let chapterScroll = UIScrollView()
    private let chapterStack = UIStackView()
    private var chapterFetchTask: Task<Void, Never>?
    // Lazy thumbnail loads spawned by fetchChapters — tracked so an episode
    // swap / dismiss cancels the previous episode's in-flight image downloads
    // instead of letting them race the new stream's open on slow links.
    private var chapterThumbTasks: [Task<Void, Never>] = []
    private var chapterStartTicks: [Int] = []
    private var chapterHeightConstraint: NSLayoutConstraint?
    private let centerGlyph = UIImageView()
    private var centerGlyphHide: DispatchWorkItem?
    private let skipGlyph = UIImageView()
    private var skipGlyphHide: DispatchWorkItem?
    /// Centered "loading" spinner. Shown whenever the engine is opening or
    /// (re)buffering — initial open, a mid-stream retry, a network re-buffer —
    /// so a stall reads as "working on it" instead of a frozen frame, and a
    /// retry confirms the action registered. Hidden the moment frames flow.
    private let loadingIndicator = UIActivityIndicatorView(style: .large)

    // Trickplay scrub previews (server-generated thumbnail grids). The bubble
    // is shown only while scrubbing; `TrickplayController` resolves position →
    // cropped thumb and re-fires `onTileLoaded` when an async tile lands.
    private let trickplay = TrickplayController()
    private let scrubPreview = UIImageView()
    private var scrubPreviewCenterX: NSLayoutConstraint?
    private var lastPreviewMs: Int32 = 0

    // Playback speed. Persisted per-session only (deliberate — 2× is a viewing
    // mode, not a setting). libVLC resets rate on media swap, so `.playing`
    // re-applies it after episode nav / retry.
    private var playbackRate: Float = 1.0
    private static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // Audio/subtitle delay in ms (positive = track plays later). Reset on
    // every media change — delays compensate per-file mux drift.
    private var audioDelayMsState = 0
    private var subtitleDelayMsState = 0

    // Stats overlay ("nerd stats") — repainted by the 1s tick while visible.
    private let statsLabel = UILabel()
    private var statsVisible = false

    // Next-episode countdown card (outro + autoPlayNext + nextEpisode).
    private var nextUpCard: NextUpCountdownView?
    private var nextUpCancelledForThisItem = false

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
    /// Interactive swipe-down-to-dismiss: the whole player surface follows the
    /// finger; releasing past the threshold (or flicking down) closes the
    /// player, otherwise it springs back.
    private var dismissPan: UIPanGestureRecognizer?
    /// True once the current drag has crossed the dismiss threshold — gates the
    /// haptic tick so it fires once per crossing, not every frame.
    private var dismissPastThreshold = false
    private let dismissHaptic = UIImpactFeedbackGenerator(style: .medium)
    /// Hold-to-2× (YouTube style): long-press on the bare video surface plays
    /// at 2× while held, restoring the user's chosen rate on release.
    private var holdPress: UILongPressGestureRecognizer?
    private var isHoldBoosting = false
    private let speedButton = UIButton(type: .system)
    private let statsButton = UIButton(type: .system)
    private let qualityButton = UIButton(type: .system)
    #else
    // tvOS custom transport: a focusable scrub bar + a focusable control row.
    // No on-screen Play/Pause button — the Siri Remote has a physical one;
    // feedback is the center glyph flash only.
    private let tvScrub = TVScrubBar()
    private let controlBar = UIStackView()
    /// True while the user is sliding the scrub bar via the Siri Remote touch
    /// surface — suppresses the periodic time tick so the preview isn't
    /// snapped back (mirrors the iOS slider's `isScrubbing`).
    private var isScrubbing = false
    private let tvAudioButton = UIButton(type: .system)
    private let tvSubtitleButton = UIButton(type: .system)
    private let tvPrevButton = UIButton(type: .system)
    private let tvNextButton = UIButton(type: .system)
    private let tvSpeedButton = UIButton(type: .system)
    /// tvOS info panel (native convention: swipe down on the touch surface
    /// while watching opens a settings strip): speed / audio / subtitles /
    /// delays / stats. Shown only while the HUD is hidden — when the HUD is
    /// up, down-swipes belong to the focus engine.
    private let infoPanel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let infoPanelStack = UIStackView()
    private var infoPanelVisible = false
    #endif

    /// Set on scrub release / coalesced skip: VLC applies a seek asynchronously,
    /// so until `currentMs` reaches this the periodic tick must keep showing the
    /// target instead of snapping back to the stale pre-seek position. Shared by
    /// both platforms (the iOS slider and the tvOS scrub bar both honor it).
    private var pendingScrubTargetMs: Int32?
    /// Debounced commit for coalesced ±N skips / chapter jumps. Each press
    /// advances `pendingScrubTargetMs` (the on-screen target) and re-arms this;
    /// the single engine seek fires `seekCommitDelay` after the LAST press. See
    /// `accumulateSeek`.
    private var seekCommitWork: DispatchWorkItem?
    private let seekCommitDelay: TimeInterval = 0.3

    private var reporter: PlaybackReporter?
    private let remoteCommands: RemoteCommandController
    private let nowPlaying: NowPlayingInfoController
    private var progressTimer: Timer?
    private var hideControlsWorkItem: DispatchWorkItem?
    private var didSeekToStart = false
    /// True once the player has reported a real (non-zero) position. The skip
    /// intro/outro button stays hidden until then — otherwise a segment that
    /// starts at 0 flashes the button during the loading spinner.
    private var hasValidTime = false
    /// Last real (non-zero) playhead position, in ms. Tracked every tick so a
    /// mid-stream error retry can resume at the point it dropped instead of
    /// restarting at 0 (the initial resume-seek has already fired by then, so
    /// `startTime` alone wouldn't re-seek). See `handlePlaybackError`.
    private var lastKnownPositionMs: Int32 = 0
    /// Explicit HUD state so single-tap toggling never depends on mid-animation
    /// `alpha` reads.
    private var controlsVisible = true
    /// Debounce for the Menu button: a single press can be delivered to both
    /// the press gesture recognizer and `pressesBegan`; this collapses them to
    /// one peel action so it never hides-then-dismisses on a single press.
    private var lastMenuHandledAt = Date.distantPast
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
    // Held weakly so a late-arriving successful open can tear down the failure
    // alert (libVLC's connection can complete after the watchdog gave up).
    private weak var errorAlert: UIAlertController?
    // Wall-clock of the first play() of this session, so the watchdog/error
    // logs can report the user-perceived open delay.
    private var firstPlayStart = Date.distantPast
    // Whether the current media is being fetched through the in-app loopback
    // proxy (broken-IPv6 servers). Lets the error fallback avoid re-proxying.
    private var usingProxy = false

    // SwiftVLC end-of-media disambiguation: `.stopped` fires for natural end,
    // teardown, AND media swap. `isTearingDown` suppresses end handling during
    // dismissal; `lastPlayStart` ignores the `.stopped` that can follow a
    // fresh `play(media)` (old media winding down).
    private var isTearingDown = false
    private var lastPlayStart = Date.distantPast

    // Episode-nav race guard (same pattern as NowPlayingInfoController):
    // bumped at every navigateToEpisode call and re-checked after its awaits so
    // a slow PlaybackInfo can't apply stale state over a newer navigation —
    // and never after teardown (which would restart the engine and re-arm a
    // progress timer nothing will ever invalidate).
    private var navGeneration = 0

    // App-lifecycle wake resilience. When the device sleeps (Apple TV / phone
    // locked) mid-playback, the stream socket dies AND the OS invalidates the
    // hardware VideoToolbox decode session + the audio session. On resume we
    // re-resolve a FRESH PlaybackInfo (new api_key + playSessionId) and rebuild
    // playback from where we left off. **Recovery runs on `didBecomeActive`, not
    // `willEnterForeground`** — tvOS won't hand out a valid VT hardware session
    // (or let the audio session activate) until the app is genuinely
    // foreground-active, so restarting any earlier reproduces the original bug:
    // a black frame (invalid VT session) with audio (`561015905`) errors flooding.
    private var didBackgroundWhilePlaying = false
    private var positionAtBackgroundMs: Int32 = 0
    private var backgroundedAt: Date?
    private var isReResolvingAfterWake = false
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    // A background longer than this is a genuine sleep/power-off: the VT decode
    // session is dead even if libVLC still reports `.playing`/`.paused`, so we
    // rebuild unconditionally. A shorter blip only rebuilds if the engine died.
    private static let wakeRebuildThreshold: TimeInterval = 8

    // "Media never opened" watchdog. libVLC 4.0 can fail to open a stream
    // (server 404/416 on the static URL, codec the demuxer rejects) by going
    // straight to `.stopped` with `lengthMs == 0` and emitting no
    // `.encounteredError` — none of the end/error guards match, so the user
    // is stranded on a frozen black screen. This fires if no valid time AND no
    // length has arrived within the timeout, routing to the normal error path.
    private var openWatchdog: Timer?
    // Short leash on the first attempt so a stalled open (e.g. degraded IPv6)
    // falls back to the proxy retry fast; the retry gets the longer leash.
    private static let firstOpenTimeout: TimeInterval = 15
    private static let retryOpenTimeout: TimeInterval = 30

    // Polish: a track/chapter picker is up — freeze the HUD behind it.
    private var pickerPresented = false

    // MARK: - SyncPlay ("Watch Together")
    // When the shared controller reports we're in a group at bind time, the
    // presenter's play/pause/seek entry points route through it (the server
    // echoes the command and THAT is what moves the playhead) instead of
    // touching the local engine.
    private let syncPlay = SyncPlayController.shared
    private var syncPlayActive = false
    private let syncPlayPill = UILabel()

    init(
        itemId: String, info: PlaybackInfo, title: String, startTime: Double?,
        previousEpisode: EpisodeRef?, nextEpisode: EpisodeRef?,
        episodeNavigator: EpisodeNavigator?, apiClient: any PlaybackAPI & LibraryAPI,
        userId: String, autoPlayNext: Bool, maxBitrate: Int, imageBuilder: ImageURLBuilder,
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
        self.maxBitrate = maxBitrate
        self.initialMaxBitrate = maxBitrate
        self.imageBuilder = imageBuilder
        self.loc = loc
        self.onDismiss = onDismiss
        var navTarget: ((EpisodeRef) -> Void)?
        var playPauseTarget: (() -> Void)?
        self.remoteCommands = RemoteCommandController(
            onNavigate: { ref in navTarget?(ref) },
            onTogglePlayPause: { playPauseTarget?() }
        )
        self.nowPlaying = NowPlayingInfoController(
            apiClient: apiClient, userId: userId,
            imageBuilder: imageBuilder, authToken: info.authToken
        )
        super.init(nibName: nil, bundle: nil)
        navTarget = { [weak self] ref in self?.navigateToEpisode(ref) }
        playPauseTarget = { [weak self] in self?.handleRemotePlayPause() }
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
        setupLifecycleObservers()
        bindSyncPlayIfNeeded()
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
        unbindSyncPlay()
        setLoading(false)
        cancelOpenWatchdog()
        progressTimer?.invalidate()
        progressTimer = nil
        remoteCommands.detach()
        nowPlaying.detach()
        hideControlsWorkItem?.cancel()
        pendingTapWork?.cancel()
        cancelPendingSeekCommit()
        segmentFetchTask?.cancel()
        chapterFetchTask?.cancel()
        chapterThumbTasks.forEach { $0.cancel() }
        chapterThumbTasks = []
        trickplay.reset()
        eventsTask?.cancel()
        eventsTask = nil
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let didBecomeActiveObserver { NotificationCenter.default.removeObserver(didBecomeActiveObserver) }
        backgroundObserver = nil
        didBecomeActiveObserver = nil
        #if os(iOS)
        pipController = nil
        #endif
        player.stop()
        deactivatePlaybackAudioSession()
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

    // MARK: Coalesced seeking
    //
    // A ±N skip used to fire an immediate relative `player.seek(by:)` on every
    // press, which storms a self-hosted / reverse-proxied origin with byte-range
    // open/cancel churn and can stall the stream. Instead we accumulate an
    // ABSOLUTE target and commit ONE engine seek a beat after the last press; the
    // HUD jumps to the projected position immediately so it reads as responsive,
    // not less. The pure target math (exact accumulation + near-end clamp) lives
    // in `SeekCoalescer` so it can be unit-tested without a live player; this
    // method owns only the debounce timer, the pending-target storage, the HUD
    // repaint, and the engine seek.

    /// Accumulate a ±N skip: advance the pending target from the last target
    /// (or the live position if none) and re-arm the debounced commit.
    private func seek(bySeconds delta: Int) {
        accumulateSeek(toAbsoluteMs: SeekCoalescer.relativeTarget(
            deltaSeconds: delta, pendingMs: pendingScrubTargetMs, currentMs: currentMs))
    }

    /// Set an absolute pending target, paint it immediately, and (re)arm the
    /// single debounced engine seek. Shared by ±N skips and chapter jumps.
    private func accumulateSeek(toAbsoluteMs target: Int32) {
        let len = lengthMs
        let clamped = SeekCoalescer.clamp(target: target, lengthMs: len)
        pendingScrubTargetMs = clamped // also holds the bar until VLC catches up
        paintPosition(clamped, lengthMs: len)
        seekCommitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitPendingSeek() }
        seekCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seekCommitDelay, execute: work)
    }

    /// Fire the one accumulated seek. `pendingScrubTargetMs` stays set so the
    /// periodic tick keeps showing the target until VLC's position reaches it
    /// (no snap-back); it clears itself in `refreshTimeUI`.
    private func commitPendingSeek() {
        seekCommitWork = nil
        guard let target = pendingScrubTargetMs else { return }
        userEngineSeek(ms: target)
        refreshTimeUISoon()
    }

    /// Drop any uncommitted skip (scrub takeover, media reload, teardown) so a
    /// stale target can't seek the wrong position / a freshly-loaded episode.
    private func cancelPendingSeekCommit() {
        seekCommitWork?.cancel()
        seekCommitWork = nil
        pendingScrubTargetMs = nil
    }

    private func enginePlay() { player.resume() }
    private func enginePause() { player.pause() }

    /// Shows/hides the centered loading spinner. Driven from playback start, the
    /// retry path, and engine state changes (opening/buffering → on; playing/
    /// paused → off); also force-cleared once real frames flow.
    private func setLoading(_ loading: Bool) {
        if loading { loadingIndicator.startAnimating() }
        else { loadingIndicator.stopAnimating() }
    }

    /// Builds the SwiftVLC `Media` for a streamed URL with `network-caching`
    /// (matches the VLCKit path).
    private func makeMedia(_ url: URL) -> Media? {
        guard let media = try? Media(url: url) else { return nil }
        // 5 s read-ahead (was 3 s): a deeper cushion rides out a transient
        // origin drop and, crucially, gives the proxy's transparent
        // reconnect time to re-establish the upstream BEFORE the buffer
        // drains — so the drop stays invisible. Costs ~2 s of extra initial
        // buffering; matches the retry path's network-caching.
        media.addOption(":network-caching=5000")
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
                    if self.mediaLengthMs > 0 {
                        self.cancelOpenWatchdog()
                        self.recoverFromErrorIfNeeded()
                    }
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
        // System-button targets (play/pause + prev/next on tvOS Siri Remote,
        // Lock Screen / CarPlay on iOS) attach for *every* session — play/pause
        // is the dedicated remote button (prev/next are suppressed when the
        // episode-nav graph is absent via nil EpisodeRefs + hasNavigator).
        remoteCommands.attach(
            previous: previousEpisode,
            next: nextEpisode,
            hasNavigator: episodeNavigator != nil
        )
        // Title / artwork / S×E× on the Lock Screen widget.
        nowPlaying.attach(itemId: itemId, title: titleText, durationSeconds: nil)
        reporter = PlaybackReporter(
            apiClient: apiClient,
            userId: userId,
            context: { [weak self] in
                guard let self else { return nil }
                // Live read, not a bound snapshot: the same reporter instance
                // survives episode swaps / wake re-resolves, and each report
                // must carry the CURRENT session's playSessionId.
                return PlaybackReporter.Context(itemId: self.itemId, info: self.info, player: nil)
            },
            timeSource: { [weak self] in
                guard let self else { return (0, true) }
                return (Double(self.currentMs) / 1000.0, !self.enginePlaying)
            }
        )
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
        let dur: Double? = lengthMs > 0 ? Double(lengthMs) / 1000 : nil
        nowPlaying.update(elapsed: now, duration: dur, rate: enginePlaying ? 1.0 : 0.0)
        updateSkipButton(currentTime: now)
        if statsVisible { refreshStats() }
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
            nextUpCard?.hide()
            activeSegmentType = nil
            return
        }
        for segment in segments {
            let start = Double(segment.startTicks ?? 0) / 10_000_000
            let end = Double(segment.endTicks ?? 0) / 10_000_000
            guard end > start, currentTime >= start, currentTime < end - 1 else { continue }
            // Outro with auto-play armed → the countdown card replaces "Skip
            // credits" (skipping to the end would just trigger the same nav).
            if segment.type == .outro, autoPlayNext, let next = nextEpisode,
               episodeNavigator != nil, !nextUpCancelledForThisItem {
                if activeSegmentType != nil {
                    activeSegmentType = nil
                    skipButton.isHidden = true
                }
                showNextUpCard(for: next)
                let totalSec = Double(lengthMs) / 1000
                nextUpCard?.update(secondsRemaining: Int((totalSec - currentTime).rounded()))
                return
            }
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
        nextUpCard?.hide()
    }

    /// Lazily builds the countdown card (it bakes in the next episode's title,
    /// so episode navigation tears it down for a fresh one).
    private func showNextUpCard(for next: EpisodeRef) {
        if nextUpCard == nil {
            let card = NextUpCountdownView(
                countdownFormat: loc.localized("player.nextUp.countdown"),
                episodeTitle: next.title,
                playTitle: loc.localized("player.nextUp.play"),
                cancelTitle: loc.localized("action.cancel")
            )
            card.onPlayNow = { [weak self] in
                guard let self, let n = self.nextEpisode else { return }
                self.nextUpCard?.hide()
                self.navigateToEpisode(n)
            }
            card.onCancel = { [weak self] in
                guard let self else { return }
                self.nextUpCancelledForThisItem = true
                self.nextUpCard?.hide()
                #if os(tvOS)
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
                #endif
            }
            view.addSubview(card)
            NSLayoutConstraint.activate([
                card.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
                card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -64)
            ])
            nextUpCard = card
        }
        let wasHidden = nextUpCard?.isHidden ?? true
        nextUpCard?.show()
        #if os(tvOS)
        if wasHidden {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
        #endif
    }

    private func tearDownNextUpCard() {
        nextUpCard?.removeFromSuperview()
        nextUpCard = nil
        nextUpCancelledForThisItem = false
    }

    @objc private func skipSegmentTapped() {
        for segment in segments where segment.type == activeSegmentType {
            let end = Int32(Double(segment.endTicks ?? 0) / 10_000_000 * 1000)
            userEngineSeek(ms: end)
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
        #if os(iOS)
        // Approximation of SleepTimerController's PiP gating (SwiftVLC's
        // PiPController exposes no reliable "is active" signal to mirror the
        // native delegate seam): when the app is .background — the PiP-window
        // viewing case — an alert presented here is unreachable, so pause
        // silently. `.inactive` (Control Center, notification shade, call
        // banner) still presents: the prompt is simply revealed when the
        // overlay drops, matching the native path.
        guard UIApplication.shared.applicationState != .background else { return }
        #endif
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
        let surface = PlayerEngineSurface(player: player) { [weak self] controller in
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

        // SyncPlay ("Watch Together") pill — sits just under the title, hidden
        // until a group binds. Same translucent rounded language as `skipHUD`.
        // The player HUD is always-dark and uses raw UIKit font sizes
        // throughout (matches `timeFont`/`hudFont` below), so hardcoded sizes
        // here are consistent with the file, not the SwiftUI CinemaFont rule.
        #if os(tvOS)
        let pillFont: CGFloat = 22
        let pillHeight: CGFloat = 40
        #else
        let pillFont: CGFloat = 13
        let pillHeight: CGFloat = 24
        #endif
        syncPlayPill.translatesAutoresizingMaskIntoConstraints = false
        syncPlayPill.font = .systemFont(ofSize: pillFont, weight: .semibold)
        syncPlayPill.textColor = .white
        syncPlayPill.textAlignment = .center
        syncPlayPill.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        syncPlayPill.layer.cornerRadius = pillHeight / 2
        syncPlayPill.clipsToBounds = true
        syncPlayPill.isHidden = true
        controlsContainer.addSubview(syncPlayPill)
        NSLayoutConstraint.activate([
            syncPlayPill.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            syncPlayPill.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            syncPlayPill.heightAnchor.constraint(equalToConstant: pillHeight)
        ])

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

        // Native-style center play/pause flash + ±10 s skip indicator. Shared
        // across platforms so iOS and tvOS speak the same visual language.
        centerGlyph.translatesAutoresizingMaskIntoConstraints = false
        centerGlyph.tintColor = .white
        centerGlyph.contentMode = .center
        centerGlyph.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        centerGlyph.clipsToBounds = true
        centerGlyph.alpha = 0
        view.addSubview(centerGlyph)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

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

        // Trickplay scrub-preview bubble. Lives on the controls container so it
        // fades with the HUD; horizontal position tracks the scrub location.
        scrubPreview.translatesAutoresizingMaskIntoConstraints = false
        scrubPreview.contentMode = .scaleAspectFill
        scrubPreview.clipsToBounds = true
        scrubPreview.layer.cornerRadius = 8
        scrubPreview.layer.borderWidth = 2
        scrubPreview.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        scrubPreview.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        scrubPreview.isHidden = true
        controlsContainer.addSubview(scrubPreview)
        trickplay.onTileLoaded = { [weak self] in self?.refreshScrubPreviewImage() }

        // Stats overlay — anchored under the title, outside the HUD container
        // so it stays readable while the controls are hidden.
        let statsContainer = UIView()
        statsContainer.translatesAutoresizingMaskIntoConstraints = false
        statsContainer.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statsContainer.layer.cornerRadius = 10
        statsContainer.isHidden = true
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.numberOfLines = 0
        statsLabel.textColor = .white
        #if os(tvOS)
        statsLabel.font = .monospacedSystemFont(ofSize: 23, weight: .regular)
        #else
        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        #endif
        statsContainer.addSubview(statsLabel)
        view.addSubview(statsContainer)
        NSLayoutConstraint.activate([
            statsContainer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statsContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            statsLabel.topAnchor.constraint(equalTo: statsContainer.topAnchor, constant: 10),
            statsLabel.bottomAnchor.constraint(equalTo: statsContainer.bottomAnchor, constant: -10),
            statsLabel.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor, constant: 14),
            statsLabel.trailingAnchor.constraint(equalTo: statsContainer.trailingAnchor, constant: -14)
        ])

        #if os(tvOS)
        buildTVTransport(safe: safe)
        #else
        buildIOSTransport(safe: safe)
        #endif
    }

    private func setStatsVisible(_ visible: Bool) {
        statsVisible = visible
        statsLabel.superview?.isHidden = !visible
        if visible { refreshStats() }
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
        configureIOS(speedButton, "gauge.with.needle", pt: 17, loc.localized("player.speed"), compact: true)
        speedButton.addTarget(self, action: #selector(openSpeedMenu), for: .touchUpInside)
        controlsContainer.addSubview(speedButton)
        configureIOS(statsButton, "chart.xyaxis.line", pt: 17, loc.localized("player.stats"), compact: true)
        statsButton.addTarget(self, action: #selector(toggleStats), for: .touchUpInside)
        controlsContainer.addSubview(statsButton)
        configureIOS(qualityButton, "slider.horizontal.3", pt: 17, loc.localized("player.quality"), compact: true)
        qualityButton.addTarget(self, action: #selector(openQualityMenu), for: .touchUpInside)
        controlsContainer.addSubview(qualityButton)

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
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: qualityButton.leadingAnchor, constant: -12),
            subtitleButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            subtitleButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            audioButton.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -4),
            audioButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            pipButton.trailingAnchor.constraint(equalTo: audioButton.leadingAnchor, constant: -4),
            pipButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            speedButton.trailingAnchor.constraint(equalTo: pipButton.leadingAnchor, constant: -4),
            speedButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            statsButton.trailingAnchor.constraint(equalTo: speedButton.leadingAnchor, constant: -4),
            statsButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            qualityButton.trailingAnchor.constraint(equalTo: statsButton.leadingAnchor, constant: -4),
            qualityButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

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

        // Trickplay preview floats above the slider, tracking the thumb.
        let previewCenterX = scrubPreview.centerXAnchor.constraint(equalTo: slider.leadingAnchor)
        scrubPreviewCenterX = previewCenterX
        NSLayoutConstraint.activate([
            scrubPreview.widthAnchor.constraint(equalToConstant: 160),
            scrubPreview.heightAnchor.constraint(equalToConstant: 90),
            scrubPreview.bottomAnchor.constraint(equalTo: timeLabel.topAnchor, constant: -10),
            previewCenterX
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
    private var speedPickerSource: UIView? { speedButton }
    private var qualityPickerSource: UIView? { qualityButton }
    #else
    private var audioPickerSource: UIView? { nil }
    private var subtitlePickerSource: UIView? { nil }
    private var speedPickerSource: UIView? { nil }
    private var qualityPickerSource: UIView? { nil }
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

        // Swipe-down-to-dismiss. Lives on `videoView` like the tap (touches on
        // HUD controls / the chapter strip never reach it) and only begins on a
        // predominantly-downward drag, so horizontal chapter scrolls and the
        // slider stay untouched.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        videoView.addGestureRecognizer(pan)
        dismissPan = pan

        // Hold-to-2×: long-press on the bare video surface boosts to 2× while
        // held. Stationary by definition, so it never races the dismiss pan;
        // the shared delegate restricts it to bare-video touches like the pan.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldBoost(_:)))
        hold.minimumPressDuration = 0.5
        hold.delegate = self
        videoView.addGestureRecognizer(hold)
        holdPress = hold
        #else
        // Most presses flow through the responder chain to `pressesBegan` below;
        // the focus engine drives navigation; TVScrubBar seeks left/right only
        // while focused.
        //
        // Menu is the exception: it MUST be caught by a dedicated press gesture
        // recognizer on `view`, not by `pressesBegan`. While the HUD is visible
        // a control (`tvScrub`) holds focus, and a focused control lets tvOS run
        // its default "Menu dismisses the modal" before the press bubbles to the
        // controller — so the `pressesBegan` peel logic never fired and Menu shut
        // the player even with the HUD up. The recognizer intercepts Menu first
        // in every focus state (this is the canonical tvOS pattern; it was the
        // pre-`002819e` design, lost when Menu was folded into `pressesBegan`).
        let menuPress = UITapGestureRecognizer(target: self, action: #selector(handleMenuPress))
        menuPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuPress)

        // The one global gesture is the native "swipe down for the info panel" —
        // armed only while the HUD is hidden (down-swipes belong to the focus
        // engine while it's up).
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleInfoPanelSwipe))
        swipeDown.direction = .down
        swipeDown.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(swipeDown)
        #endif
    }

    #if os(tvOS)
    /// What a press should DO while the HUD is hidden. Each case wakes the HUD;
    /// select/Enter also toggles play/pause and left/right also skip ∓N s, so a
    /// hidden-HUD remote/keyboard isn't dead. Deliberately a whitelist — an
    /// unrecognized press returns nil and is ignored, so stray simulator key
    /// noise can't un-hide the HUD a beat before a real Menu press lands (that
    /// raced the Menu peel into an infinite hide/reveal loop). **Matches BOTH
    /// Siri-remote `PressType` AND hardware-keyboard `key.keyCode`** — keyboard
    /// arrows/Enter arrive only as `key.keyCode` (no arrow `PressType`), which is
    /// why they previously did nothing on the simulator.
    private enum HiddenHUDIntent { case playPause, skipBack, skipForward, revealOnly }

    private static func hiddenHUDIntent(for press: UIPress) -> HiddenHUDIntent? {
        switch press.type {
        case .select: return .playPause
        case .leftArrow: return .skipBack
        case .rightArrow: return .skipForward
        case .upArrow, .downArrow: return .revealOnly
        default: break
        }
        switch press.key?.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter, .keyboardSpacebar: return .playPause
        case .keyboardLeftArrow: return .skipBack
        case .keyboardRightArrow: return .skipForward
        case .keyboardUpArrow, .keyboardDownArrow: return .revealOnly
        default: return nil
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Menu (or keyboard Escape on the simulator) → peel one layer. Handled
        // HERE too (not only via the recognizer): when the HUD is hidden no
        // control is focused, so `pressesBegan` is the path that fires. Routing
        // through the shared, debounced `handleMenu` guarantees "hidden + Menu →
        // quit" and stops the press from reaching the wake path below.
        if presses.contains(where: { $0.type == .menu || $0.key?.keyCode == .keyboardEscape }) {
            handleMenu()
            return
        }
        for press in presses {
            if press.type == .playPause {
                playPauseTapped()
                revealControls()
                return
            }
        }
        // The info panel (or a visible next-up card over bare video) owns the
        // focus engine — let presses flow to its buttons instead of treating
        // them as "reveal the HUD".
        if infoPanelVisible {
            super.pressesBegan(presses, with: event)
            return
        }
        if let card = nextUpCard, !card.isHidden, controlsContainer.alpha == 0 {
            super.pressesBegan(presses, with: event)
            return
        }
        if controlsContainer.alpha == 0 {
            // HUD hidden: a recognized press performs its action AND wakes the
            // HUD — select/Enter toggles play/pause, left/right skip ∓N s, arrows
            // up/down just reveal. Unrecognized presses are ignored (see
            // `hiddenHUDIntent`) so they can't reveal the HUD ahead of a Menu
            // dismiss. `revealControls()` then moves focus to `tvScrub`, so the
            // NEXT press routes normally.
            guard let intent = presses.lazy.compactMap({ Self.hiddenHUDIntent(for: $0) }).first else {
                return
            }
            switch intent {
            case .playPause: playPauseTapped()
            case .skipBack: seek(bySeconds: -PlayerSkipConfig.intervalSeconds); showSkipGlyph(forward: false)
            case .skipForward: seek(bySeconds: PlayerSkipConfig.intervalSeconds); showSkipGlyph(forward: true)
            case .revealOnly: break
            }
            revealControls()
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

        // Focusable scrub bar: left/right seek ±10 s ONLY while it holds focus,
        // so the focus engine can move left/right between the control buttons
        // when the bar is not focused.
        tvScrub.translatesAutoresizingMaskIntoConstraints = false
        tvScrub.accessibilityLabel = loc.localized("player.scrubBar")
        tvScrub.onSeek = { [weak self] delta in
            guard let self else { return }
            let forward = delta >= 0
            self.seek(bySeconds: forward ? PlayerSkipConfig.intervalSeconds : -PlayerSkipConfig.intervalSeconds)
            self.showSkipGlyph(forward: forward)
            self.scheduleHideControls()
        }
        tvScrub.onSelect = { [weak self] in self?.playPauseTapped() }
        // Siri Remote touch-surface slide: live label preview while sliding
        // (no engine thrash), single seek committed on release.
        tvScrub.onScrubPreview = { [weak self] progress in
            guard let self else { return }
            self.isScrubbing = true
            self.cancelPendingSeekCommit() // a live drag supersedes a queued skip
            self.hideControlsWorkItem?.cancel()
            let len = self.lengthMs
            guard len > 0 else { return }
            let target = Int32(Float(len) * progress)
            self.timeLabel.text = PlayerTimeFormat.ms(target)
            self.durationLabel.text = "-" + PlayerTimeFormat.ms(max(0, len - target))
            self.updateTVScrubPreview(progress: progress, targetMs: target)
        }
        tvScrub.onScrubCommit = { [weak self] progress in
            guard let self else { return }
            self.scrubPreview.isHidden = true
            let len = self.lengthMs
            self.isScrubbing = false
            guard len > 0 else { self.scheduleHideControls(); return }
            let target = Int32(Float(len) * progress)
            // Hold the bar/labels at the target; the periodic tick keeps
            // showing it (not the stale pre-seek currentMs) until VLC's
            // position actually reaches it — no snap-back flicker.
            self.pendingScrubTargetMs = target
            self.timeLabel.text = PlayerTimeFormat.ms(target)
            self.durationLabel.text = "-" + PlayerTimeFormat.ms(max(0, len - target))
            self.updateScrubBar(progress: progress)
            self.userEngineSeek(ms: target)
            self.scheduleHideControls()
        }
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
        configureTV(tvSpeedButton, "gauge.with.needle", loc.localized("player.speed"))
        tvSpeedButton.addTarget(self, action: #selector(openSpeedMenu), for: .primaryActionTriggered)
        controlBar.addArrangedSubview(tvSpeedButton)

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
            // Pin to the chip's intrinsic 150pt, NOT the animating frame height
            // (40↔178) — tying 150pt chips to a 40pt frame floods Auto Layout.
            chapterStack.heightAnchor.constraint(equalToConstant: 150)
        ])
        let ch = chapterScroll.heightAnchor.constraint(equalToConstant: 0)
        ch.isActive = true
        chapterHeightConstraint = ch

        // Trickplay preview floats above the scrub bar, tracking the position.
        let previewCenterX = scrubPreview.centerXAnchor.constraint(equalTo: tvScrub.leadingAnchor)
        scrubPreviewCenterX = previewCenterX
        NSLayoutConstraint.activate([
            scrubPreview.widthAnchor.constraint(equalToConstant: 320),
            scrubPreview.heightAnchor.constraint(equalToConstant: 180),
            scrubPreview.bottomAnchor.constraint(equalTo: timeLabel.topAnchor, constant: -16),
            previewCenterX
        ])

        buildInfoPanel(safe: safe)
    }

    /// Top settings strip (speed / audio / subtitles / delays / stats) —
    /// opened by swiping down on the Siri Remote while the HUD is hidden,
    /// closed by Menu. Mirrors the native player's info panel convention.
    private func buildInfoPanel(safe: UILayoutGuide) {
        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.isHidden = true
        infoPanel.alpha = 0
        view.addSubview(infoPanel)

        infoPanelStack.translatesAutoresizingMaskIntoConstraints = false
        infoPanelStack.axis = .horizontal
        infoPanelStack.alignment = .center
        infoPanelStack.spacing = 12
        infoPanel.contentView.addSubview(infoPanelStack)

        let entries: [(String, String, Selector)] = [
            ("gauge.with.needle", "player.speed", #selector(openSpeedMenu)),
            ("slider.horizontal.3", "player.quality", #selector(openQualityMenu)),
            ("waveform", "player.audio", #selector(openAudioMenu)),
            ("captions.bubble", "player.subtitles", #selector(openSubtitleMenu)),
            ("waveform.badge.minus", "player.audioDelay", #selector(openAudioDelayMenu)),
            ("captions.bubble.fill", "player.subtitleDelay", #selector(openSubtitleDelayMenu)),
            ("chart.xyaxis.line", "player.stats", #selector(toggleStats))
        ]
        for (symbol, key, action) in entries {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold))
            cfg.title = loc.localized(key)
            cfg.imagePadding = 10
            cfg.baseForegroundColor = .white
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
            b.configuration = cfg
            b.addTarget(self, action: action, for: .primaryActionTriggered)
            infoPanelStack.addArrangedSubview(b)
        }

        NSLayoutConstraint.activate([
            infoPanel.topAnchor.constraint(equalTo: view.topAnchor),
            infoPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            infoPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoPanelStack.centerXAnchor.constraint(equalTo: infoPanel.contentView.centerXAnchor),
            infoPanelStack.topAnchor.constraint(equalTo: safe.topAnchor, constant: 24),
            infoPanelStack.bottomAnchor.constraint(equalTo: infoPanel.bottomAnchor, constant: -32)
        ])
    }

    /// Menu button target (press gesture recognizer). Routes to `handleMenu`.
    @objc private func handleMenuPress() { handleMenu() }

    /// Menu button — peels one layer at a time (matches the system
    /// `AVPlayerViewController`): info panel up → close it; HUD visible → hide
    /// it (and cancel the auto-hide timer); **bare video → exit the player**.
    ///
    /// Called from BOTH the press gesture recognizer AND `pressesBegan`, because
    /// tvOS routes the Menu press to different responders depending on focus:
    /// while a control holds focus (HUD visible) the recognizer wins over the
    /// system's default modal-dismiss; while the HUD is hidden no control is
    /// focused and `pressesBegan` is the only path that fires (see the note on
    /// `handleRemotePlayPause`). A single physical press can reach both within
    /// the same event, so `lastMenuHandledAt` debounces the duplicate.
    ///
    /// Keyed on `controlsContainer.alpha` (the VISUAL truth) — NOT the
    /// `controlsVisible` flag, which can disagree with what's on screen and was
    /// the source of the "Menu re-opens the HUD instead of quitting" loop.
    private func handleMenu() {
        let now = Date()
        if now.timeIntervalSince(lastMenuHandledAt) < 0.2 { return }
        lastMenuHandledAt = now
        if infoPanelVisible {
            setInfoPanelVisible(false)
        } else if controlsContainer.alpha > 0 {
            hideControlsWorkItem?.cancel()
            hideControlsImmediately()
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func handleInfoPanelSwipe() {
        // HUD up → the focus engine owns down-swipes; a picker up → ignore.
        guard !infoPanelVisible, controlsContainer.alpha == 0, !pickerPresented else { return }
        setInfoPanelVisible(true)
    }

    private func setInfoPanelVisible(_ visible: Bool) {
        infoPanelVisible = visible
        if visible {
            infoPanel.isHidden = false
            UIView.animate(withDuration: 0.25) { self.infoPanel.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.2) { self.infoPanel.alpha = 0 } completion: { _ in
                if !self.infoPanelVisible { self.infoPanel.isHidden = true }
            }
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
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
        chapterThumbTasks.forEach { $0.cancel() }
        chapterThumbTasks = []
        chapterStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chapterStartTicks = []
        chapterScroll.isHidden = true
        chapterHeightConstraint?.constant = 0
        trickplay.reset()
        scrubPreview.isHidden = true
        let client = apiClient, builder = imageBuilder, uid = userId
        let id = itemId
        let token = info.authToken
        let mediaSourceId = info.mediaSourceId
        chapterFetchTask = Task { @MainActor [weak self] in
            guard let item = try? await client.getItem(userId: uid, itemId: id),
                  !Task.isCancelled, let self else { return }
            // Same fetch feeds the trickplay manifest — no extra API call.
            self.trickplay.configure(item: item, itemId: id, mediaSourceId: mediaSourceId,
                                     token: token, imageBuilder: builder)
            guard let chapters = item.chapters, chapters.count > 1 else { return }
            self.chapterStartTicks = chapters.map { $0.startPositionTicks ?? 0 }
            for (i, ch) in chapters.enumerated() {
                let startSec = Double(ch.startPositionTicks ?? 0) / 10_000_000
                let title = (ch.name?.isEmpty == false ? ch.name : nil)
                    ?? "\(self.loc.localized("player.chapter")) \(i + 1)"
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
                let thumbTask = Task { @MainActor [weak self] in
                    guard let data = await Self.loadImage(url: url, token: token),
                          !Task.isCancelled,
                          let img = UIImage(data: data), let self,
                          i < self.chapterStack.arrangedSubviews.count,
                          let chip = self.chapterStack.arrangedSubviews[i] as? UIButton,
                          let iv = chip.viewWithTag(99) as? UIImageView else { return }
                    iv.image = img
                    iv.contentMode = .scaleAspectFill
                }
                self.chapterThumbTasks.append(thumbTask)
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
        b.isAccessibilityElement = true
        b.accessibilityLabel = "\(loc.localized("player.chapter")): \(title), \(time)"
        b.accessibilityTraits = .button

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
        let targetMs = Int32(clamping: chapterStartTicks[i] / 10_000)
        accumulateSeek(toAbsoluteMs: targetMs) // coalesce rapid chapter taps too
        showSkipHUD(PlayerTimeFormat.ms(targetMs))
        scheduleHideControls()
    }

    /// Downloads one chapter thumbnail. Sends the token both as the
    /// `api_key` query param (what Jellyfin image endpoints expect) and as the
    /// Authorization header, so it works regardless of server hardening.
    nonisolated private static func loadImage(url: URL, token: String?) async -> Data? {
        let authed = VLCStreamPresenter.authedURL(url, token: token)
        guard let (data, resp) = await AuthenticatedImageFetch.data(from: authed, token: token) else {
            #if DEBUG
            logger.debug("CINEMAX-CHAPTERIMG ▸ request failed \(redactedURL(authed))")
            #endif
            return nil
        }
        let code = resp.statusCode
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
        // Keep VoiceOver's spoken value in sync with the playhead. `timeLabel`
        // is set immediately before every call site, so it's the current time.
        tvScrub.accessibilityValue = timeLabel.text
    }

    /// Positions + populates the trickplay bubble during a touch-surface scrub.
    private func updateTVScrubPreview(progress: Float, targetMs: Int32) {
        guard trickplay.isAvailable else { return }
        lastPreviewMs = targetMs
        let trackWidth = tvScrub.bounds.width
        guard trackWidth > 0 else { return }
        let half: CGFloat = 160 // preview width / 2 — keep the bubble on-screen
        let x = min(max(trackWidth * CGFloat(progress), half), trackWidth - half)
        scrubPreviewCenterX?.constant = x
        scrubPreview.isHidden = false
        refreshScrubPreviewImage()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if infoPanelVisible { return [infoPanelStack] }
        if let card = nextUpCard, !card.isHidden, controlsContainer.alpha == 0 {
            return [card.playButton]
        }
        return controlsContainer.alpha > 0 ? [tvScrub] : []
    }
    #endif

    // MARK: - Single-purpose track pickers

    private func presentPicker(_ title: String,
                               sourceView: UIView? = nil,
                               _ options: [(title: String, selected: Bool, action: () -> Void)]) {
        pickerPresented = true
        hideControlsWorkItem?.cancel()
        #if os(tvOS)
        // A picker opened from the info panel keeps the panel as its backdrop —
        // revealing the HUD underneath would stack both chrome layers.
        if !infoPanelVisible { showControls() }
        #else
        showControls()
        #endif
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
        #if os(tvOS)
        if infoPanelVisible {
            // Back to the panel, not the HUD — restore focus to its buttons.
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return
        }
        #endif
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
        opts.append(("\(loc.localized("player.audioDelay")) — \(Self.formatDelay(audioDelayMsState))", false, { [weak self] in
            DispatchQueue.main.async { self?.openAudioDelayMenu() }
        }))
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
        opts.append(("\(loc.localized("player.subtitleDelay")) — \(Self.formatDelay(subtitleDelayMsState))", false, { [weak self] in
            DispatchQueue.main.async { self?.openSubtitleDelayMenu() }
        }))
        presentPicker(loc.localized("player.subtitles"), sourceView: subtitlePickerSource, opts)
    }

    // MARK: - Speed / delays / stats

    @objc private func openSpeedMenu() {
        var opts: [(String, Bool, () -> Void)] = []
        for rate in Self.speedOptions {
            let label = String(format: "%g×", rate)
            opts.append((label, abs(playbackRate - rate) < 0.01, { [weak self] in
                self?.setPlaybackRate(rate)
            }))
        }
        presentPicker(loc.localized("player.speed"), sourceView: speedPickerSource, opts)
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player.rate = rate
    }

    /// In-player quality ceiling picker. "Auto" restores the render4K-derived
    /// launch ceiling; each explicit option pins a lower `maxBitrate` so the
    /// server transcodes down (or DirectPlay stays under the cap). Selection
    /// re-negotiates a fresh PlaybackInfo and resumes at the current position
    /// via the wake re-resolve machinery (the loading spinner covers the re-open).
    /// Per-session only — no persisted setting.
    @objc private func openQualityMenu() {
        var opts: [(String, Bool, () -> Void)] = []
        opts.append((loc.localized("player.quality.auto"), bitrateIsAuto, { [weak self] in
            self?.applyBitrate(nil)
        }))
        for bps in Self.bitrateOptions {
            let label = loc.localized("player.quality.mbps", bps / 1_000_000)
            let selected = !bitrateIsAuto && maxBitrate == bps
            opts.append((label, selected, { [weak self] in
                self?.applyBitrate(bps)
            }))
        }
        presentPicker(loc.localized("player.quality"), sourceView: qualityPickerSource, opts)
    }

    /// Applies a new bitrate ceiling (nil = Auto) and re-resolves playback at the
    /// current position. No-op when the selection is unchanged.
    private func applyBitrate(_ bps: Int?) {
        let target = bps ?? initialMaxBitrate
        let willBeAuto = (bps == nil)
        guard target != maxBitrate || willBeAuto != bitrateIsAuto else { return }
        // `reResolveAndResume` reads `maxBitrate` for the fresh negotiation, so set
        // it first — but revert if the re-resolve is refused (a wake / quality
        // re-resolve is already in flight): otherwise the menu shows a ceiling the
        // stream never negotiated and re-picking that value would no-op forever.
        let previousBitrate = maxBitrate
        let previousAuto = bitrateIsAuto
        maxBitrate = target
        bitrateIsAuto = willBeAuto
        // Before the first engine time lands, `currentMs` is 0 and the resume-seek
        // hasn't fired yet — fall back to the original resume offset so a quality
        // change during the opening spinner doesn't restart the item from 0:00.
        let ms = hasValidTime ? currentMs : Int32(clamping: Int((startTime ?? 0) * 1000))
        if !reResolveAndResume(from: ms) {
            maxBitrate = previousBitrate
            bitrateIsAuto = previousAuto
        }
    }

    @objc private func openAudioDelayMenu() { presentDelayPicker(isAudio: true) }
    @objc private func openSubtitleDelayMenu() { presentDelayPicker(isAudio: false) }

    /// Cumulative ±nudge picker. Each adjustment re-opens the picker (title
    /// shows the running value) so repeated nudges are one tap each — the
    /// usual flow when syncing against what's on screen.
    private func presentDelayPicker(isAudio: Bool) {
        let current = isAudio ? audioDelayMsState : subtitleDelayMsState
        let titleKey = isAudio ? "player.audioDelay" : "player.subtitleDelay"
        let title = "\(loc.localized(titleKey)) — \(Self.formatDelay(current))"
        var opts: [(String, Bool, () -> Void)] = []
        for delta in [-250, -50, 50, 250] {
            opts.append((String(format: "%+d ms", delta), false, { [weak self] in
                self?.setDelay(isAudio: isAudio, ms: current + delta)
                // Re-present AFTER endPicker resets the picker state, else the
                // new sheet's pickerPresented flag is immediately cleared.
                DispatchQueue.main.async { self?.presentDelayPicker(isAudio: isAudio) }
            }))
        }
        opts.append((loc.localized("player.delay.reset"), current == 0, { [weak self] in
            self?.setDelay(isAudio: isAudio, ms: 0)
        }))
        presentPicker(title, sourceView: isAudio ? audioPickerSource : subtitlePickerSource, opts)
    }

    private func setDelay(isAudio: Bool, ms: Int) {
        let clamped = max(-5000, min(5000, ms))
        if isAudio {
            audioDelayMsState = clamped
            player.audioDelay = .milliseconds(clamped)
        } else {
            subtitleDelayMsState = clamped
            player.subtitleDelay = .milliseconds(clamped)
        }
    }

    private static func formatDelay(_ ms: Int) -> String {
        ms == 0 ? "0 ms" : String(format: "%+d ms", ms)
    }

    @objc private func toggleStats() {
        setStatsVisible(!statsVisible)
        scheduleHideControls()
    }

    /// Repainted by the 1s tick while visible — transport path, video/audio
    /// track facts, live bitrates, dropped frames.
    private func refreshStats() {
        guard statsVisible else { return }
        var lines: [String] = []
        var transport = usingProxy ? loc.localized("player.stats.proxy") : loc.localized("player.stats.direct")
        transport += " · \(info.playMethod.rawValue)"
        lines.append(transport)
        if let v = player.videoTracks.first(where: { $0.isSelected }) ?? player.videoTracks.first {
            var parts: [String] = []
            if let w = v.width, let h = v.height { parts.append("\(w)×\(h)") }
            parts.append(Self.fourCCString(v.codec))
            if let f = v.frameRate, f > 0 { parts.append(String(format: "%.4g fps", f)) }
            lines.append("\(loc.localized("player.stats.video")) : " + parts.joined(separator: " · "))
        }
        if let a = player.selectedAudioTrack ?? player.audioTracks.first {
            var parts: [String] = [Self.fourCCString(a.codec)]
            if let c = a.channels, c > 0 { parts.append("\(c) ch") }
            if let s = a.sampleRate, s > 0 { parts.append("\(s / 1000) kHz") }
            lines.append("\(loc.localized("player.stats.audio")) : " + parts.joined(separator: " · "))
        }
        if let s = player.statistics {
            // libVLC reports raw f_input_bitrate; ×8000 is what VLC's own UI
            // shows as kb/s.
            lines.append(String(
                format: "%@ : %.0f kb/s · demux %.0f kb/s",
                loc.localized("player.stats.bitrate"), s.inputBitrate * 8000, s.demuxBitrate * 8000
            ))
            lines.append("\(loc.localized("player.stats.dropped")) : \(s.lostPictures) · \(s.latePictures) late · \(s.lostAudioBuffers) audio")
        }
        statsLabel.text = lines.joined(separator: "\n")
    }

    /// FourCC codec int → printable tag ("hev1", "h264", "ac-3"…).
    private static func fourCCString(_ codec: Int) -> String {
        let v = UInt32(truncatingIfNeeded: codec)
        let chars = [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]
            .map { c -> Character in
                let scalar = Unicode.Scalar(UInt8(c))
                return (32...126).contains(c) ? Character(scalar) : "?"
            }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    /// Re-crops the preview bubble for the last scrub position — called when
    /// the position changes and when an async tile sheet lands.
    private func refreshScrubPreviewImage() {
        guard !scrubPreview.isHidden else { return }
        if let img = trickplay.thumbnail(atMs: lastPreviewMs) {
            scrubPreview.image = img
        }
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

    /// Containers whose layout forces libVLC into a storm of HTTP range
    /// requests (index/metadata at EOF, not streaming-optimised). Over HTTP/2
    /// that rapid stream open/cancel can trip a reverse proxy (`peer stream
    /// error: Protocol error`) and cascade into app-wide timeouts. We route
    /// these through the loopback proxy, which re-fetches via URLSession with
    /// bounded concurrency — so the origin never sees the storm.
    private static let seekHeavyContainers: Set<String> = [
        "avi", "divx", "wmv", "asf", "flv", "vob", "mpg", "mpeg", "mpe", "m2v"
    ]

    /// The source container (server-reported, DirectPlay/DirectStream only) is
    /// one libVLC tends to flood the server with range requests for.
    private var sourceNeedsProxy: Bool {
        guard let raw = info.sourceContainer?.lowercased() else { return false }
        // `container` can be comma/space-joined ("mov,mp4") — match any token.
        return raw.split(whereSeparator: { $0 == "," || $0 == " " })
            .contains { Self.seekHeavyContainers.contains(String($0)) }
    }

    /// Single decision point for opening a *fresh* stream through the proxy:
    /// a probed black-hole, a prior direct failure this session, or a
    /// seek-heavy container that would otherwise flood the server.
    private var shouldRouteThroughProxy: Bool {
        StreamTransportPolicy.shared.shouldStartOnProxy || sourceNeedsProxy
    }

    private func startPlayback() {
        hasValidTime = false
        didApplyServerTrackDefaults = false
        cancelPendingSeekCommit()
        setLoading(true)
        mediaLengthMs = 0
        firstPlayStart = Date()
        usingProxy = false
        nextUpCancelledForThisItem = false
        audioDelayMsState = 0
        subtitleDelayMsState = 0
        let url: URL
        let authed = VLCStreamPresenter.authedURL(info.url, token: info.authToken)
        // Broken-IPv6 server (decided in the background), direct already
        // failed this session, or a seek-heavy container (AVI…): route via
        // the loopback proxy; fall back to the direct URL if it can't start.
        if shouldRouteThroughProxy,
           let proxied = StreamTransportPolicy.shared.proxiedURL(for: authed, token: info.authToken) {
            url = proxied
            usingProxy = true
        } else {
            url = authed
        }
        guard let media = makeMedia(url) else { handlePlaybackError(); return }
        startEventLoop()
        activatePlaybackAudioSession()
        lastPlayStart = Date()
        try? player.play(media)
        scheduleOpenWatchdog()
        reporter?.reportStart(startTime: startTime)
        startProgressTimer()
        fetchSegments()
        startSleepTimerIfNeeded()
        fetchChapters()
    }

    /// Arms (or re-arms) the open watchdog. Cancelled the moment playback
    /// produces a length or a valid time, or on teardown / error / end.
    private func scheduleOpenWatchdog() {
        openWatchdog?.invalidate()
        let timeout = didRetry ? Self.retryOpenTimeout : Self.firstOpenTimeout
        let t = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isTearingDown, !self.hasValidTime, self.lengthMs <= 0 else { return }
                logger.error("VLC open watchdog: media never became ready after \(self.elapsedSincePlay(), privacy: .public) — surfacing error")
                self.handlePlaybackError()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        openWatchdog = t
    }

    private func cancelOpenWatchdog() {
        openWatchdog?.invalidate()
        openWatchdog = nil
    }

    /// Called by `RemoteCommandController` when the Siri Remote / Lock Screen /
    /// CarPlay play-pause command fires. Reveals the HUD on tvOS so the user
    /// gets visual feedback (HUD often hidden when the press lands here —
    /// that's exactly when `pressesBegan` doesn't reach the controller).
    private func handleRemotePlayPause() {
        playPauseTapped()
        #if os(tvOS)
        revealControls()
        #endif
    }

    @objc private func playPauseTapped() {
        let willPlay = !enginePlaying
        // In a SyncPlay group the tap is a request to the server, not a local
        // action: emit it and let the echoed command move every participant's
        // playhead together. The center glyph + icon still flip for immediate
        // feedback; the engine follows when the echo lands.
        if syncPlayActive {
            if willPlay { syncPlay.userDidPlay() } else { syncPlay.userDidPause() }
        } else {
            if enginePlaying { enginePause() } else { enginePlay() }
        }
        flashCenterGlyph(playing: willPlay)
        #if os(iOS)
        setPlayPauseIcon(playing: willPlay)
        #endif
        scheduleHideControls()
    }

    // MARK: - SyncPlay ("Watch Together")

    /// Binds this presenter to the shared SyncPlay controller when playback
    /// opens while already in a group. The controller drives the engine
    /// through these closures (never re-emitting), and routes the user's
    /// transport actions to the server instead.
    private func bindSyncPlayIfNeeded() {
        guard syncPlay.isInGroup else { return }
        syncPlayActive = true
        syncPlay.bindPlayback(SyncPlayController.PlaybackBridge(
            play: { [weak self] in self?.enginePlay() },
            pause: { [weak self] in self?.enginePause() },
            seekMs: { [weak self] ms in self?.engineSeek(ms: Int32(clamping: ms)) },
            positionMs: { [weak self] in Int(self?.currentMs ?? 0) },
            stop: { [weak self] in self?.enginePause() } // v1: pause on server Stop
        ))
        syncPlay.onParticipantsChanged = { [weak self] count in self?.updateSyncPlayPill(count: count) }
        updateSyncPlayPill(count: syncPlay.participantCount)
    }

    private func updateSyncPlayPill(count: Int) {
        guard syncPlayActive else { return }
        syncPlayPill.isHidden = false
        // Padded with spaces so the rounded background reads as a pill without
        // a custom label-inset subclass.
        syncPlayPill.text = "  " + loc.localized("syncplay.pill", max(count, 1)) + "  "
    }

    /// Detaches from the controller and, since v1 ties the group's lifetime to
    /// the player, leaves the group. Called from `teardown` (user dismiss).
    private func unbindSyncPlay() {
        guard syncPlayActive else { return }
        syncPlayActive = false
        syncPlay.onParticipantsChanged = nil
        syncPlay.unbindPlayback()
        syncPlay.playbackDidDismiss()
    }

    /// A user-initiated seek. In a group it becomes a server Seek request (the
    /// echo does the actual engine seek); otherwise it seeks locally.
    private func userEngineSeek(ms: Int32) {
        if syncPlayActive {
            syncPlay.userDidSeek(toMs: Int(max(0, ms)))
        } else {
            engineSeek(ms: ms)
        }
    }

    // MARK: - Episode navigation

    private func navigateToEpisode(_ ref: EpisodeRef) {
        // Only navigable when the episode-nav graph is present.
        guard let navigator = episodeNavigator else { return }
        navGeneration += 1
        let gen = navGeneration
        reporter?.reportStop()
        progressTimer?.invalidate()
        Task { [weak self] in
            guard let self else { return }
            // Navigator yields the new prev/next graph (its PlaybackInfo is
            // negotiated for the native engine, so we re-negotiate for VLC).
            let nav = await navigator(ref.id)
            guard let vlcInfo = try? await self.apiClient.getPlaybackInfo(
                itemId: ref.id, userId: self.userId, maxBitrate: self.maxBitrate, engine: .vlc
            ) else {
                logger.error("VLC episode nav: failed to negotiate \(ref.id, privacy: .public)")
                return
            }
            // Dismissed mid-nav, or a newer nav superseded this one: applying
            // would resurrect playback / interleave two episodes' state.
            guard !self.isTearingDown, gen == self.navGeneration else { return }
            self.itemId = ref.id
            self.info = vlcInfo
            self.startTime = nil
            self.didSeekToStart = true // new episode starts at 0
            self.hasValidTime = false
            self.lastKnownPositionMs = 0 // don't resume a retry at the old episode's position
            self.cancelPendingSeekCommit() // a queued skip must not seek the new episode
            self.didRetry = false
            self.didReportEnd = false
            self.didApplyServerTrackDefaults = false
            self.mediaLengthMs = 0
            // Per-file state: the countdown card baked in the old "next" title,
            // and delays compensate per-file mux drift. Speed persists.
            self.tearDownNextUpCard()
            self.audioDelayMsState = 0
            self.subtitleDelayMsState = 0
            self.previousEpisode = nav?.1
            self.nextEpisode = nav?.2
            self.titleLabel.text = ref.title
            let authed = VLCStreamPresenter.authedURL(vlcInfo.url, token: vlcInfo.authToken)
            let url: URL
            // Carry the proxy across episodes when the server needs it.
            if (self.usingProxy || self.shouldRouteThroughProxy),
               let proxied = StreamTransportPolicy.shared.proxiedURL(for: authed, token: vlcInfo.authToken) {
                url = proxied
                self.usingProxy = true
            } else {
                url = authed
                self.usingProxy = false
            }
            guard let media = self.makeMedia(url) else { self.handlePlaybackError(); return }
            self.setLoading(true)
            self.lastPlayStart = Date()
            try? self.player.play(media)
            self.scheduleOpenWatchdog()
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
            self.nowPlaying.attach(itemId: ref.id, title: ref.title, durationSeconds: nil)
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
    /// it). Double tap → seek ∓10 s by screen half; a hidden HUD stays hidden
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
                seek(bySeconds: -PlayerSkipConfig.intervalSeconds)
                showSkipGlyph(forward: false)
            } else {
                seek(bySeconds: PlayerSkipConfig.intervalSeconds)
                showSkipGlyph(forward: true)
            }
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

    /// Interactive swipe-down dismissal. The presented view tracks the finger
    /// (translation + slight fade + corner rounding); past 25% of the screen
    /// height or on a downward flick the player slides off and dismisses —
    /// `.overFullScreen` keeps the underlying screen in the hierarchy, so the
    /// app is revealed live behind the drag. Otherwise it springs back.
    @objc private func handleDismissPan(_ g: UIPanGestureRecognizer) {
        let height = max(view.bounds.height, 1)
        let ty = max(0, g.translation(in: view).y)
        switch g.state {
        case .began:
            view.clipsToBounds = true
            dismissPastThreshold = false
            dismissHaptic.prepare()
        case .changed:
            view.transform = CGAffineTransform(translationX: 0, y: ty)
            view.alpha = 1 - 0.35 * min(1, ty / height)
            view.layer.cornerRadius = min(24, ty * 0.2)
            // One haptic tick per threshold crossing — "release here closes".
            let past = ty > height * 0.25
            if past != dismissPastThreshold {
                dismissPastThreshold = past
                if past { dismissHaptic.impactOccurred() }
            }
        case .ended, .cancelled:
            let flick = g.velocity(in: view).y > 900
            if g.state == .ended, ty > height * 0.25 || flick {
                UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseIn) {
                    self.view.transform = CGAffineTransform(translationX: 0, y: height)
                    self.view.alpha = 0
                } completion: { _ in
                    // The slide already played the exit; a second animated
                    // cross-dissolve here would double-animate.
                    self.dismiss(animated: false)
                }
            } else {
                UIView.animate(withDuration: 0.3, delay: 0,
                               usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.view.transform = .identity
                    self.view.alpha = 1
                    self.view.layer.cornerRadius = 0
                }
            }
        default:
            break
        }
    }

    /// Only begin the dismiss pan on a predominantly-downward drag — sideways
    /// motion belongs to the chapter strip / double-tap zones, and a slider
    /// scrub in progress must never tug the whole surface.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard !isScrubbing else { return false }
        let v = pan.velocity(in: view)
        return v.y > 0 && abs(v.y) > abs(v.x)
    }

    /// The dismiss pan and hold-boost only track touches landing on the bare
    /// video surface — HUD buttons, the slider, and the chapter strip keep
    /// their own touches.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === dismissPan || gestureRecognizer === holdPress else { return true }
        return touch.view === videoView
    }

    /// Hold-to-2×: boost while the press is held, restore the user-selected
    /// rate on release. The skip HUD doubles as the "2×" indicator (manually
    /// held visible — its usual auto-hide is for transient chapter jumps).
    @objc private func handleHoldBoost(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard enginePlaying else { return }
            isHoldBoosting = true
            player.rate = 2.0
            skipHUDHide?.cancel()
            skipHUD.text = "  2× ▸▸  "
            skipHUD.alpha = 1
        case .ended, .cancelled, .failed:
            guard isHoldBoosting else { return }
            isHoldBoosting = false
            player.rate = playbackRate
            UIView.animate(withDuration: 0.25) { self.skipHUD.alpha = 0 }
        default:
            break
        }
    }

    @objc private func iosSkipBack() {
        seek(bySeconds: -PlayerSkipConfig.intervalSeconds)
        showSkipGlyph(forward: false)
        scheduleHideControls()
    }

    @objc private func iosSkipForward() {
        seek(bySeconds: PlayerSkipConfig.intervalSeconds)
        showSkipGlyph(forward: true)
        scheduleHideControls()
    }

    // MARK: - iPad hardware-keyboard shortcuts
    //
    // Space = play/pause, ←/→ = seek ∓10 s. Both seek shortcuts route through the
    // documented coalesced path (`seek(bySeconds:)` → `accumulateSeek`) via the
    // existing iOS skip handlers — never a direct engine seek. Wired as UIKit key
    // commands so they coexist with the gesture/HUD stack without touching it.
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let cmds = [
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(keyTogglePlayPause)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keySeekBackward)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keySeekForward))
        ]
        // Space/arrows are otherwise absorbed by system scroll/select behavior.
        cmds.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return cmds
    }

    @objc private func keyTogglePlayPause() { showControls(); playPauseTapped() }
    @objc private func keySeekBackward() { showControls(); iosSkipBack() }
    @objc private func keySeekForward() { showControls(); iosSkipForward() }

    @objc private func scrubberTouchDown() {
        isScrubbing = true
        cancelPendingSeekCommit() // a live drag supersedes a queued skip
        // Freeze the HUD for the whole drag — re-armed on touch-up.
        hideControlsWorkItem?.cancel()
        updateScrubPreview()
    }

    @objc private func scrubberChanged() {
        isScrubbing = true
        hideControlsWorkItem?.cancel()
        let length = lengthMs
        guard length > 0 else { return }
        timeLabel.text = PlayerTimeFormat.ms(Int32(Float(length) * slider.value))
        updateScrubPreview()
    }

    @objc private func scrubberDone() {
        scrubPreview.isHidden = true
        let length = lengthMs
        guard length > 0 else { isScrubbing = false; return }
        userEngineSeek(ms: Int32(Float(length) * slider.value))
        isScrubbing = false
        scheduleHideControls()
    }

    /// Positions + populates the trickplay bubble for the slider's value.
    private func updateScrubPreview() {
        guard trickplay.isAvailable, lengthMs > 0 else { return }
        let ms = Int32(Float(lengthMs) * slider.value)
        lastPreviewMs = ms
        let trackWidth = slider.bounds.width
        guard trackWidth > 0 else { return }
        let half: CGFloat = 80 // preview width / 2 — keep the bubble on-screen
        let x = min(max(trackWidth * CGFloat(slider.value), half), trackWidth - half)
        scrubPreviewCenterX?.constant = x
        scrubPreview.isHidden = false
        refreshScrubPreviewImage()
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
        case .opening, .buffering:
            // Opening a stream or re-buffering mid-playback → show the spinner so
            // the gap reads as "loading", not "frozen". Cleared by .playing or the
            // first time tick.
            setLoading(true)
            if syncPlayActive { syncPlay.reportBuffering() }
        case .stopped:
            guard !isTearingDown,
                  Date().timeIntervalSince(lastPlayStart) > 1.0,
                  lengthMs > 0, currentMs >= lengthMs - 2000 else { return }
            handlePlaybackEnded()
        case .playing:
            setLoading(false)
            didRetry = false
            // libVLC resets rate on media swap — re-apply the user's speed
            // (but never while a hold-boost owns the rate).
            #if os(iOS)
            let boosting = isHoldBoosting
            #else
            let boosting = false
            #endif
            if !boosting, abs(player.rate - playbackRate) > 0.01 {
                player.rate = playbackRate
            }
            #if os(iOS)
            setPlayPauseIcon(playing: true)
            #endif
            refreshNowPlayingRate(playing: true)
            if syncPlayActive { syncPlay.reportReady(isPlaying: true) }
        case .paused:
            setLoading(false)
            #if os(iOS)
            setPlayPauseIcon(playing: false)
            #endif
            refreshNowPlayingRate(playing: false)
            if syncPlayActive { syncPlay.reportReady(isPlaying: false) }
        default: break
        }
    }

    /// Sub-second sync of the Lock Screen widget's play/pause indicator on
    /// engine state transitions — the 1 s tick alone would lag visibly here.
    private func refreshNowPlayingRate(playing: Bool) {
        let dur: Double? = lengthMs > 0 ? Double(lengthMs) / 1000 : nil
        nowPlaying.update(
            elapsed: Double(currentMs) / 1000,
            duration: dur,
            rate: playing ? 1.0 : 0.0
        )
    }

    private func handlePlaybackEnded() {
        guard !didReportEnd else { return }
        didReportEnd = true
        cancelOpenWatchdog()
        nextUpCard?.hide()
        if autoPlayNext, !nextUpCancelledForThisItem, let next = nextEpisode, episodeNavigator != nil {
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
        // Gated on `episodeNavigator != nil` (series playback only).
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
        cancelOpenWatchdog()
        if !didRetry {
            didRetry = true
            logger.error("VLC error for \(self.itemId, privacy: .public) at \(self.elapsedSincePlay(), privacy: .public) — retrying once")
            // A direct attempt failed: pin the rest of the session to the
            // proxy so we stop re-rolling the dice on the flaky direct path.
            if !usingProxy { StreamTransportPolicy.shared.noteDirectPlaybackFailed() }
            let authed = VLCStreamPresenter.authedURL(info.url, token: info.authToken)
            // Always retry via the proxy (direct is the path that stalls on
            // broken IPv6); fall back to direct only if it can't start.
            let url: URL
            if let proxied = StreamTransportPolicy.shared.proxiedURL(for: authed, token: info.authToken) {
                url = proxied
                usingProxy = true
            } else {
                url = authed
            }
            if let media = try? Media(url: url) {
                media.addOption(":network-caching=5000")
                // A drop AFTER playback began (HTTP/2 RST on a proxied
                // server, transient blip): resume where it dropped instead
                // of restarting at 0. The initial resume-seek already fired,
                // so re-arm it and reset media state exactly like an episode
                // swap. A fresh-open failure (never played, position 0)
                // keeps its original `startTime` resume untouched.
                if lastKnownPositionMs > 1000 {
                    startTime = Double(lastKnownPositionMs) / 1000
                    didSeekToStart = false
                    hasValidTime = false
                    mediaLengthMs = 0
                }
                setLoading(true)
                activatePlaybackAudioSession()
                lastPlayStart = Date()
                try? player.play(media)
                scheduleOpenWatchdog()
            }
            return
        }
        logger.error("VLC error for \(self.itemId, privacy: .public) at \(self.elapsedSincePlay(), privacy: .public) — giving up")
        setLoading(false) // the error dialog now owns the screen
        let alert = UIAlertController(
            title: loc.localized("playback.error.title"),
            message: loc.localized("playback.error.generic"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: loc.localized("playback.error.close"), style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
        errorAlert = alert
    }

    /// The open watchdog already surfaced the failure alert, but libVLC then
    /// finished connecting (a stalled handshake recovered, or the IPv4 retry
    /// landed). Tear the alert down and let the video play rather than leaving
    /// the user stranded behind a "playback failed" dialog over a live stream.
    private func recoverFromErrorIfNeeded() {
        guard let alert = errorAlert else { return }
        errorAlert = nil
        didRetry = false
        alert.dismiss(animated: true)
    }

    // MARK: - Audio session ownership (wake-from-sleep resilience)

    /// libVLC's audio-output module activates the `AVAudioSession` itself, which
    /// works on a clean cold start. But after the device sleeps and wakes, its
    /// `setActive(true)` fails with `AVAudioSessionErrorCodeCannotStartPlaying`
    /// (561015905) and the aout retries forever — audio output never starts,
    /// libVLC's playback clock stalls, and the user is stranded on a black frame
    /// even though the video decoder is running. Owning the session here (the same
    /// `.playback`/`.moviePlayback` the native `AVPlayer` path uses) means libVLC
    /// re-opens onto an already-active, app-owned playback session, so its aout
    /// starts cleanly. Idempotent — called before every (re)open of a stream.
    private func activatePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
        } catch {
            logger.error("VLC: failed to activate playback audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivatePlaybackAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("VLC: failed to deactivate playback audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - App-lifecycle wake resilience

    /// Observes background/foreground so a stream that died during device sleep
    /// (Apple TV powered off, phone locked) is re-resolved and resumed instead
    /// of stranding the user on a generic playback error. Mirrors
    /// `NativeVideoPresenter.setupBackgroundObserver` (the `@Sendable` observer
    /// closure hops `Task { @MainActor in … }` to reach `self`).
    private func setupLifecycleObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidEnterBackground() }
        }
        // Recover on `didBecomeActive` (NOT `willEnterForeground`): VideoToolbox
        // only issues a valid hardware decode session — and AVAudioSession only
        // activates — once the app is genuinely foreground-active. Restarting at
        // `willEnterForeground` builds an invalid VT session (black frame) and a
        // dead audio output.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidBecomeActive() }
        }
    }

    private func handleDidEnterBackground() {
        // Remember whether we were actively watching, where, and for how long, so
        // we can pick back up. (`.buffering`/`.opening` also count as "watching".)
        switch player.state {
        case .playing, .paused, .buffering, .opening:
            didBackgroundWhilePlaying = true
            positionAtBackgroundMs = currentMs
            backgroundedAt = Date()
        default:
            didBackgroundWhilePlaying = false
            backgroundedAt = nil
        }
    }

    private func handleDidBecomeActive() {
        guard didBackgroundWhilePlaying else { return }
        didBackgroundWhilePlaying = false
        defer { backgroundedAt = nil }
        switch player.state {
        case .error, .stopped, .stopping, .idle:
            // Engine died with the socket — rebuild and resume.
            reResolveAndResume(from: positionAtBackgroundMs)
        default:
            // Engine still REPORTS alive, but on tvOS a genuine sleep/power-off
            // invalidated the VT decode + audio sessions underneath it (the
            // "audio but black video" symptom). A real sleep ⇒ rebuild anyway.
            // iOS deliberately skips this: PiP and locked-screen-with-audio keep
            // a healthy session playing in the background, so a "reports alive"
            // engine there really IS alive — rebuilding would nuke working PiP.
            // A genuinely dead iOS stream falls into the `.error/.stopped` case.
            #if os(tvOS)
            let backgroundDuration = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
            if backgroundDuration >= Self.wakeRebuildThreshold {
                reResolveAndResume(from: positionAtBackgroundMs)
            }
            #endif
        }
    }

    /// Re-negotiates a FRESH PlaybackInfo (new `api_key` + `playSessionId`) for
    /// the current item and resumes from `ms`. Trimmed copy of
    /// `navigateToEpisode`'s media/proxy/seek machinery (no episode-graph
    /// changes). Guarded by `navGeneration` so a user episode-nav started during
    /// the await wins, and one-shot via `isReResolvingAfterWake`.
    @discardableResult
    private func reResolveAndResume(from ms: Int32) -> Bool {
        guard !isTearingDown, !isReResolvingAfterWake else { return false }
        // A committed-but-not-yet-landed skip is the user's intended position:
        // resume there rather than the stale pre-seek tick, then drop the pending
        // seek so it can't fire against the reloaded media or leave `refreshTimeUI`
        // frozen painting a target the new stream never reaches. Mirrors the
        // `cancelPendingSeekCommit()` that `startPlayback`/`navigateToEpisode` do.
        let resumeMs = pendingScrubTargetMs ?? ms
        cancelPendingSeekCommit()
        isReResolvingAfterWake = true
        navGeneration += 1
        let gen = navGeneration
        let resumeItemId = itemId
        let resumeSeconds = Double(resumeMs) / 1000.0
        logger.notice("VLC wake re-resolve for \(resumeItemId, privacy: .public) @ \(Int(resumeSeconds))s")
        Task { [weak self] in
            guard let self else { return }
            defer { self.isReResolvingAfterWake = false }
            // Routes through `notifyIfUnauthorized`: a genuinely revoked token
            // triggers the confirm-before-logout cycle in AppState. A transient
            // failure just returns nil → leave the watchdog / error path to it.
            guard let fresh = try? await self.apiClient.getPlaybackInfo(
                itemId: resumeItemId, userId: self.userId, maxBitrate: self.maxBitrate, engine: .vlc
            ) else { return }
            guard !self.isTearingDown, gen == self.navGeneration else { return }
            self.info = fresh
            self.startTime = resumeSeconds > 1 ? resumeSeconds : nil
            self.didSeekToStart = (self.startTime == nil)   // re-arm seek-to-resume
            self.hasValidTime = false
            self.didRetry = false
            self.didReportEnd = false
            self.didApplyServerTrackDefaults = false
            self.mediaLengthMs = 0
            self.recoverFromErrorIfNeeded()                 // drop any stale error alert
            let authed = VLCStreamPresenter.authedURL(fresh.url, token: fresh.authToken)
            let url: URL
            if (self.usingProxy || self.shouldRouteThroughProxy),
               let proxied = StreamTransportPolicy.shared.proxiedURL(for: authed, token: fresh.authToken) {
                url = proxied
                self.usingProxy = true
            } else {
                url = authed
                self.usingProxy = false
            }
            guard let media = self.makeMedia(url) else { self.handlePlaybackError(); return }
            self.setLoading(true)
            // Re-assert the playback session BEFORE replay: the system deactivated
            // it during sleep, and without this libVLC's aout loops forever on
            // `CannotStartPlaying` (the black-screen-after-wake bug).
            self.activatePlaybackAudioSession()
            self.lastPlayStart = Date()
            try? self.player.play(media)
            self.scheduleOpenWatchdog()
            self.reporter?.resetTicking()
            self.startProgressTimer()
            self.refreshTimeUISoon()
        }
        return true
    }

    /// Seconds elapsed since the first play() of this session — the
    /// user-perceived "time to open". Surfaced in the watchdog/error logs.
    private func elapsedSincePlay() -> String {
        String(format: "%.1fs", Date().timeIntervalSince(firstPlayStart))
    }

    private func onEngineTimeChanged() {
        refreshTimeUI()
        if currentMs > 0 {
            hasValidTime = true; cancelOpenWatchdog(); recoverFromErrorIfNeeded()
            setLoading(false)
            lastKnownPositionMs = currentMs
        }
        if !didSeekToStart, let start = startTime, start.isFinite, start > 0, lengthMs > 0 {
            didSeekToStart = true
            // `Int32(start * 1000)` traps on overflow if a corrupt resume tick
            // yields a huge position — clamp the conversion, then cap to just
            // before the end so a stale tick past EOF doesn't seek into nothing.
            let targetMs = min(Int32(clamping: Int(start * 1000)), max(0, lengthMs - 5000))
            if targetMs > 0 { engineSeek(ms: targetMs) }
        }
    }

    /// Repaints the scrub bar + time labels from the player's current position.
    /// Driven by `mediaPlayerTimeChanged` while playing, AND called explicitly
    /// after every programmatic seek — VLC doesn't emit time updates while
    /// paused, so without this a seek-while-paused wouldn't move the bar.
    private func refreshTimeUI() {
        // While the user is sliding, the live preview owns the bar + labels.
        if isScrubbing { return }
        let currentMs = self.currentMs
        let lengthMs = self.lengthMs
        // Hold a pending target (coalesced skip, chapter jump, or scrub release)
        // until VLC's position actually reaches it (within ~1.2 s) — otherwise
        // the periodic tick paints the stale pre-seek position for a beat and
        // the bar visibly snaps back. Applies to BOTH platforms.
        if let target = pendingScrubTargetMs {
            if abs(Int(currentMs) - Int(target)) <= 1200 {
                pendingScrubTargetMs = nil
            } else {
                paintPosition(target, lengthMs: lengthMs)
                return
            }
        }
        paintPosition(currentMs, lengthMs: lengthMs)
    }

    /// Writes one position to the time labels and the platform scrub control.
    private func paintPosition(_ ms: Int32, lengthMs: Int32) {
        timeLabel.text = PlayerTimeFormat.ms(ms)
        durationLabel.text = "-" + PlayerTimeFormat.ms(max(0, lengthMs - ms))
        guard lengthMs > 0 else { return }
        #if os(iOS)
        slider.value = Float(ms) / Float(lengthMs)
        #else
        updateScrubBar(progress: Float(ms) / Float(lengthMs))
        #endif
    }

    /// Follow-up repaints pending from the last `refreshTimeUISoon()`. Held so
    /// a rapid scrub burst coalesces instead of stacking dozens of closures
    /// (each call cancels the previous follow-ups before scheduling fresh ones).
    private var pendingTimeRefreshes: [DispatchWorkItem] = []

    /// Refreshes now and again shortly after — VLC applies a seek asynchronously,
    /// so `mediaPlayer.time` may not reflect the new position for a beat.
    private func refreshTimeUISoon() {
        refreshTimeUI()
        pendingTimeRefreshes.forEach { $0.cancel() }
        pendingTimeRefreshes = [0.15, 0.4].map { delay in
            let work = DispatchWorkItem { [weak self] in self?.refreshTimeUI() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

}
