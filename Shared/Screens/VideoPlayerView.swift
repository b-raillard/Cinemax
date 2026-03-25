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

// MARK: - Video Player View

struct VideoPlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var playMethod: String?
    @State private var isLoading = true
    @State private var playerObservation: NSKeyValueObservation?

    let itemId: String
    let title: String

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
                Text(title)
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
            let info = try await appState.apiClient.getPlaybackInfo(itemId: itemId, userId: userId)
            playMethod = info.playMethod
            logger.info("Starting playback: method=\(info.playMethod), url=\(info.url.absoluteString)")

            let playerItem = AVPlayerItem(url: info.url)
            playerItem.preferredForwardBufferDuration = 5

            let avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer.automaticallyWaitsToMinimizeStalling = true

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

    private func cleanup() {
        playerObservation?.invalidate()
        playerObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

// MARK: - tvOS UIKit Video Presentation

/// Presents AVPlayerViewController directly via UIKit modal presentation,
/// completely bypassing SwiftUI's view hierarchy. This prevents
/// NavigationSplitView focus corruption on dismiss.
#if os(tvOS)
@MainActor
final class TVVideoPresenter {

    static func present(url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first?.rootViewController else {
            logger.error("TVVideoPresenter: no root view controller")
            return
        }

        // Walk up to the topmost presented VC
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 5

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.modalPresentationStyle = .fullScreen

        topVC.present(playerVC, animated: true) {
            player.play()
        }
    }
}
#endif

// MARK: - Video Player Coordinator (tvOS)

/// Coordinates playback on tvOS. Fetches the stream URL via the API client,
/// then hands off to TVVideoPresenter for pure-UIKit modal presentation.
#if os(tvOS)
@MainActor @Observable
final class VideoPlayerCoordinator {

    func play(itemId: String, title: String, using appState: AppState) {
        Task {
            guard let userId = appState.currentUserId else {
                logger.error("VideoPlayerCoordinator: not authenticated")
                return
            }
            do {
                let info = try await appState.apiClient.getPlaybackInfo(itemId: itemId, userId: userId)
                logger.info("tvOS play: method=\(info.playMethod), url=\(info.url.absoluteString)")
                TVVideoPresenter.present(url: info.url)
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
    @ViewBuilder let label: () -> Label

    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState
    #endif

    var body: some View {
        #if os(tvOS)
        Button {
            coordinator.play(itemId: itemId, title: title, using: appState)
        } label: {
            label()
        }
        #else
        NavigationLink {
            VideoPlayerView(itemId: itemId, title: title)
        } label: {
            label()
        }
        #endif
    }
}
