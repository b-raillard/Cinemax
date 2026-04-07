#if os(tvOS)
import SwiftUI
import AVFoundation
import UIKit
import OSLog
import CinemaxKit

private let tvPlayerLog = Logger(subsystem: "com.cinemax", category: "TVPlayer")

// MARK: - Player State

@MainActor @Observable
final class TVPlayerState {
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying: Bool = false
    var isBuffering: Bool = true
    var showControls: Bool = true
    var currentAudioIdx: Int?
    var currentSubtitleIdx: Int?
    var title: String = ""
    var previousEpisode: EpisodeRef?
    var nextEpisode: EpisodeRef?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, currentTime / duration)
    }

    var formattedCurrentTime: String { Self.format(currentTime) }

    var formattedRemaining: String {
        guard duration > 0 else { return "" }
        return "-" + Self.format(max(0, duration - currentTime))
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}

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

        let item = AVPlayerItem(url: info.url)
        item.preferredForwardBufferDuration = 5
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
            Task { @MainActor [weak self] in
                guard let self else { return }
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

            let newItem = AVPlayerItem(url: newURL)
            newItem.preferredForwardBufferDuration = 5

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

            let newItem = AVPlayerItem(url: newInfo.url)
            newItem.preferredForwardBufferDuration = 5

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

// MARK: - Overlay View

/// Top-level overlay. Only observes `state.isBuffering` and `state.showControls`.
/// Time-dependent and track-dependent rendering is delegated to isolated sub-views
/// so that the frequent currentTime updates do not re-render the Menu buttons.
struct TVPlayerOverlayView: View {
    let state: TVPlayerState
    let info: JellyfinAPIClient.PlaybackInfo
    let onPlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onAudioChange: (Int?) -> Void
    let onSubtitleChange: (Int?) -> Void
    let onDismiss: () -> Void
    let onInteraction: () -> Void
    let onPreviousEpisode: () -> Void
    let onNextEpisode: () -> Void

    var body: some View {
        // Accesses only state.isBuffering + state.showControls — re-renders only on those.
        ZStack {
            if state.isBuffering {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(2)
            }

            if state.showControls {
                TVControlsOverlay(
                    state: state,
                    info: info,
                    onSeek: onSeek,
                    onAudioChange: onAudioChange,
                    onSubtitleChange: onSubtitleChange,
                    onInteraction: onInteraction,
                    onPreviousEpisode: onPreviousEpisode,
                    onNextEpisode: onNextEpisode
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: state.showControls)
    }
}

// MARK: - Controls Overlay

/// Layout shell: title + glass controls strip. Owns the single @FocusState
/// for all interactive elements so SwiftUI can reliably restore focus to the
/// correct button after a Menu is dismissed with the back button.
private struct TVControlsOverlay: View {

    private enum FocusItem: Hashable { case scrubber, audio, subtitle, previousEpisode, nextEpisode }

    let state: TVPlayerState
    let info: JellyfinAPIClient.PlaybackInfo
    let onSeek: (Double) -> Void
    let onAudioChange: (Int?) -> Void
    let onSubtitleChange: (Int?) -> Void
    let onInteraction: () -> Void
    let onPreviousEpisode: () -> Void
    let onNextEpisode: () -> Void

    @FocusState private var focus: FocusItem?

    // Seek flash indicators — local UI state only
    @State private var showBackwardSeek = false
    @State private var showForwardSeek = false
    @State private var backwardSeekTask: Task<Void, Never>?
    @State private var forwardSeekTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            // Title floats at top — reads from state.title so it updates after episode navigation
            HStack {
                Text(state.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
                    .lineLimit(1)
                Spacer()
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 72)
            .padding(.top, 48)

            // Center: play/pause status + seek flash indicators
            HStack(spacing: 80) {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .opacity(showBackwardSeek ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: showBackwardSeek)

                Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 80, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 10)

                Image(systemName: "goforward.15")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .opacity(showForwardSeek ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: showForwardSeek)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // Shift up slightly so it sits in the visual center above the scrubber strip
            .padding(.bottom, 160)

            // Floating controls — no background container, elements float on video
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Spacer()
                    if state.previousEpisode != nil {
                        Button {
                            onInteraction()
                            onPreviousEpisode()
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(focus == .previousEpisode ? Color.black.opacity(0.8) : .white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 14)
                                .background(
                                    focus == .previousEpisode
                                        ? AnyShapeStyle(.white)
                                        : AnyShapeStyle(.regularMaterial),
                                    in: Capsule()
                                )
                                .animation(.easeInOut(duration: 0.15), value: focus == .previousEpisode)
                        }
                        .focused($focus, equals: .previousEpisode)
                        .focusEffectDisabled()
                    }
                    if state.nextEpisode != nil {
                        Button {
                            onInteraction()
                            onNextEpisode()
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(focus == .nextEpisode ? Color.black.opacity(0.8) : .white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 14)
                                .background(
                                    focus == .nextEpisode
                                        ? AnyShapeStyle(.white)
                                        : AnyShapeStyle(.regularMaterial),
                                    in: Capsule()
                                )
                                .animation(.easeInOut(duration: 0.15), value: focus == .nextEpisode)
                        }
                        .focused($focus, equals: .nextEpisode)
                        .focusEffectDisabled()
                    }
                    if !info.audioTracks.isEmpty {
                        TVAudioTrackMenu(
                            state: state,
                            tracks: info.audioTracks,
                            isFocused: focus == .audio,
                            onInteraction: onInteraction,
                            onAudioChange: onAudioChange
                        )
                        .focused($focus, equals: .audio)
                        .focusEffectDisabled()
                    }
                    if !info.subtitleTracks.isEmpty {
                        TVSubtitleTrackMenu(
                            state: state,
                            tracks: info.subtitleTracks,
                            isFocused: focus == .subtitle,
                            onInteraction: onInteraction,
                            onSubtitleChange: onSubtitleChange
                        )
                        .focused($focus, equals: .subtitle)
                        .focusEffectDisabled()
                    }
                }

                // Scrubber: glass pill container, focus + seek handled here
                TVPlayerScrubber(state: state, isFocused: focus == .scrubber)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .focusable()
                    .focused($focus, equals: .scrubber)
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        switch direction {
                        case .left:
                            onSeek(-15)
                            flashSeekIndicator(forward: false)
                        case .right:
                            onSeek(15)
                            flashSeekIndicator(forward: true)
                        default: break
                        }
                    }
            }
            .padding(.horizontal, 72)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = .scrubber }
        // Reset auto-hide timer whenever focus moves to any interactive element
        .onChange(of: focus) { _, _ in onInteraction() }
    }

    /// Shows the seek flash indicator for 500 ms then fades it out.
    /// Rapid consecutive seeks reset the timer so the icon stays visible throughout.
    private func flashSeekIndicator(forward: Bool) {
        if forward {
            forwardSeekTask?.cancel()
            showForwardSeek = true
            forwardSeekTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                showForwardSeek = false
            }
        } else {
            backwardSeekTask?.cancel()
            showBackwardSeek = true
            backwardSeekTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                showBackwardSeek = false
            }
        }
    }
}

