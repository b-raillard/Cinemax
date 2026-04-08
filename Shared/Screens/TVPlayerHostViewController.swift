#if os(tvOS)
import SwiftUI
import AVFoundation
import UIKit
import OSLog
import CinemaxKit

private let tvPlayerLog = Logger(subsystem: "com.cinemax", category: "TVPlayer")

// MARK: - Host View Controller

/// Full-screen UIKit container that embeds AVPlayer + a SwiftUI overlay.
/// Replaces AVPlayerViewController to give us full control of the transport bar,
/// eliminating the native "Unknown" audio track and duplicate CC subtitle buttons.
final class TVPlayerHostViewController: UIViewController {

    // MARK: Dependencies

    private var avPlayer: AVPlayer
    private let playerLayer = AVPlayerLayer()
    private var hostingController: UIHostingController<AnyView>?

    private(set) var state: TVPlayerState
    let info: JellyfinAPIClient.PlaybackInfo
    let itemTitle: String
    let onTrackChange: (Int?, Int?) async -> URL?
    let episodeNavigator: EpisodeNavigator?
    private var startTime: Double?
    private let authToken: String?

    // MARK: Observations

    private var statusObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var hideControlsTask: Task<Void, Never>?

    // MARK: Init

    init(
        title: String,
        info: JellyfinAPIClient.PlaybackInfo,
        startTime: Double? = nil,
        previousEpisode: EpisodeRef? = nil,
        nextEpisode: EpisodeRef? = nil,
        episodeNavigator: EpisodeNavigator? = nil,
        onTrackChange: @escaping (Int?, Int?) async -> URL?
    ) {
        self.itemTitle = title
        self.info = info
        self.startTime = startTime
        self.episodeNavigator = episodeNavigator
        self.onTrackChange = onTrackChange
        self.authToken = info.authToken

        let item = Self.makePlayerItem(url: info.url, authToken: info.authToken)
        self.avPlayer = AVPlayer(playerItem: item)
        self.avPlayer.automaticallyWaitsToMinimizeStalling = true

        self.state = TVPlayerState()
        self.state.title = title
        self.state.currentAudioIdx = info.selectedAudioIndex
        self.state.currentSubtitleIdx = info.selectedSubtitleIndex
        self.state.previousEpisode = previousEpisode
        self.state.nextEpisode = nextEpisode

        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        playerLayer.player = avPlayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = view.bounds
        view.layer.addSublayer(playerLayer)

        observeCurrentItem()
        addTimeObserver()
        mountOverlay()
        scheduleHideControls()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = view.bounds
        hostingController?.view.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        avPlayer.play()
        state.isPlaying = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        avPlayer.pause()
        teardown()
    }

    // MARK: - Setup

    private func mountOverlay() {
        let overlay = TVPlayerOverlayView(
            state: state,
            info: info,
            onPlayPause: { [weak self] in self?.togglePlayPause() },
            onSeek: { [weak self] delta in self?.seek(by: delta) },
            onAudioChange: { [weak self] id in
                guard let self else { return }
                state.currentAudioIdx = id
                restartWithCurrentTracks()
            },
            onSubtitleChange: { [weak self] id in
                guard let self else { return }
                state.currentSubtitleIdx = id
                restartWithCurrentTracks()
            },
            onDismiss: { [weak self] in self?.dismiss(animated: true) },
            onInteraction: { [weak self] in self?.showControlsTemporarily() },
            onPreviousEpisode: { [weak self] in
                guard let ep = self?.state.previousEpisode else { return }
                self?.navigateToEpisode(ep)
            },
            onNextEpisode: { [weak self] in
                guard let ep = self?.state.nextEpisode else { return }
                self?.navigateToEpisode(ep)
            }
        )

        let hc = UIHostingController(rootView: AnyView(overlay))
        hc.view.backgroundColor = .clear
        addChild(hc)
        view.addSubview(hc.view)
        hc.didMove(toParent: self)
        hostingController = hc
    }

    // MARK: - Observations

