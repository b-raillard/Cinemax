import SwiftUI
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playback")

// MARK: - Video Player View (iOS entry point)

struct VideoPlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode: Bool = true
    @AppStorage("render4K") private var render4K: Bool = true

    let itemId: String
    let title: String
    var startTime: Double? = nil
    var previousEpisode: EpisodeRef? = nil
    var nextEpisode: EpisodeRef? = nil
    var episodeNavigator: EpisodeNavigator? = nil

    #if os(iOS)
    @State private var presenter: NativeVideoPresenter?
    @State private var didPresent = false
    #endif

    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if os(iOS)
            // iOS: present AVPlayerViewController full-screen modally
            if let error = errorMessage {
                iOSErrorView(error: error)
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
            #else
            // tvOS: VideoPlayerView is not used directly — playback goes through VideoPlayerCoordinator.
            // This branch should not be reached in normal flow.
            if let error = errorMessage {
                Text(error).foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
            #endif
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { await startIOSPlayback() }
        #endif
    }

    // MARK: - iOS Playback

    #if os(iOS)
    private func startIOSPlayback() async {
        guard !didPresent else { return }
        guard let userId = appState.currentUserId else {
            errorMessage = "Not authenticated"
            return
        }

        do {
            let bitrate = render4K ? 120_000_000 : 20_000_000
            let info = try await appState.apiClient.getPlaybackInfo(itemId: itemId, userId: userId, maxBitrate: bitrate)
            #if DEBUG
            logger.info("iOS play: method=\(info.playMethod.rawValue), url=\(info.url.absoluteString)")
            #endif

            let p = NativeVideoPresenter(
                itemId: itemId, title: title, startTime: startTime,
                previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                episodeNavigator: episodeNavigator,
                apiClient: appState.apiClient, userId: userId,
                maxBitrate: bitrate, loc: loc,
                autoPlayNextEpisode: autoPlayNextEpisode,
                imageBuilder: appState.imageBuilder,
                onDismiss: { dismiss() }
            )
            presenter = p
            didPresent = true
            p.present(info: info)
        } catch {
            logger.error("iOS playback error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func iOSErrorView(error: String) -> some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: CinemaScale.pt(48)))
                .foregroundStyle(CinemaColor.error)
            Text(error)
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            CinemaButton(title: loc.localized("action.retry"), style: .ghost) {
                didPresent = false
                errorMessage = nil
                Task { await startIOSPlayback() }
            }
            .frame(width: 160)
        }
    }
    #endif
}
