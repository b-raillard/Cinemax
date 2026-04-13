import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playback")

// MARK: - HLS Manifest Loader

/// Intercepts HLS requests via a `cinemax-https://` custom scheme:
/// 1. Strips `#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS` from playlists (in-band CEA-608/708 CC)
/// 2. Keeps `TYPE=SUBTITLES` so Jellyfin's WebVTT renditions appear in AVKit's native menu
/// 3. Strips ASS/SSA override tags (`{\i1}`, `{\b}`, `{\an8}`, etc.) from WebVTT segments
///    — Jellyfin's ASS→WebVTT conversion leaves these raw tags in the text
/// 4. Rewrites relative segment URIs to absolute `https://` (except `.vtt` segments,
///    which stay relative so they route through this delegate for tag stripping)
///
/// Key implementation note: `AVAssetResourceLoadingContentInformationRequest.contentType`
/// requires a **UTI**, not a MIME type. Passing the raw MIME string causes AVFoundation
/// to reject the response. Use `"public.m3u-playlist"` for M3U8 content.
private final class HLSManifestLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    static let schemePrefix = "cinemax-"
    let delegateQueue = DispatchQueue(label: "com.cinemax.manifestloader", qos: .userInitiated)

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let customURL = loadingRequest.request.url,
              let realURL = Self.realURL(from: customURL) else { return false }

        URLSession.shared.dataTask(with: URLRequest(url: realURL)) { data, response, error in
            guard let data, error == nil else {
                loadingRequest.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }
            let mime = (response as? HTTPURLResponse)?.mimeType ?? ""
            let isPlaylist = mime.contains("mpegurl") || mime.contains("m3u") || realURL.pathExtension == "m3u8"

            let isVTT = realURL.pathExtension.lowercased() == "vtt"
                || mime.contains("text/vtt")

            var responseData = data
            if isPlaylist, let text = String(data: data, encoding: .utf8) {
                responseData = Self.filterManifest(text, baseURL: realURL.deletingLastPathComponent())
                    .data(using: .utf8) ?? data
            } else if isVTT, let text = String(data: data, encoding: .utf8) {
                responseData = Self.stripASSTags(text).data(using: .utf8) ?? data
            }

            if let info = loadingRequest.contentInformationRequest {
                // contentType MUST be a UTI, not a MIME type.
                // Setting raw MIME strings causes "resource unavailable" on iOS
                // and -12881 on tvOS. Use proper UTIs for known types;
                // skip contentType for segments to let AVFoundation infer it.
                if isPlaylist {
                    info.contentType = "public.m3u-playlist"
                } else if isVTT {
                    info.contentType = "org.w3.webvtt"
                }
                info.contentLength = Int64(responseData.count)
                info.isByteRangeAccessSupported = false
            }
            loadingRequest.dataRequest?.respond(with: responseData)
            loadingRequest.finishLoading()
        }.resume()

        return true
    }

    static func realURL(from url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme, scheme.hasPrefix(schemePrefix) else { return nil }
        c.scheme = String(scheme.dropFirst(schemePrefix.count))
        return c.url
    }

    static func filterManifest(_ manifest: String, baseURL: URL) -> String {
        manifest
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only strip CLOSED-CAPTIONS (in-band CEA-608/708 from H.264 NAL units).
                // Keep TYPE=SUBTITLES — Jellyfin's WebVTT renditions appear natively in AVKit's menu.
                if t.hasPrefix("#EXT-X-MEDIA:") && t.contains("TYPE=CLOSED-CAPTIONS") {
                    return nil
                }
                // Bare URI lines (not tags, not empty)
                if !t.isEmpty, !t.hasPrefix("#") {
                    let isVTT = t.contains(".vtt")
                    if isVTT {
                        // Route VTT URLs through the delegate for ASS tag stripping.
                        // Absolute URLs need scheme rewrite; relative URLs stay as-is
                        // (they resolve against the custom-scheme base automatically).
                        if t.hasPrefix("https://") {
                            return schemePrefix + t
                        } else if t.hasPrefix("http://") {
                            return schemePrefix + t
                        }
                        return line
                    }
                    // Non-VTT relative URIs → make absolute so they bypass the delegate
                    if !t.hasPrefix("http://"), !t.hasPrefix("https://") {
                        return URL(string: t, relativeTo: baseURL)?.absoluteString ?? line
                    }
                }
                return line
            }
            .joined(separator: "\n")
    }

    /// Strips ASS/SSA artifacts from WebVTT text.
    /// Jellyfin's ASS→WebVTT conversion leaves:
    ///  - Override tags: `{\i1}`, `{\b0}`, `{\an8}`, `{\q2}`, `{\pos(x,y)}`
    ///  - Inline comments: `{TLC note: ...}`, `{I can't believe...}`
    /// This regex removes ALL `{...}` sequences from cue text lines,
    /// but preserves WebVTT structure lines (timestamps, WEBVTT header, NOTE blocks).
    static func stripASSTags(_ vtt: String) -> String {
        vtt.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
    }
}