    private func observeCurrentItem() {
        guard let item = avPlayer.currentItem else { return }
        statusObservation?.invalidate()
        keepUpObservation?.invalidate()

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.state.isBuffering = false
                    if let d = try? await item.asset.load(.duration),
                       d.isValid, d.seconds.isFinite, d.seconds > 0 {
                        self.state.duration = d.seconds
                    }
                    if let st = self.startTime, st > 0 {
                        await self.avPlayer.seek(
                            to: CMTime(seconds: st, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                        self.startTime = nil
                    }
                case .failed:
                    tvPlayerLog.error("AVPlayer failed: \(item.error?.localizedDescription ?? "unknown")")
                    self.state.isBuffering = false
                default:
                    break
                }
            }
        }

        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.isBuffering = !item.isPlaybackLikelyToKeepUp
                    && self.avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
    }

    private func addTimeObserver() {
        if let obs = timeObserver { avPlayer.removeTimeObserver(obs) }
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, time.isValid, time.seconds.isFinite else { return }
            // Delivered on .main queue — use assumeIsolated to avoid a Task allocation every second.
            MainActor.assumeIsolated {
                // Skip time updates while buffering during a track switch so the
                // scrubber stays pinned at the saved position instead of jumping to 0.
                guard !self.state.isBuffering else { return }
                self.state.currentTime = time.seconds
                self.state.isPlaying = self.avPlayer.rate != 0
            }
        }
    }

    private func teardown() {
        hideControlsTask?.cancel()
        statusObservation?.invalidate()
        keepUpObservation?.invalidate()
        statusObservation = nil
        keepUpObservation = nil
        if let obs = timeObserver {
            avPlayer.removeTimeObserver(obs)
            timeObserver = nil
        }
    }

    // MARK: - Control Visibility

    func showControlsTemporarily() {
        state.showControls = true
        scheduleHideControls()
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.state.showControls = false
        }
    }

    // MARK: - Player Item Factory

    private static func makePlayerItem(url: URL, authToken: String?) -> AVPlayerItem {
        let item: AVPlayerItem
        if let token = authToken {
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "MediaBrowser Token=\(token)"]
            ])
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: url)
        }
        item.preferredForwardBufferDuration = 5
        return item
    }

    // MARK: - Playback Actions

    func togglePlayPause() {
        if avPlayer.rate == 0 {
            avPlayer.play()
            state.isPlaying = true
        } else {
            avPlayer.pause()
            state.isPlaying = false
        }
        showControlsTemporarily()
    }

    func seek(by delta: Double) {
        let target = max(0, min(state.duration, state.currentTime + delta))
        avPlayer.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        state.currentTime = target
        showControlsTemporarily()
    }

    private func restartWithCurrentTracks() {
        let savedSeconds = avPlayer.currentTime().seconds
        // Pin the scrubber at the current position before buffering starts,
        // so it doesn't reset to 0 while the new item loads.
        state.currentTime = savedSeconds
        state.isBuffering = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let newURL = await onTrackChange(state.currentAudioIdx, state.currentSubtitleIdx) else {
                state.isBuffering = false
                return
            }

            let newItem = Self.makePlayerItem(url: newURL, authToken: authToken)

            statusObservation?.invalidate()
            keepUpObservation?.invalidate()

            statusObservation = newItem.observe(\.status) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, item.status == .readyToPlay else { return }
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    if savedSeconds > 0 {
                        await self.avPlayer.seek(
                            to: CMTime(seconds: savedSeconds, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    }
                    self.avPlayer.play()
                    self.state.isPlaying = true
                    self.state.isBuffering = false
                    if let d = try? await item.asset.load(.duration),
                       d.isValid, d.seconds.isFinite, d.seconds > 0 {
                        self.state.duration = d.seconds
                    }
                    // Re-attach keepUp observation on new item
                    self.keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp) { [weak self] item, _ in
                        Task { @MainActor [weak self] in
                            self?.state.isBuffering = !item.isPlaybackLikelyToKeepUp
                        }
                    }
                }
            }
            avPlayer.replaceCurrentItem(with: newItem)
        }
    }

    func navigateToEpisode(_ ep: EpisodeRef) {
        guard episodeNavigator != nil else { return }
        state.currentTime = 0
        state.duration = 0
        state.isBuffering = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let (newInfo, newPrev, newNext) = await episodeNavigator?(ep.id) else {
                state.isBuffering = false
                return
            }

            state.title = ep.title
            state.previousEpisode = newPrev
            state.nextEpisode = newNext
            state.currentAudioIdx = newInfo.selectedAudioIndex
            state.currentSubtitleIdx = newInfo.selectedSubtitleIndex

            let newItem = Self.makePlayerItem(url: newInfo.url, authToken: authToken)

            statusObservation?.invalidate()
            keepUpObservation?.invalidate()

            statusObservation = newItem.observe(\.status) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, item.status == .readyToPlay else { return }
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    self.avPlayer.play()
                    self.state.isPlaying = true
                    self.state.isBuffering = false
                    if let d = try? await item.asset.load(.duration),
                       d.isValid, d.seconds.isFinite, d.seconds > 0 {
                        self.state.duration = d.seconds
                    }
                    self.keepUpObservation = newItem.observe(\.isPlaybackLikelyToKeepUp) { [weak self] item, _ in
                        Task { @MainActor [weak self] in
                            self?.state.isBuffering = !item.isPlaybackLikelyToKeepUp
                        }
                    }
                }
            }
            avPlayer.replaceCurrentItem(with: newItem)
        }
    }

    // MARK: - Remote Input

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else {
            super.pressesBegan(presses, with: event)
            return
        }
        switch press.type {
        case .playPause:
            togglePlayPause()

        case .menu:
            // Menu dismisses only when controls are visible; otherwise shows them first
            if state.showControls {
                dismiss(animated: true)
            } else {
                showControlsTemporarily()
            }

        case .select:
            // Select toggles play/pause only when controls are visible and no SwiftUI
            // element intercepted the press (SwiftUI buttons consume presses before UIKit).
            if state.showControls {
                togglePlayPause()
            } else {
                showControlsTemporarily()
            }
            super.pressesBegan(presses, with: event)

        case .leftArrow, .rightArrow:
            // Show controls and pass to SwiftUI so the focused scrubber's
            // onMoveCommand handles seeking. Never seek unconditionally here,
            // because left/right is also used to navigate between focusable buttons.
            showControlsTemporarily()
            super.pressesBegan(presses, with: event)

        default:
            showControlsTemporarily()
            super.pressesBegan(presses, with: event)
        }
    }
}
#endif
