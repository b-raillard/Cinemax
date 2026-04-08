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
    @State private var playMethod: String?
    @State private var isLoading = true
    @State private var playerObservation: NSKeyValueObservation?
    @State private var playbackInfo: JellyfinAPIClient.PlaybackInfo?
    @State private var showTrackPicker = false

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
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 0) {
                            if let prev = currentPrevEpisode, episodeNavigator != nil {
                                Button { navigateToEpisode(prev) } label: {
                                    Image(systemName: "backward.end.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .shadow(radius: 4)
                                        .padding(12)
                                }
                            }
                            if let next = currentNextEpisode, episodeNavigator != nil {
                                Button { navigateToEpisode(next) } label: {
                                    Image(systemName: "forward.end.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .shadow(radius: 4)
                                        .padding(12)
                                }
                            }
                            if let info = playbackInfo, info.audioTracks.count > 1 || !info.subtitleTracks.isEmpty {
                                Button { showTrackPicker = true } label: {
                                    Image(systemName: "ellipsis.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .shadow(radius: 4)
                                        .padding(12)
                                }
                            }
                        }
                        .padding(.trailing, 4)
                    }
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
                        Text(loc.localized("player.method", method))
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(currentTitle)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
            }
        }
        #endif
        .task {
            await startPlayback()
        }
        .onDisappear {
            cleanup()
        }
    }

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
            logger.info("Starting playback: method=\(info.playMethod), url=\(info.url.absoluteString)")

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
        } catch {
            logger.error("Playback setup error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func navigateToEpisode(_ ep: EpisodeRef) {
        guard let navigator = episodeNavigator else { return }
        Task {
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
        }
    }

    private func cleanup() {
        playerObservation?.invalidate()
        playerObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func makePlayerItem(for info: JellyfinAPIClient.PlaybackInfo) -> AVPlayerItem {
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

