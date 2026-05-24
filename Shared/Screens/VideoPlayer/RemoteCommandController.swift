import MediaPlayer

/// Drives the system's prev/next track and play/pause buttons in the native
/// HUD (Lock Screen, Control Center, Siri Remote on tvOS). Mirrors the
/// sub-controller pattern already used by `PlaybackReporter` /
/// `SkipSegmentController` / `SleepTimerController`: presenter retains a
/// single instance per session, `attach` on play / episode-nav,
/// `detach` on cleanup.
///
/// Prev/next targets capture the destination `EpisodeRef` directly. Play/pause
/// fires a presenter-supplied closure that toggles the engine *and* reveals
/// the HUD — critical on tvOS, where pressing the Siri Remote play/pause
/// while the HUD is hidden has no focused responder, so the press is delivered
/// to `MPRemoteCommandCenter` instead of bubbling to `pressesBegan`.
@MainActor
final class RemoteCommandController {
    private let onNavigate: @MainActor (EpisodeRef) -> Void
    private let onTogglePlayPause: @MainActor () -> Void
    private var prevCommandTarget: Any?
    private var nextCommandTarget: Any?
    private var playPauseTarget: Any?
    private var playTarget: Any?
    private var pauseTarget: Any?

    init(onNavigate: @escaping @MainActor (EpisodeRef) -> Void,
         onTogglePlayPause: @escaping @MainActor () -> Void) {
        self.onNavigate = onNavigate
        self.onTogglePlayPause = onTogglePlayPause
    }

    /// Wires the system prev/next + play/pause commands. Pass `hasNavigator ==
    /// false` to suppress both episode buttons (e.g. movie playback where there
    /// is no episode graph). Play/pause is always wired — it's the dedicated
    /// Siri Remote button and must work regardless of HUD state.
    /// Re-callable: previously registered targets are replaced each time,
    /// matching how the presenter calls this on every episode nav.
    func attach(previous: EpisodeRef?, next: EpisodeRef?, hasNavigator: Bool) {
        detach()
        let center = MPRemoteCommandCenter.shared()

        if let prev = previous, hasNavigator {
            center.previousTrackCommand.isEnabled = true
            prevCommandTarget = center.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.onNavigate(prev) }
                return .success
            }
        } else {
            center.previousTrackCommand.isEnabled = false
        }

        if let next = next, hasNavigator {
            center.nextTrackCommand.isEnabled = true
            nextCommandTarget = center.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.onNavigate(next) }
                return .success
            }
        } else {
            center.nextTrackCommand.isEnabled = false
        }

        // tvOS dedicated play/pause button reaches us here when the HUD is
        // hidden (no focused responder). The presenter's closure both flips
        // the engine and reveals the HUD so the user gets visual feedback.
        center.togglePlayPauseCommand.isEnabled = true
        playPauseTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onTogglePlayPause() }
            return .success
        }
        // Some surfaces (CarPlay, headphones with discrete play/pause) only
        // wire the split commands — duplicate the binding so all three resolve.
        center.playCommand.isEnabled = true
        playTarget = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onTogglePlayPause() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onTogglePlayPause() }
            return .success
        }
    }

    /// Removes every registered target and disables the commands. Idempotent.
    func detach() {
        let center = MPRemoteCommandCenter.shared()
        if let target = prevCommandTarget {
            center.previousTrackCommand.removeTarget(target)
            prevCommandTarget = nil
        }
        if let target = nextCommandTarget {
            center.nextTrackCommand.removeTarget(target)
            nextCommandTarget = nil
        }
        if let target = playPauseTarget {
            center.togglePlayPauseCommand.removeTarget(target)
            playPauseTarget = nil
        }
        if let target = playTarget {
            center.playCommand.removeTarget(target)
            playTarget = nil
        }
        if let target = pauseTarget {
            center.pauseCommand.removeTarget(target)
            pauseTarget = nil
        }
        center.previousTrackCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
    }
}