// MARK: - Scrubber

/// Display-only. Focus management and onMoveCommand live in TVControlsOverlay
/// so the parent's @FocusState owns the binding and correctly restores focus
/// to any sibling button after a Menu is dismissed with the back button.
private struct TVPlayerScrubber: View {
    let state: TVPlayerState
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(height: isFocused ? 8 : 5)
                    Capsule()
                        .fill(.white)
                        .frame(width: geo.size.width * state.progress,
                               height: isFocused ? 8 : 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .animation(.easeInOut(duration: 0.15), value: isFocused)
            }
            .frame(height: 16)

            HStack {
                Text(state.formattedCurrentTime)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
                Spacer()
                Text(state.formattedRemaining)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
            }
        }
    }
}

// MARK: - Audio Track Menu

/// Isolated sub-view. Only accesses state.currentAudioIdx — never re-renders on time updates.
/// Selecting the already-active track is a no-op (no stream restart).
private struct TVAudioTrackMenu: View {
    let state: TVPlayerState
    let tracks: [MediaTrackInfo]
    let isFocused: Bool
    let onInteraction: () -> Void
    let onAudioChange: (Int?) -> Void

    var body: some View {
        Menu {
            ForEach(tracks) { track in
                Button {
                    onInteraction()
                    guard state.currentAudioIdx != track.id else { return }
                    onAudioChange(track.id)
                } label: {
                    if state.currentAudioIdx == track.id {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isFocused ? Color.black.opacity(0.8) : .white)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.regularMaterial), in: Capsule())
                .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }
}

// MARK: - Subtitle Track Menu

/// Isolated sub-view. Only accesses state.currentSubtitleIdx — never re-renders on time updates.
/// Selecting the already-active subtitle (or "off" when already off) is a no-op.
private struct TVSubtitleTrackMenu: View {
    let state: TVPlayerState
    let tracks: [MediaTrackInfo]
    let isFocused: Bool
    let onInteraction: () -> Void
    let onSubtitleChange: (Int?) -> Void

    private var lang: String { UserDefaults.standard.string(forKey: "language") ?? "fr" }
    private var offLabel: String { lang == "fr" ? "Désactivé" : "Off" }
    private var isOff: Bool { state.currentSubtitleIdx == nil || state.currentSubtitleIdx == -1 }

    var body: some View {
        Menu {
            Button {
                onInteraction()
                guard !isOff else { return }
                onSubtitleChange(-1)
            } label: {
                if isOff {
                    Label(offLabel, systemImage: "checkmark")
                } else {
                    Text(offLabel)
                }
            }
            ForEach(tracks) { track in
                Button {
                    onInteraction()
                    guard state.currentSubtitleIdx != track.id else { return }
                    onSubtitleChange(track.id)
                } label: {
                    if state.currentSubtitleIdx == track.id {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isFocused ? Color.black.opacity(0.8) : .white)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.regularMaterial), in: Capsule())
                .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }
}
#endif
