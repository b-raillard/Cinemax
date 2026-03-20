import SwiftUI
import AVKit
import CinemaxKit

struct VideoPlayerView: View {
    @Environment(AppState.self) private var appState
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
                VideoPlayer(player: player)
                    .ignoresSafeArea()
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
                        Text("Method: \(method)")
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.outline)
                    }
                    CinemaButton(title: "Retry", style: .ghost) {
                        Task { await startPlayback() }
                    }
                    .frame(width: 160)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                    Text("Preparing stream...")
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
            // Ask Jellyfin to negotiate the best playback method
            let info = try await appState.apiClient.getPlaybackInfo(itemId: itemId, userId: userId)
            playMethod = info.playMethod
            #if DEBUG
            print("[Cinemax] Starting playback: method=\(info.playMethod), url=\(info.url)")
            #endif

            let playerItem = AVPlayerItem(url: info.url)
            let avPlayer = AVPlayer(playerItem: playerItem)

            // Observe for errors
            playerObservation = playerItem.observe(\.status) { item, _ in
                Task { @MainActor in
                    switch item.status {
                    case .failed:
                        let err = item.error
                        #if DEBUG
                        print("[Cinemax] AVPlayer FAILED: \(err?.localizedDescription ?? "unknown")")
                        if let urlError = err as? URLError {
                            print("[Cinemax]   URLError code: \(urlError.code.rawValue)")
                        }
                        #endif
                        errorMessage = err?.localizedDescription ?? "Playback failed"
                        cleanup()
                    case .readyToPlay:
                        #if DEBUG
                        print("[Cinemax] AVPlayer ready to play")
                        #endif
                        isLoading = false
                    default:
                        break
                    }
                }
            }

            self.player = avPlayer
            avPlayer.play()
        } catch {
            #if DEBUG
            print("[Cinemax] Playback setup error: \(error)")
            #endif
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func cleanup() {
        playerObservation?.invalidate()
        playerObservation = nil
        player?.pause()
        player = nil
    }
}
