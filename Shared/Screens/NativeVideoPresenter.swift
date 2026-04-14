import UIKit
import AVKit
import AVFoundation
import MediaPlayer
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Playback")

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
    private var hasRetriedDirectURL = false
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
    private var backgroundObserver: NSObjectProtocol?

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
        setupBackgroundObserver()

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

            playerObservation = playerItem.observe(\.status) { [weak self, weak avPlayer] item, _ in
                Task { @MainActor in
                    switch item.status {
                    case .readyToPlay:
                        if let st, st > 0 {
                            avPlayer?.seek(to: CMTime(seconds: st, preferredTimescale: 600),
                                          toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    case .failed:
                        logger.error("AVPlayer failed: \(item.error?.localizedDescription ?? "unknown")")
                        #if os(iOS)
                        if let self, let avPlayer {
                            self.retryWithDirectURL(player: avPlayer, startTime: st)
                        }
                        #endif
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

    // MARK: - Direct URL Fallback (iOS)

    #if os(iOS)
    /// When `HLSManifestLoader` (custom-scheme `AVAssetResourceLoaderDelegate`) fails with
    /// errors like -12881, retry playback using the direct HLS URL without manifest interception.
    /// Subtitles may show raw ASS tags, but playback works.
    private func retryWithDirectURL(player: AVPlayer, startTime: Double?) {
        guard let info = playbackInfo, !hasRetriedDirectURL else { return }
        hasRetriedDirectURL = true
        logger.info("Retrying playback without HLSManifestLoader (direct URL fallback)")

        let playerItem: AVPlayerItem
        if let token = info.authToken {
            let asset = AVURLAsset(url: info.url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "MediaBrowser Token=\(token)"]
            ])
            playerItem = AVPlayerItem(asset: asset)
        } else {
            playerItem = AVPlayerItem(url: info.url)
        }
        playerItem.preferredForwardBufferDuration = 30
        applyTitleMetadata(to: playerItem, title: title)

        playerObservation?.invalidate()
        playerObservation = playerItem.observe(\.status) { item, _ in
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    if let st = startTime, st > 0 {
                        player.seek(to: CMTime(seconds: st, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                case .failed:
                    logger.error("AVPlayer failed on direct URL fallback: \(item.error?.localizedDescription ?? "unknown")")
                default: break
                }
            }
        }

        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndObserver = nil
        }
        player.replaceCurrentItem(with: playerItem)
        player.play()
        observeItemEnd(playerItem, player: player)
    }
    #endif

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

        // Episode navigation buttons — appear as tappable icons in the transport bar
        if previousEpisode != nil, episodeNavigator != nil {
            items.append(UIAction(
                title: loc.localized("accessibility.previousEpisode"),
                image: UIImage(systemName: "backward.end.fill")
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let prev = self.previousEpisode else { return }
                    self.navigateToEpisode(prev)
                }
            })
        }

        if nextEpisode != nil, episodeNavigator != nil {
            items.append(UIAction(
                title: loc.localized("accessibility.nextEpisode"),
                image: UIImage(systemName: "forward.end.fill")
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let next = self.nextEpisode else { return }
                    self.navigateToEpisode(next)
                }
            })
        }

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
        // On iOS, HLSManifestLoader strips ASS/SSA tags from the WebVTT subtitle segments.
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
            self.hasRetriedDirectURL = false
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
                item.preferredForwardBufferDuration = 30
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
        item.preferredForwardBufferDuration = 30
        return item
    }

    private func setupBackgroundObserver() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: .cinemaxDidEnterBackground, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reportPlaybackProgress()
            }
        }
    }

    private func reportPlaybackProgress() {
        guard let info = playbackInfo, let player = playerVC?.player else { return }
        let positionTicks = Int(player.currentTime().seconds * 10_000_000)
        let id = itemId
        let client = apiClient
        let uid = userId
        Task.detached {
            await client.reportPlaybackProgress(
                itemId: id, userId: uid,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, isPaused: true, playMethod: info.playMethod
            )
        }
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
        if let obs = backgroundObserver {
            NotificationCenter.default.removeObserver(obs)
            backgroundObserver = nil
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
