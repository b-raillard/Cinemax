import SwiftUI
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playback")

// MARK: - Video Player View (iOS entry point)

struct VideoPlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(DownloadManager.self) private var downloads
    #endif
    @AppStorage(SettingsKey.autoPlayNextEpisode) private var autoPlayNextEpisode: Bool = SettingsKey.Default.autoPlayNextEpisode
    @AppStorage(SettingsKey.render4K) private var render4K: Bool = SettingsKey.Default.render4K
    @AppStorage(SettingsKey.forceNativeAVPlayer) private var forceNativeAVPlayer: Bool = SettingsKey.Default.forceNativeAVPlayer

    let itemId: String
    let title: String
    var startTime: Double? = nil
    var previousEpisode: EpisodeRef? = nil
    var nextEpisode: EpisodeRef? = nil
    var episodeNavigator: EpisodeNavigator? = nil

    #if os(iOS)
    @State private var presenter: NativeVideoPresenter?
    // One VLC presenter for both modes — stream and offline. Two refs let the
    // SwiftUI state machine cleanly distinguish "I started a stream" vs
    // "I started an offline session" without juggling a sum type.
    @State private var vlcStreamPresenter: VLCStreamPresenter?
    @State private var vlcOfflinePresenter: VLCStreamPresenter?
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
            // tvOS: VideoPlayerView is normally bypassed — playback goes through
            // VideoPlayerCoordinator. This branch can still be reached if a
            // future code path mounts VideoPlayerView directly, so render a
            // styled error card matching the iOS pattern instead of leaking a
            // raw NSError string onto a black screen.
            if let error = errorMessage {
                tvOSErrorView(error: error)
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
            errorMessage = loc.localized("error.sessionExpired")
            return
        }

        do {
            let bitrate = render4K ? 120_000_000 : 20_000_000
            // Offline resume: an explicit caller `startTime` always wins;
            // otherwise fall back to the locally-persisted offline playhead from
            // a previous offline session (unless the item is already watched).
            // For online items `downloads.item(for:)` is nil, so this is just
            // `startTime` — no behavior change on the streaming paths.
            let resolvedStartTime: Double? = startTime ?? downloads.item(for: itemId).flatMap { entry in
                entry.watched == true ? nil : entry.lastPositionMs.map { Double($0) / 1000 }
            }
            // Offline-completed file gets two routes:
            //   1. AVKit-friendly container → AVPlayer (full feature set —
            //      skip intro/outro, chapter markers, AirPlay, PiP).
            //   2. MKV / AVI / WebM → libVLC via `VLCStreamPresenter` in
            //      offline mode: same HUD as online (audio/subtitle pickers,
            //      sleep timer, ±N skip, PiP) minus the network-only bits.
            let info: PlaybackInfo
            if let entry = downloads.item(for: itemId), entry.status == .completed,
               let local = downloads.localURL(forItemId: itemId) {
                if entry.isOfflinePlayable {
                    info = PlaybackInfo(
                        url: local,
                        playSessionId: nil,
                        mediaSourceId: itemId,
                        playMethod: .directStream,
                        audioTracks: [], subtitleTracks: [],
                        selectedAudioIndex: nil, selectedSubtitleIndex: nil,
                        authToken: nil
                    )
                    #if DEBUG
                    logger.info("iOS play (offline AVKit): \(local.lastPathComponent)")
                    #endif
                } else {
                    // Hand off to libVLC and skip the rest of the AVKit path.
                    presentVLC(localURL: local, startTime: resolvedStartTime)
                    return
                }
            } else if !forceNativeAVPlayer {
                // Default online path: VLC DirectPlays the raw file (no server
                // transcode → no freeze, 4K/HEVC/Dolby Vision preserved).
                let vlcInfo = try await appState.apiClient.getPlaybackInfo(
                    itemId: itemId, userId: userId, maxBitrate: bitrate, engine: .vlc
                )
                #if DEBUG
                logger.info("iOS play: engine=vlc, method=\(vlcInfo.playMethod.rawValue), url=\(redactedURL(vlcInfo.url))")
                #endif
                let v = VLCStreamPresenter(
                    itemId: itemId, title: title, startTime: startTime,
                    previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                    episodeNavigator: episodeNavigator,
                    apiClient: appState.apiClient, userId: userId,
                    autoPlayNext: autoPlayNextEpisode, maxBitrate: bitrate,
                    imageBuilder: appState.imageBuilder, loc: loc,
                    onDismiss: { dismiss() }
                )
                vlcStreamPresenter = v
                didPresent = true
                v.present(info: vlcInfo)
                return
            } else {
                info = try await appState.apiClient.getPlaybackInfo(itemId: itemId, userId: userId, maxBitrate: bitrate, engine: .native)
                #if DEBUG
                logger.info("iOS play: engine=native, method=\(info.playMethod.rawValue), url=\(redactedURL(info.url))")
                #endif
            }

            let p = NativeVideoPresenter(
                itemId: itemId, title: title, startTime: resolvedStartTime,
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
            errorMessage = loc.userFacingMessage(for: error)
        }
    }

    private func presentVLC(localURL: URL, startTime: Double?) {
        let p = VLCStreamPresenter(
            localURL: localURL,
            title: title,
            startTime: startTime,
            loc: loc,
            // Persist the offline playhead + queue the server sync on tick /
            // teardown. Captures `downloads` (a @MainActor store) and the item
            // id; the sink itself is @MainActor.
            onProgress: { positionMs, durationMs, final in
                downloads.recordOfflinePlaybackProgress(
                    itemId: itemId, positionMs: positionMs,
                    durationMs: durationMs, final: final
                )
            },
            onDismiss: { dismiss() }
        )
        vlcOfflinePresenter = p
        didPresent = true
        p.presentOffline()
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

    #if os(tvOS)
    /// Mirror of `iOSErrorView` for the tvOS fallback path. Same shape, larger
    /// type for couch-distance reading. No retry — tvOS playback is owned by
    /// `VideoPlayerCoordinator`, so the only sensible action here is to back
    /// out via the Menu button.
    private func tvOSErrorView(error: String) -> some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: CinemaScale.pt(64)))
                .foregroundStyle(CinemaColor.error)
            Text(error)
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
                .padding(.horizontal, 48)
            Text(loc.localized("player.tvOS.dismissHint"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.outlineVariant)
        }
    }
    #endif
}
