import SwiftUI
import AVKit
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playback")

// MARK: - tvOS AVPlayerViewController wrapper

#if os(tvOS)
struct TVPlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
#endif

// MARK: - Episode Navigation

struct EpisodeRef: Sendable {
    let id: String
    let title: String
}

/// Returns (new PlaybackInfo, new previousEpisode, new nextEpisode) for a given episode ID.
typealias EpisodeNavigator = @Sendable (String) async -> (JellyfinAPIClient.PlaybackInfo, EpisodeRef?, EpisodeRef?)?

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
                #if os(tvOS)
                TVPlayerViewController(player: player)
                    .ignoresSafeArea()
                #else
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
                #endif
            } else if let error = errorMessage {
                VStack(spacing: CinemaSpacing.spacing3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
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

            let playerItem = AVPlayerItem(url: info.url)
            playerItem.preferredForwardBufferDuration = 5

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

            let playerItem = AVPlayerItem(url: info.url)
            playerItem.preferredForwardBufferDuration = 5
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

            let playerItem = AVPlayerItem(url: info.url)
            playerItem.preferredForwardBufferDuration = 5
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

// MARK: - tvOS UIKit Video Presentation

/// Presents TVPlayerHostViewController via UIKit modal presentation,
/// completely bypassing SwiftUI's view hierarchy. This prevents
/// NavigationSplitView focus corruption on dismiss, and gives us a
/// fully custom transport bar with correct Jellyfin track metadata.
#if os(tvOS)
@MainActor
final class TVVideoPresenter {

    static func present(
        title: String,
        info: JellyfinAPIClient.PlaybackInfo,
        startTime: Double? = nil,
        previousEpisode: EpisodeRef? = nil,
        nextEpisode: EpisodeRef? = nil,
        episodeNavigator: EpisodeNavigator? = nil,
        onTrackChange: @escaping (Int?, Int?) async -> URL?
    ) {
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first?.rootViewController else {
            logger.error("TVVideoPresenter: no root view controller")
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let playerVC = TVPlayerHostViewController(
            title: title,
            info: info,
            startTime: startTime,
            previousEpisode: previousEpisode,
            nextEpisode: nextEpisode,
            episodeNavigator: episodeNavigator,
            onTrackChange: onTrackChange
        )
        topVC.present(playerVC, animated: true)
    }
}
#endif

// MARK: - Video Player Coordinator (tvOS)

/// Coordinates playback on tvOS. Fetches the stream URL via the API client,
/// then hands off to TVVideoPresenter for pure-UIKit modal presentation.
#if os(tvOS)
@MainActor @Observable
final class VideoPlayerCoordinator {
    @ObservationIgnored
    @AppStorage("forceSubtitles") private var forceSubtitles: Bool = false
    @ObservationIgnored
    @AppStorage("render4K") private var render4K: Bool = true

    var maxBitrate: Int { render4K ? 120_000_000 : 20_000_000 }

    func play(
        itemId: String, title: String, startTime: Double? = nil,
        previousEpisode: EpisodeRef? = nil, nextEpisode: EpisodeRef? = nil,
        episodeNavigator: EpisodeNavigator? = nil,
        using appState: AppState
    ) {
        let bitrate = maxBitrate
        let apiClient = appState.apiClient
        Task {
            guard let userId = appState.currentUserId else {
                logger.error("VideoPlayerCoordinator: not authenticated")
                return
            }
            do {
                let info = try await apiClient.getPlaybackInfo(itemId: itemId, userId: userId, maxBitrate: bitrate)
                logger.info("tvOS play: method=\(info.playMethod), url=\(info.url.absoluteString)")
                TVVideoPresenter.present(
                    title: title, info: info, startTime: startTime,
                    previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                    episodeNavigator: episodeNavigator
                ) { audioIdx, subtitleIdx in
                    return try? await apiClient.getPlaybackInfo(
                        itemId: itemId, userId: userId, maxBitrate: bitrate,
                        audioStreamIndex: audioIdx, subtitleStreamIndex: subtitleIdx
                    ).url
                }
            } catch {
                logger.error("tvOS playback error: \(error.localizedDescription)")
            }
        }
    }
}
#endif

// MARK: - Cross-platform Play Link

/// On tvOS, uses VideoPlayerCoordinator for UIKit-based modal presentation.
/// On iOS, uses a standard NavigationLink push.
struct PlayLink<Label: View>: View {
    let itemId: String
    let title: String
    var startTime: Double? = nil
    var previousEpisode: EpisodeRef? = nil
    var nextEpisode: EpisodeRef? = nil
    var episodeNavigator: EpisodeNavigator? = nil
    @ViewBuilder let label: () -> Label

    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState
    #endif

    var body: some View {
        #if os(tvOS)
        Button {
            coordinator.play(
                itemId: itemId, title: title, startTime: startTime,
                previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                episodeNavigator: episodeNavigator, using: appState
            )
        } label: {
            label()
        }
        #else
        NavigationLink {
            VideoPlayerView(
                itemId: itemId, title: title, startTime: startTime,
                previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                episodeNavigator: episodeNavigator
            )
        } label: {
            label()
        }
        #endif
    }
}

// MARK: - Track Picker Sheet

/// Unified audio + subtitle track picker, used on both iOS (sheet) and tvOS (pre-play sheet).
struct TrackPickerSheet: View {
    let info: JellyfinAPIClient.PlaybackInfo
    /// Called with (audioStreamIndex, subtitleStreamIndex). nil = keep current / off.
    let onConfirm: (Int?, Int?) -> Void

    @Environment(LocalizationManager.self) private var loc
    @State private var audioId: Int?
    @State private var subtitleId: Int?  // -1 = off, nil initially resolved to current or off

    private let noSubtitle = -1

    init(info: JellyfinAPIClient.PlaybackInfo, onConfirm: @escaping (Int?, Int?) -> Void) {
        self.info = info
        self.onConfirm = onConfirm
        _audioId = State(initialValue: info.selectedAudioIndex ?? info.audioTracks.first(where: { $0.isDefault })?.id ?? info.audioTracks.first?.id)
        _subtitleId = State(initialValue: info.selectedSubtitleIndex)
    }

    var body: some View {
        NavigationView {
            List {
                if !info.audioTracks.isEmpty {
                    Section(loc.localized("player.audio")) {
                        ForEach(info.audioTracks) { track in
                            Button {
                                audioId = track.id
                            } label: {
                                HStack {
                                    Text(track.label)
                                        .foregroundStyle(CinemaColor.onSurface)
                                    Spacer()
                                    if audioId == track.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !info.subtitleTracks.isEmpty {
                    Section(loc.localized("player.subtitles")) {
                        // "Off" option
                        Button {
                            subtitleId = noSubtitle
                        } label: {
                            HStack {
                                Text(loc.localized("player.subtitles.off"))
                                    .foregroundStyle(CinemaColor.onSurface)
                                Spacer()
                                if subtitleId == noSubtitle || subtitleId == nil {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        ForEach(info.subtitleTracks) { track in
                            Button {
                                subtitleId = track.id
                            } label: {
                                HStack {
                                    Text(track.label)
                                        .foregroundStyle(CinemaColor.onSurface)
                                    Spacer()
                                    if subtitleId == track.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(loc.localized("player.trackPicker.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.localized("action.play")) {
                        onConfirm(audioId, subtitleId == noSubtitle ? -1 : subtitleId)
                    }
                    .fontWeight(.semibold)
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.localized("action.play")) {
                        onConfirm(audioId, subtitleId == noSubtitle ? -1 : subtitleId)
                    }
                }
            }
            #endif
        }
    }
}