// MARK: - Native Full-Screen Player Presenter

/// Presents AVPlayerViewController as a full-screen modal from UIKit,
/// so all HUD elements (title, transport controls, done button) are native
/// and show/hide together as one integrated layer.
/// Used on both iOS and tvOS.
@MainActor
final class NativeVideoPresenter {
    private var playerVC: AVPlayerViewController?
    private var playerObservation: NSKeyValueObservation?
    private var itemEndObserver: NSObjectProtocol?
    private var progressReportTask: Task<Void, Never>?
    private var playbackInfo: PlaybackInfo?

    private let itemId: String
    private let title: String
    private let startTime: Double?
    private var previousEpisode: EpisodeRef?
    private var nextEpisode: EpisodeRef?
    private let episodeNavigator: EpisodeNavigator?
    private let apiClient: any APIClientProtocol
    private let userId: String
    private let maxBitrate: Int
    private let loc: LocalizationManager
    private let autoPlayNextEpisode: Bool
    private let onDismiss: () -> Void

    // Retained for the lifetime of the asset — AVAssetResourceLoader holds only a weak ref.
    private var manifestLoader = HLSManifestLoader()

    // Track state
    private var audioTracks: [MediaTrackInfo] = []
    private var subtitleTracks: [MediaTrackInfo] = []
    private var currentAudioIndex: Int? = nil
    private var currentSubtitleIndex: Int? = nil
    private var currentPlayMethod: PlayMethod = .transcode

    #if os(tvOS)
    /// Retained delegate — AVPlayerViewControllerDelegate is used on tvOS to detect
    /// modal dismissal (Menu button). On iOS we use the PlayerHostingVC wrapper instead.
    private var dismissDelegate: TVDismissDelegate?
    #endif

    init(
        itemId: String, title: String, startTime: Double?,
        previousEpisode: EpisodeRef?, nextEpisode: EpisodeRef?,
        episodeNavigator: EpisodeNavigator?,
        apiClient: any APIClientProtocol, userId: String,
        maxBitrate: Int, loc: LocalizationManager,
        autoPlayNextEpisode: Bool,
        onDismiss: @escaping () -> Void
    ) {
        self.itemId = itemId
        self.title = title
        self.startTime = startTime
        self.previousEpisode = previousEpisode
        self.nextEpisode = nextEpisode
        self.episodeNavigator = episodeNavigator
        self.apiClient = apiClient
        self.userId = userId
        self.maxBitrate = maxBitrate
        self.loc = loc
        self.autoPlayNextEpisode = autoPlayNextEpisode
        self.onDismiss = onDismiss
    }

