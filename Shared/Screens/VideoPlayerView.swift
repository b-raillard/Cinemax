import SwiftUI
import AVKit
import AVFoundation
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playback")

// MARK: - Video Player View

struct VideoPlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var playMethod: PlayMethod?
    @State private var isLoading = true
    @State private var playerObservation: NSKeyValueObservation?
    @State private var playbackInfo: PlaybackInfo?
    @State private var showTrackPicker = false
    @State private var progressReportTask: Task<Void, Never>?

    // Mutable episode context — updated when navigating between episodes
    @State private var currentItemId: String
    @State private var currentTitle: String
    @State private var currentStartTime: Double?
    @State private var currentPrevEpisode: EpisodeRef?
    @State private var currentNextEpisode: EpisodeRef?
    let episodeNavigator: EpisodeNavigator?

    init(
        itemId: String,
        title: String,
        startTime: Double? = nil,
        previousEpisode: EpisodeRef? = nil,
        nextEpisode: EpisodeRef? = nil,
        episodeNavigator: EpisodeNavigator? = nil
    ) {
        _currentItemId = State(initialValue: itemId)
        _currentTitle = State(initialValue: title)
        _currentStartTime = State(initialValue: startTime)
        _currentPrevEpisode = State(initialValue: previousEpisode)
        _currentNextEpisode = State(initialValue: nextEpisode)
        self.episodeNavigator = episodeNavigator
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .sheet(isPresented: $showTrackPicker) {
                        if let info = playbackInfo {
                            TrackPickerSheet(info: info) { audioIdx, subtitleIdx in
                                showTrackPicker = false
                                Task { await restartWithTracks(audioIndex: audioIdx, subtitleIndex: subtitleIdx) }
                            }
                        }
                    }
            } else if let error = errorMessage {
                VStack(spacing: CinemaSpacing.spacing3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: CinemaScale.pt(48)))
                        .foregroundStyle(CinemaColor.error)
                    Text(error)
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    if let method = playMethod {
                        Text(loc.localized("player.method", method.rawValue))
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.outline)
                    }
                    CinemaButton(title: loc.localized("action.retry"), style: .ghost) {
                        Task { await startPlayback() }
                    }
                    .frame(width: 160)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                    Text(loc.localized("player.preparing"))
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(currentTitle)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    if let prev = currentPrevEpisode, episodeNavigator != nil {
                        Button { navigateToEpisode(prev) } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(CinemaColor.onSurface)
                        }
                        .accessibilityLabel(loc.localized("accessibility.previousEpisode"))
                        .accessibilityHint(prev.title)
                    }
                    if let next = currentNextEpisode, episodeNavigator != nil {
                        Button { navigateToEpisode(next) } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(CinemaColor.onSurface)
                        }
                        .accessibilityLabel(loc.localized("accessibility.nextEpisode"))
                        .accessibilityHint(next.title)
                    }
                    if let info = playbackInfo, info.audioTracks.count > 1 || !info.subtitleTracks.isEmpty {
                        Button { showTrackPicker = true } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(CinemaColor.onSurface)
                        }
                        .accessibilityLabel(loc.localized("accessibility.trackOptions"))
                    }
                }
            }
        }
        #endif
        .task {
            await startPlayback()
        }
        .onDisappear {
            reportPlaybackStop()
            cleanup()
        }
    }

    // MARK: - Playback Reporting

    private func reportPlaybackStart() {
        guard let info = playbackInfo, let userId = appState.currentUserId else { return }
        let positionTicks = currentStartTime.map { Int($0 * 10_000_000) } ?? 0
        let itemId = currentItemId
        let apiClient = appState.apiClient
        Task.detached {
            await apiClient.reportPlaybackStart(
                itemId: itemId, userId: userId,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, playMethod: info.playMethod
            )
        }
    }

    private func reportPlaybackStop() {
        guard let info = playbackInfo, let userId = appState.currentUserId else { return }
        let positionTicks = Int((player?.currentTime().seconds ?? 0) * 10_000_000)
        let itemId = currentItemId
        let apiClient = appState.apiClient
        Task.detached {
            await apiClient.reportPlaybackStopped(
                itemId: itemId, userId: userId,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks
            )
        }
    }

    private func startProgressReporting() {
        progressReportTask?.cancel()
        guard let info = playbackInfo, let userId = appState.currentUserId else { return }
        let itemId = currentItemId
        let apiClient = appState.apiClient
        progressReportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                let ticks = Int((player?.currentTime().seconds ?? 0) * 10_000_000)
                let isPaused = player?.rate == 0
                await apiClient.reportPlaybackProgress(
                    itemId: itemId, userId: userId,
                    mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                    positionTicks: ticks, isPaused: isPaused, playMethod: info.playMethod
                )
            }
        }
    }

    // MARK: - Playback

    private func startPlayback() async {
        cleanup()
        errorMessage = nil
        isLoading = true

        guard let userId = appState.currentUserId else {
            errorMessage = "Not authenticated"
            isLoading = false
            return
        }

        do {
            let info = try await appState.apiClient.getPlaybackInfo(itemId: currentItemId, userId: userId)
            playMethod = info.playMethod
            self.playbackInfo = info
            logger.info("Starting playback: method=\(info.playMethod.rawValue), url=\(info.url.absoluteString)")

            let playerItem = makePlayerItem(for: info)
            let avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer.automaticallyWaitsToMinimizeStalling = true

            let startTime = currentStartTime
            playerObservation = playerItem.observe(\.status) { item, _ in
                Task { @MainActor in
                    switch item.status {
                    case .failed:
                        let err = item.error
                        logger.error("AVPlayer failed: \(err?.localizedDescription ?? "unknown")")
                        if let urlError = err as? URLError {
                            logger.error("URLError code: \(urlError.code.rawValue)")
                        }
                        errorMessage = err?.localizedDescription ?? "Playback failed"
                        cleanup()
                    case .readyToPlay:
                        logger.info("AVPlayer ready to play")
                        if let st = startTime, st > 0 {
                            avPlayer.seek(
                                to: CMTime(seconds: st, preferredTimescale: 600),
                                toleranceBefore: .zero,
                                toleranceAfter: .zero
                            )
                        }
                        isLoading = false
                    default:
                        break
                    }
                }
            }

            self.player = avPlayer
            avPlayer.play()
            reportPlaybackStart()
            startProgressReporting()
        } catch {
            logger.error("Playback setup error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func navigateToEpisode(_ ep: EpisodeRef) {
        guard let navigator = episodeNavigator else { return }
        Task {
            reportPlaybackStop()
            guard let (info, prev, next) = await navigator(ep.id) else { return }
            cleanup()
            currentItemId = ep.id
            currentTitle = ep.title
            currentStartTime = nil
            currentPrevEpisode = prev
            currentNextEpisode = next
            isLoading = true
            errorMessage = nil
            playMethod = info.playMethod
            playbackInfo = info

            let playerItem = makePlayerItem(for: info)
            let avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer.automaticallyWaitsToMinimizeStalling = true

            playerObservation = playerItem.observe(\.status) { item, _ in
                Task { @MainActor in
                    switch item.status {
                    case .readyToPlay:
                        isLoading = false
                    case .failed:
                        logger.error("AVPlayer failed on episode nav: \(item.error?.localizedDescription ?? "unknown")")
                        errorMessage = item.error?.localizedDescription ?? "Playback failed"
                        cleanup()
                    default: break
                    }
                }
            }
            self.player = avPlayer
            avPlayer.play()
            reportPlaybackStart()
            startProgressReporting()
        }
    }

    private func cleanup() {
        progressReportTask?.cancel()
        progressReportTask = nil
        playerObservation?.invalidate()
        playerObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func makePlayerItem(for info: PlaybackInfo) -> AVPlayerItem {
        let item: AVPlayerItem
        if let token = info.authToken {
            let asset = AVURLAsset(url: info.url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "MediaBrowser Token=\(token)"]
            ])
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: info.url)
        }
        item.preferredForwardBufferDuration = 5
        return item
    }

    private func restartWithTracks(audioIndex: Int?, subtitleIndex: Int?) async {
        guard let userId = appState.currentUserId else { return }
        let savedTime = player?.currentTime() ?? .zero
        cleanup()
        isLoading = true
        errorMessage = nil
        do {
            let info = try await appState.apiClient.getPlaybackInfo(
                itemId: currentItemId, userId: userId,
                audioStreamIndex: audioIndex,
                subtitleStreamIndex: subtitleIndex
            )
            playbackInfo = info
            playMethod = info.playMethod

            let playerItem = makePlayerItem(for: info)
            let avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer.automaticallyWaitsToMinimizeStalling = true

            playerObservation = playerItem.observe(\.status) { item, _ in
                Task { @MainActor in
                    switch item.status {
                    case .readyToPlay:
                        if savedTime.seconds > 0 { avPlayer.seek(to: savedTime) }
                        isLoading = false
                    case .failed:
                        errorMessage = item.error?.localizedDescription ?? "Playback failed"
                        cleanup()
                    default: break
                    }
                }
            }
            self.player = avPlayer
            avPlayer.play()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

