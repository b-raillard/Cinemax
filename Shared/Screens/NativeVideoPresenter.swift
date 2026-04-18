import UIKit
import AVKit
import AVFoundation
import MediaPlayer
import OSLog
import CinemaxKit
import JellyfinAPI

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
    private var hasRetriedDirectURL = false
    private var playbackInfo: PlaybackInfo?

    // `itemId` / `startTime` are mutable so episode navigation can rebind them;
    // PlaybackReporter.Context reads `self.itemId` each tick, and reportStart
    // uses `self.startTime` to position the new episode.
    private var itemId: String
    private let title: String
    private var startTime: Double?
    private var previousEpisode: EpisodeRef?
    private var nextEpisode: EpisodeRef?
    private let episodeNavigator: EpisodeNavigator?
    private let apiClient: any APIClientProtocol
    private let userId: String
    private let maxBitrate: Int
    private let loc: LocalizationManager
    private let autoPlayNextEpisode: Bool
    private let imageBuilder: ImageURLBuilder
    private let onDismiss: () -> Void

    // Retained for the lifetime of the asset — AVAssetResourceLoader holds only a weak ref.
    private var manifestLoader = HLSManifestLoader()
    private var backgroundObserver: NSObjectProtocol?

    // Sub-controllers (see Shared/Screens/VideoPlayer/)
    private var playbackReporter: PlaybackReporter!
    private var skipSegments: SkipSegmentController!
    private var sleepTimer: SleepTimerController!

    // Track state
    private var audioTracks: [MediaTrackInfo] = []
    private var subtitleTracks: [MediaTrackInfo] = []
    private var currentAudioIndex: Int? = nil
    private var currentSubtitleIndex: Int? = nil
    private var currentPlayMethod: CinemaxKit.PlayMethod = .transcode

    // Shared periodic time observer. Fans out to SkipSegmentController.onTick
    // and PlaybackReporter.onTick from startProgressReporting.
    private var timeObserver: Any?

    // End-of-series
    private var currentSeriesName: String?
    private var finishedSeriesOverlay: UIView?

    // Debug: jump to last 15 seconds button
    private var skipToEndButton: UIButton?

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
        imageBuilder: ImageURLBuilder,
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
        self.imageBuilder = imageBuilder
        self.onDismiss = onDismiss

        self.playbackReporter = PlaybackReporter(
            apiClient: apiClient, userId: userId,
            context: { [weak self] in
                guard let self, let info = self.playbackInfo else { return nil }
                return .init(itemId: self.itemId, info: info, player: self.playerVC?.player)
            }
        )
        self.skipSegments = SkipSegmentController(
            apiClient: apiClient, loc: loc,
            playerVCProvider: { [weak self] in self?.playerVC }
        )
        self.sleepTimer = SleepTimerController(
            loc: loc,
            playerVCProvider: { [weak self] in self?.playerVC },
            onStopPlayback: { [weak self] in self?.playerVC?.dismiss(animated: true) }
        )
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

        // AVAudioSession must be `.playback` before we hand a player item to AVKit,
        // otherwise AirPlay routing drops audio when the iPhone silent switch is on
        // or the screen locks during a cast.
        activatePlaybackAudioSession()

        // Start with nil item — native player chrome appears immediately while
        // we fetch and filter the HLS manifest in the background.
        let avPlayer = AVPlayer(playerItem: nil)
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        avPlayer.allowsExternalPlayback = true
        avPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true

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
            self?.playbackReporter.reportStop()
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
            self?.playbackReporter.reportStop()
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
                        #else
                        self?.showPlaybackErrorAlert(error: item.error)
                        #endif
                    default: break
                    }
                }
            }

            avPlayer.replaceCurrentItem(with: playerItem)
            avPlayer.play()
            self.playbackReporter.reportStart(startTime: self.startTime)
            startProgressReporting()
            observeItemEnd(playerItem, player: avPlayer)
            self.skipSegments.load(for: self.itemId)
            fetchAndApplyChapters(for: self.itemId, playerItem: playerItem)
            self.sleepTimer.startIfNeeded()
            showSkipToEndButtonIfDebugEnabled()
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
        playerObservation = playerItem.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    if let st = startTime, st > 0 {
                        player.seek(to: CMTime(seconds: st, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                case .failed:
                    logger.error("AVPlayer failed on direct URL fallback: \(item.error?.localizedDescription ?? "unknown")")
                    // Both HLS with manifest loader and direct URL failed — nothing else to try.
                    self?.showPlaybackErrorAlert(error: item.error)
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

        // Debug: jump to the last 15 seconds. Lives in the transport bar custom menu
        // (rather than as a free-floating UIView overlay) so the tvOS focus engine
        // can actually reach it via the Siri Remote.
        if UserDefaults.standard.bool(forKey: "debug.showSkipToEnd") {
            items.append(UIAction(
                title: "⏭ Skip to End (Debug)",
                image: UIImage(systemName: "forward.end.alt.fill")
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.seekToLast15Seconds()
                }
            })
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
            playbackReporter.reportStop()
            guard let (info, prev, next) = await navigator(ep.id) else { return }
            cleanupPlayer()
            self.hasRetriedDirectURL = false
            self.playbackInfo = info
            // Rebind identity so PlaybackReporter (via its context closure) and
            // reportStart below operate on the new episode, not the initial one.
            // New episodes always start at 0 — the resume `startTime` only applies
            // to the first item presented.
            self.itemId = ep.id
            self.startTime = nil
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
            playbackReporter.reportStart(startTime: self.startTime)
            startProgressReporting()
            observeItemEnd(playerItem, player: avPlayer)
            skipSegments.load(for: ep.id)
            fetchAndApplyChapters(for: ep.id, playerItem: playerItem)
            // Episode navigation restarts the sleep timer (keeps playback "session" alive).
            sleepTimer.startIfNeeded()
            showSkipToEndButtonIfDebugEnabled()
        }
    }

    // MARK: - Metadata

    private func applyTitleMetadata(to item: AVPlayerItem, title: String) {
        let meta = AVMutableMetadataItem()
        meta.identifier = .commonIdentifierTitle
        meta.value = title as NSString
        item.externalMetadata = [meta]
    }

    // MARK: - Shared Time Observer
    //
    // Single periodic observer (1 s) that fans out to segment skip detection and
    // playback progress reporting. The reporter applies a 10-tick throttle.

    private func startProgressReporting() {
        removeTimeObserver()
        playbackReporter.resetTicking()
        guard let player = playerVC?.player else { return }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.skipSegments.onTick(currentTime: time.seconds)
                self.playbackReporter.onTick()
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
                } else if autoPlay, self.episodeNavigator != nil, self.nextEpisode == nil,
                          let seriesName = self.currentSeriesName {
                    // We just finished the last episode of a series while auto-play is on.
                    self.showFinishedSeriesOverlay(seriesName: seriesName)
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver, let player = playerVC?.player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
    }

    // Shared button styling for the debug Skip-to-End pill and the sleep
    // indicator. Skip-intro/credits styling is owned by `SkipSegmentController`.
    private var buttonFontSize: CGFloat {
        #if os(tvOS)
        28
        #else
        16
        #endif
    }

    private var buttonCornerRadius: CGFloat {
        #if os(tvOS)
        14
        #else
        10
        #endif
    }

    private var buttonPaddingH: CGFloat {
        #if os(tvOS)
        32
        #else
        20
        #endif
    }

    // Shared overlay styling (used by the iOS finishedSeriesOverlay).

    private var overlayCardWidth: CGFloat {
        #if os(tvOS)
        640
        #else
        340
        #endif
    }

    private var overlayIconSize: CGFloat {
        #if os(tvOS)
        72
        #else
        48
        #endif
    }

    private var overlayTitleSize: CGFloat {
        #if os(tvOS)
        36
        #else
        22
        #endif
    }

    private var overlaySubtitleSize: CGFloat {
        #if os(tvOS)
        22
        #else
        15
        #endif
    }

    private var overlayButtonSize: CGFloat {
        #if os(tvOS)
        24
        #else
        16
        #endif
    }

    // MARK: - Chapters

    /// Fetches the full item (which carries the chapter list) and builds an
    /// `AVNavigationMarkersGroup` exposed to AVPlayerViewController's scrubber.
    /// Chapter images are downloaded in parallel and embedded as artwork metadata.
    private func fetchAndApplyChapters(for id: String, playerItem: AVPlayerItem) {
        let client = apiClient
        let uid = userId
        let builder = imageBuilder
        let token = playbackInfo?.authToken
        Task { [weak self, weak playerItem] in
            guard let fullItem = try? await client.getItem(userId: uid, itemId: id) else { return }

            // Capture the series name while we have the full item — used by the
            // end-of-series completion overlay when this was the last episode.
            await MainActor.run { [weak self] in
                self?.currentSeriesName = fullItem.seriesName
            }

            guard let chapters = fullItem.chapters, chapters.count > 1 else { return }

            // Chapter markers are tvOS-only (AVNavigationMarkersGroup lives in AVKit
            // on tvOS only). Skip image download and marker build on iOS.
            #if os(tvOS)
            // Fetch chapter thumbnails in parallel. Missing images are fine — chapter
            // markers still render with just a title.
            let images: [Int: Data] = await withTaskGroup(of: (Int, Data?).self) { group in
                for (index, _) in chapters.enumerated() {
                    let url = builder.chapterImageURL(itemId: id, imageIndex: index, maxWidth: 480)
                    group.addTask {
                        await Self.loadChapterImage(url: url, token: token).map { (index, $0) } ?? (index, nil)
                    }
                }
                var results: [Int: Data] = [:]
                for await (idx, data) in group {
                    if let data { results[idx] = data }
                }
                return results
            }

            await MainActor.run {
                guard let self, let playerItem else { return }
                self.applyChapterMarkers(chapters: chapters, images: images, to: playerItem)
            }
            #else
            _ = builder
            _ = token
            _ = playerItem
            _ = self
            #endif
        }
    }

    /// Downloads one chapter thumbnail, attaching the Jellyfin access token so the server
    /// authorises the request. Returns `nil` on HTTP error or non-image content.
    nonisolated private static func loadChapterImage(url: URL, token: String?) async -> Data? {
        var request = URLRequest(url: url)
        if let token {
            request.addValue("MediaBrowser Token=\(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return data
    }

    /// Builds `AVTimedMetadataGroup` markers for the scrubber and assigns them via
    /// `AVPlayerItem.navigationMarkerGroups`. Group title becomes the section label
    /// in AVKit's Chapters menu.
    ///
    /// **tvOS-only**: `AVNavigationMarkersGroup` lives in `AVKit` and only ships on tvOS.
    /// On iOS, `AVPlayerViewController` has no built-in chapters scrubber, so we skip.
    private func applyChapterMarkers(chapters: [ChapterInfo], images: [Int: Data], to playerItem: AVPlayerItem) {
        #if os(tvOS)
        var markers: [AVTimedMetadataGroup] = []
        markers.reserveCapacity(chapters.count)

        for (index, chapter) in chapters.enumerated() {
            let startSeconds = Double(chapter.startPositionTicks ?? 0) / 10_000_000
            let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
            let range = CMTimeRange(start: startTime, duration: .zero)

            var items: [AVMetadataItem] = []

            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = (chapter.name ?? "Chapter \(index + 1)") as NSString
            titleItem.extendedLanguageTag = "und"
            items.append(titleItem)

            if let data = images[index] {
                let artwork = AVMutableMetadataItem()
                artwork.identifier = .commonIdentifierArtwork
                artwork.value = data as NSData
                artwork.dataType = kCMMetadataBaseDataType_JPEG as String
                artwork.extendedLanguageTag = "und"
                items.append(artwork)
            }

            markers.append(AVTimedMetadataGroup(items: items, timeRange: range))
        }

        let group = AVNavigationMarkersGroup(title: "Chapters", timedNavigationMarkers: markers)
        playerItem.navigationMarkerGroups = [group]
        #endif
    }

    // MARK: - Error Recovery

    /// Presents a native UIAlertController with a specific, actionable message when all
    /// playback attempts have failed. Translates common AVFoundation error codes
    /// (-12881 transcode, -12938 network) into human-readable guidance.
    private var isShowingErrorAlert = false

    private func showPlaybackErrorAlert(error: Error?) {
        guard !isShowingErrorAlert, let vc = playerVC else { return }
        isShowingErrorAlert = true

        let message = errorMessage(for: error)

        let alert = UIAlertController(
            title: loc.localized("playback.error.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: loc.localized("playback.error.close"),
            style: .default,
            handler: { [weak self] _ in
                self?.isShowingErrorAlert = false
                self?.playerVC?.dismiss(animated: true)
            }
        ))
        vc.present(alert, animated: true)
    }

    private func errorMessage(for error: Error?) -> String {
        guard let nsError = error as NSError? else {
            return loc.localized("playback.error.generic")
        }
        switch nsError.code {
        case -12881, -12886, -16170:
            return loc.localized("playback.error.transcode")
        case -12938, -1009, -1001, -1004, -1005:
            return loc.localized("playback.error.network")
        default:
            return loc.localized("playback.error.generic")
        }
    }

    // MARK: - Debug: Skip to End

    /// iOS draws a small floating overlay button (top-right) that the user taps directly.
    /// On tvOS the same overlay isn't focusable through the AVPlayerViewController focus
    /// engine — so the action is injected into `transportBarCustomMenuItems` instead
    /// (see `setupTrackMenus`).
    private func showSkipToEndButtonIfDebugEnabled() {
        #if os(tvOS)
        // tvOS path is handled by the transport-bar custom menu; nothing to draw here.
        return
        #else
        let enabled = UserDefaults.standard.bool(forKey: "debug.showSkipToEnd")
        guard enabled else {
            hideSkipToEndButton()
            return
        }
        guard skipToEndButton == nil, let vc = playerVC else { return }

        var config = UIButton.Configuration.plain()
        var attrTitle = AttributedString("  ⏭ End  ")
        attrTitle.font = .systemFont(ofSize: buttonFontSize, weight: .semibold)
        attrTitle.foregroundColor = UIColor.white
        config.attributedTitle = attrTitle
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: buttonPaddingH, bottom: 0, trailing: buttonPaddingH)
        config.background.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.55)
        config.background.cornerRadius = buttonCornerRadius

        let button = UIButton(
            configuration: config,
            primaryAction: UIAction { [weak self] _ in self?.seekToLast15Seconds() }
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alpha = 0.85

        let targetView = vc.view!
        targetView.addSubview(button)

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: targetView.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            button.topAnchor.constraint(equalTo: targetView.safeAreaLayoutGuide.topAnchor, constant: 12),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])

        skipToEndButton = button
        #endif
    }

    private func hideSkipToEndButton() {
        skipToEndButton?.removeFromSuperview()
        skipToEndButton = nil
    }

    private func seekToLast15Seconds() {
        guard let player = playerVC?.player,
              let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 15 else { return }
        let target = CMTime(seconds: duration - 15, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - End-of-Series Overlay

    /// Shown when the last episode of a series finishes with autoplay on. Gives the user
    /// a concrete "you're done" moment rather than the player just sitting at the end.
    private func showFinishedSeriesOverlay(seriesName: String) {
        #if os(tvOS)
        // Same focus-engine reasoning as `showSleepOverlay` — UIAlertController
        // owns its own focus context so the Done button is reachable with the remote.
        guard finishedSeriesOverlay == nil, let vc = playerVC else { return }

        let alert = UIAlertController(
            title: String(format: loc.localized("player.finishedSeries.title"), seriesName),
            message: loc.localized("player.finishedSeries.subtitle"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: loc.localized("player.finishedSeries.done"),
            style: .default,
            handler: { [weak self] _ in
                self?.finishedSeriesOverlay = nil
                self?.playerVC?.dismiss(animated: true)
            }
        ))

        finishedSeriesOverlay = alert.view
        vc.present(alert, animated: true)
        return
        #else
        guard finishedSeriesOverlay == nil, let vc = playerVC else { return }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        container.alpha = 0

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 20
        card.clipsToBounds = true

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        card.addSubview(blur)

        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = .systemGreen
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: overlayTitleSize, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = String(format: loc.localized("player.finishedSeries.title"), seriesName)

        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: overlaySubtitleSize, weight: .medium)
        subtitleLabel.textColor = .white.withAlphaComponent(0.8)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text = loc.localized("player.finishedSeries.subtitle")

        var doneConfig = UIButton.Configuration.plain()
        var doneTitle = AttributedString(loc.localized("player.finishedSeries.done"))
        doneTitle.font = .systemFont(ofSize: overlayButtonSize, weight: .semibold)
        doneTitle.foregroundColor = UIColor.black
        doneConfig.attributedTitle = doneTitle
        doneConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        doneConfig.background.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        doneConfig.background.cornerRadius = 12

        let doneButton = UIButton(
            configuration: doneConfig,
            primaryAction: UIAction { [weak self] _ in
                self?.hideFinishedSeriesOverlay()
                self?.playerVC?.dismiss(animated: true)
            }
        )
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(doneButton)
        container.addSubview(card)

        let targetView = vc.view!
        targetView.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: targetView.topAnchor),
            container.bottomAnchor.constraint(equalTo: targetView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: targetView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: targetView.trailingAnchor),

            card.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: overlayCardWidth),

            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 36),
            icon.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: overlayIconSize),
            icon.heightAnchor.constraint(equalToConstant: overlayIconSize),

            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            doneButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
            doneButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            doneButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])

        self.finishedSeriesOverlay = container

        UIView.animate(withDuration: 0.3) { container.alpha = 1 }
        #endif
    }

    private func hideFinishedSeriesOverlay() {
        guard let container = finishedSeriesOverlay else { return }
        #if os(tvOS)
        if let presented = playerVC?.presentedViewController {
            presented.dismiss(animated: true)
        }
        finishedSeriesOverlay = nil
        return
        #else
        UIView.animate(withDuration: 0.25, animations: { container.alpha = 0 }) { _ in
            container.removeFromSuperview()
        }
        finishedSeriesOverlay = nil
        #endif
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

    // MARK: - Audio Session (AirPlay + screen-lock continuity)

    /// `.playback` + `.moviePlayback` is the Apple-recommended category for a video
    /// player: it keeps audio flowing over AirPlay when the ringer is silent or the
    /// device locks, and cooperates with other media apps' interruption handling.
    private func activatePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
        } catch {
            logger.error("Failed to activate playback audio session: \(error.localizedDescription)")
        }
    }

    private func deactivatePlaybackAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Failed to deactivate playback audio session: \(error.localizedDescription)")
        }
    }

    private func setupBackgroundObserver() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: .cinemaxDidEnterBackground, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.playbackReporter.reportBackgroundProgress()
            }
        }
    }

    private func cleanupPlayer() {
        removeTimeObserver()
        skipSegments.teardown()
        hideSkipToEndButton()
        sleepTimer.teardown()
        hideFinishedSeriesOverlay()
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
        deactivatePlaybackAudioSession()
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