    func present(info: PlaybackInfo) {
        self.playbackInfo = info

        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first?.rootViewController else {
            logger.error("NativeVideoPresenter: no root view controller")
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController { topVC = presented }

        // Store track state
        self.audioTracks = info.audioTracks
        self.subtitleTracks = info.subtitleTracks
        self.currentAudioIndex = info.selectedAudioIndex
        self.currentSubtitleIndex = info.selectedSubtitleIndex
        self.currentPlayMethod = info.playMethod

        // Start with nil item — native player chrome appears immediately while
        // we fetch and filter the HLS manifest in the background.
        let avPlayer = AVPlayer(playerItem: nil)
        avPlayer.automaticallyWaitsToMinimizeStalling = true

        let vc = AVPlayerViewController()
        vc.player = avPlayer
        vc.showsPlaybackControls = true
        #if os(iOS)
        // Suppress native text recognition ("Show Text") — iOS only API.
        vc.allowsVideoFrameAnalysis = false
        #endif
        self.playerVC = vc
        setupRemoteCommands()
        setupTrackMenus()

        #if os(tvOS)
        // tvOS: present AVPlayerViewController directly — embedding as a child VC causes
        // internal constraint conflicts and playback errors on tvOS.
        // Use AVPlayerViewControllerDelegate to detect dismissal (Menu button).
        let delegate = TVDismissDelegate()
        delegate.onDismiss = { [weak self] in
            self?.reportPlaybackStop()
            self?.cleanup()
            self?.onDismiss()
        }
        self.dismissDelegate = delegate
        vc.delegate = delegate
        vc.modalPresentationStyle = .fullScreen
        topVC.present(vc, animated: true)
        #else
        // iOS: wrap in PlayerHostingVC for dismiss detection via viewWillDisappear.
        let hostingVC = PlayerHostingVC(playerVC: vc)
        hostingVC.modalPresentationStyle = .fullScreen
        hostingVC.onDismissed = { [weak self] in
            self?.reportPlaybackStop()
            self?.cleanup()
            self?.onDismiss()
        }
        topVC.present(hostingVC, animated: true)
        #endif

        // Create the player item and hand it to the player.
        // For transcode streams, makePlayerItem uses HLSManifestLoader (AVAssetResourceLoader)
        // to intercept the manifest and strip subtitle/CC renditions before AVKit parses it.
        let st = startTime
        Task { [weak self] in
            guard let self else { return }
            let playerItem = self.makePlayerItem(for: info)
            applyTitleMetadata(to: playerItem, title: self.title)

            playerObservation = playerItem.observe(\.status) { [weak avPlayer] item, _ in
                Task { @MainActor in
                    switch item.status {
                    case .readyToPlay:
                        if let st, st > 0 {
                            avPlayer?.seek(to: CMTime(seconds: st, preferredTimescale: 600),
                                          toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    case .failed:
                        logger.error("AVPlayer failed: \(item.error?.localizedDescription ?? "unknown")")
                    default: break
                    }
                }
            }

            avPlayer.replaceCurrentItem(with: playerItem)
            avPlayer.play()
            reportPlaybackStart()
            startProgressReporting()
            observeItemEnd(playerItem, player: avPlayer)
        }
    }

    // MARK: - Remote Command Center (prev/next in native HUD)

    private var prevCommandTarget: Any?
    private var nextCommandTarget: Any?

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        if let prev = previousEpisode, episodeNavigator != nil {
            center.previousTrackCommand.isEnabled = true
            prevCommandTarget = center.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.navigateToEpisode(prev) }
                return .success
            }
        } else {
            center.previousTrackCommand.isEnabled = false
        }

        if let next = nextEpisode, episodeNavigator != nil {
            center.nextTrackCommand.isEnabled = true
            nextCommandTarget = center.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.navigateToEpisode(next) }
                return .success
            }
        } else {
            center.nextTrackCommand.isEnabled = false
        }
    }

    private func teardownRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        if let target = prevCommandTarget {
            center.previousTrackCommand.removeTarget(target)
            prevCommandTarget = nil
        }
        if let target = nextCommandTarget {
            center.nextTrackCommand.removeTarget(target)
            nextCommandTarget = nil
        }
        center.previousTrackCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
    }

    // MARK: - Track Menus (native transport bar)

    /// Injects audio options into the native transport bar.
    ///
    /// On tvOS, `transportBarCustomMenuItems` is a first-class public API.
    /// On iOS, it's marked `API_UNAVAILABLE(ios)` in the Swift SDK but exists
    /// at runtime on iOS 16+ — reached via the Objective-C runtime.
    private func setupTrackMenus() {
        guard let vc = playerVC else { return }
        var items: [UIMenuElement] = []

        if audioTracks.count > 1 {
            let current = currentAudioIndex
            items.append(UIMenu(
                title: loc.localized("player.audio"),
                image: UIImage(systemName: "speaker.wave.2"),
                children: audioTracks.map { track in
                    UIAction(title: track.label, state: track.id == current ? .on : .off) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            await self?.switchTracks(audioIndex: track.id, subtitleIndex: self?.currentSubtitleIndex)
                        }
                    }
                }
            ))
        }

        // Subtitles are handled natively by AVKit via WebVTT HLS renditions in the manifest.
        // No custom subtitle menu injection needed — AVKit shows ONE unified Subtitles entry.
        // On iOS, HLSManifestLoader strips ASS/SSA tags from the WebVTT segments.
        // On tvOS, AVAssetResourceLoaderDelegate doesn't work so ASS tags may appear.

        applyTransportBarItems(items, to: vc)
    }

    private func applyTransportBarItems(_ items: [UIMenuElement], to vc: AVPlayerViewController) {
        #if os(tvOS)
        vc.transportBarCustomMenuItems = items
        #else
        let sel = NSSelectorFromString("setTransportBarCustomMenuItems:")
        guard vc.responds(to: sel) else { return }
        vc.setValue(items, forKey: "transportBarCustomMenuItems")
        #endif
    }

    private func switchTracks(audioIndex: Int?, subtitleIndex: Int?) async {
        guard let vc = playerVC, let player = vc.player else { return }
        let currentTime = player.currentTime().seconds

        guard let info = try? await apiClient.getPlaybackInfo(
            itemId: itemId, userId: userId, maxBitrate: maxBitrate,
            audioStreamIndex: audioIndex, subtitleStreamIndex: subtitleIndex
        ) else {
            logger.error("NativeVideoPresenter: track switch failed for audio=\(String(describing: audioIndex)) sub=\(String(describing: subtitleIndex))")
            return
        }

        self.playbackInfo = info
        self.currentAudioIndex = audioIndex ?? info.selectedAudioIndex
        self.currentSubtitleIndex = subtitleIndex ?? info.selectedSubtitleIndex
        self.audioTracks = info.audioTracks
        self.subtitleTracks = info.subtitleTracks
        self.currentPlayMethod = info.playMethod

        let playerItem = makePlayerItem(for: info)
        applyTitleMetadata(to: playerItem, title: self.title)

        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndObserver = nil
        }
        playerObservation?.invalidate()
        playerObservation = playerItem.observe(\.status) { item, _ in
            Task { @MainActor in
                guard item.status == .readyToPlay, currentTime > 0 else { return }
                player.seek(
                    to: CMTime(seconds: currentTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
                player.play()
            }
        }

        player.replaceCurrentItem(with: playerItem)
        startProgressReporting()
        observeItemEnd(playerItem, player: player)
        setupTrackMenus()
    }

    // MARK: - Episode Navigation

    private func navigateToEpisode(_ ep: EpisodeRef) {
        guard let navigator = episodeNavigator, let vc = playerVC else { return }
        Task {
            reportPlaybackStop()
            guard let (info, prev, next) = await navigator(ep.id) else { return }
            cleanupPlayer()
            self.playbackInfo = info
            self.previousEpisode = prev
            self.nextEpisode = next
            self.audioTracks = info.audioTracks
            self.subtitleTracks = info.subtitleTracks
            self.currentAudioIndex = info.selectedAudioIndex
            self.currentSubtitleIndex = info.selectedSubtitleIndex
            self.currentPlayMethod = info.playMethod

            let playerItem = makePlayerItem(for: info)
            applyTitleMetadata(to: playerItem, title: ep.title)

            let avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer.automaticallyWaitsToMinimizeStalling = true
            vc.player = avPlayer
            teardownRemoteCommands()
            setupRemoteCommands()
            setupTrackMenus()              // refreshes native "..." menu for new episode

            playerObservation = playerItem.observe(\.status) { item, _ in
                Task { @MainActor in
                    if item.status == .failed {
                        logger.error("AVPlayer failed on episode nav: \(item.error?.localizedDescription ?? "unknown")")
                    }
                }
            }

            avPlayer.play()
            reportPlaybackStart()
            startProgressReporting()
            observeItemEnd(playerItem, player: avPlayer)
        }
    }

    // MARK: - Metadata

    private func applyTitleMetadata(to item: AVPlayerItem, title: String) {
        let meta = AVMutableMetadataItem()
        meta.identifier = .commonIdentifierTitle
        meta.value = title as NSString
        item.externalMetadata = [meta]
    }

    // MARK: - Playback Reporting

    private func reportPlaybackStart() {
        guard let info = playbackInfo else { return }
        let positionTicks = startTime.map { Int($0 * 10_000_000) } ?? 0
        let id = itemId
        let client = apiClient
        let uid = userId
        Task.detached {
            await client.reportPlaybackStart(
                itemId: id, userId: uid,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, playMethod: info.playMethod
            )
        }
    }

    private func reportPlaybackStop() {
        guard let info = playbackInfo else { return }
        let positionTicks = Int((playerVC?.player?.currentTime().seconds ?? 0) * 10_000_000)
        let id = itemId
        let client = apiClient
        let uid = userId
        Task.detached {
            await client.reportPlaybackStopped(
                itemId: id, userId: uid,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks
            )
        }
    }

    private func startProgressReporting() {
        progressReportTask?.cancel()
        guard let info = playbackInfo else { return }
        let id = itemId
        let client = apiClient
        let uid = userId
        let player = playerVC?.player
        progressReportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                let ticks = Int((player?.currentTime().seconds ?? 0) * 10_000_000)
                let isPaused = player?.rate == 0
                await client.reportPlaybackProgress(
                    itemId: id, userId: uid,
                    mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                    positionTicks: ticks, isPaused: isPaused, playMethod: info.playMethod
                )
            }
        }
    }

    private func observeItemEnd(_ item: AVPlayerItem, player: AVPlayer) {
        if let obs = itemEndObserver { NotificationCenter.default.removeObserver(obs) }
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let autoPlay = UserDefaults.standard.object(forKey: "autoPlayNextEpisode") as? Bool ?? true
                if autoPlay, let next = self.nextEpisode, self.episodeNavigator != nil {
                    self.navigateToEpisode(next)
                }
            }
        }
    }

    // MARK: - Helpers

    private func makePlayerItem(for info: PlaybackInfo) -> AVPlayerItem {
        let item: AVPlayerItem

        #if os(iOS)
        // Route transcoded HLS through HLSManifestLoader to strip CLOSED-CAPTIONS
        // entries and ASS/SSA override tags from WebVTT subtitle segments.
        // On tvOS, AVAssetResourceLoaderDelegate with custom schemes causes -12881 errors
        // when used with AVPlayerViewController — subtitles play with raw ASS tags as a
        // known limitation (Jellyfin's imperfect ASS→WebVTT conversion).
        if info.playMethod == .transcode,
           var components = URLComponents(url: info.url, resolvingAgainstBaseURL: false),
           let originalScheme = components.scheme {
            components.scheme = HLSManifestLoader.schemePrefix + originalScheme
            if let customURL = components.url {
                let asset = AVURLAsset(url: customURL)
                asset.resourceLoader.setDelegate(manifestLoader, queue: manifestLoader.delegateQueue)
                item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 5
                return item
            }
        }
        #endif

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

    private func cleanupPlayer() {
        progressReportTask?.cancel()
        progressReportTask = nil
        playerObservation?.invalidate()
        playerObservation = nil
        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndObserver = nil
        }
        playerVC?.player?.pause()
        playerVC?.player?.replaceCurrentItem(with: nil)
    }

    private func cleanup() {
        teardownRemoteCommands()
        if let vc = playerVC { applyTransportBarItems([], to: vc) }
        #if os(tvOS)
        dismissDelegate = nil
        #endif
        cleanupPlayer()
        playerVC = nil
    }

    // MARK: - Platform-specific dismiss detection

    #if os(tvOS)
    /// Uses AVPlayerViewControllerDelegate (tvOS-only APIs) to detect when the user
    /// presses Menu to dismiss the player.
    private class TVDismissDelegate: NSObject, AVPlayerViewControllerDelegate, @unchecked Sendable {
        var onDismiss: (@MainActor () -> Void)?

        func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
            let cb = onDismiss
            Task { @MainActor in cb?() }
        }
    }
    #else
    /// Wraps AVPlayerViewController on iOS so we can detect modal dismissal
    /// via viewWillDisappear(isBeingDismissed:), which fires when the user taps Done/X.
    private class PlayerHostingVC: UIViewController, @unchecked Sendable {
        var onDismissed: (@MainActor () -> Void)?
        private let playerVC: AVPlayerViewController

        init(playerVC: AVPlayerViewController) {
            self.playerVC = playerVC
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(playerVC)
            playerVC.view.frame = view.bounds
            playerVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(playerVC.view)
            playerVC.didMove(toParent: self)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if isBeingDismissed {
                let cb = onDismissed
                Task { @MainActor in cb?() }
            }
        }
    }
    #endif
}

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
            logger.info("iOS play: method=\(info.playMethod.rawValue), url=\(info.url.absoluteString)")

            let p = NativeVideoPresenter(
                itemId: itemId, title: title, startTime: startTime,
                previousEpisode: previousEpisode, nextEpisode: nextEpisode,
                episodeNavigator: episodeNavigator,
                apiClient: appState.apiClient, userId: userId,
                maxBitrate: bitrate, loc: loc,
                autoPlayNextEpisode: autoPlayNextEpisode,
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
