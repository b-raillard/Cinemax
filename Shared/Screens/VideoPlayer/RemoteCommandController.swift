import MediaPlayer

/// Drives the system's prev/next track buttons in the native HUD (Lock Screen,
/// Control Center, Siri Remote on tvOS). Mirrors the sub-controller pattern
/// already used by `PlaybackReporter` / `SkipSegmentController` /
/// `SleepTimerController`: presenter retains a single instance per session,
/// `attach` on play / episode-nav, `detach` on cleanup.
///
/// Both target handlers capture the destination `EpisodeRef` directly — no
/// per-tick state on this controller; the system fires the closure when the
/// user taps prev/next in the HUD.
@MainActor
final class RemoteCommandController {
    private let onNavigate: @MainActor (EpisodeRef) -> Void
    private var prevCommandTarget: Any?
    private var nextCommandTarget: Any?

    init(onNavigate: @escaping @MainActor (EpisodeRef) -> Void) {
        self.onNavigate = onNavigate
    }

    /// Wires the system prev/next commands. Pass `hasNavigator == false` to
    /// suppress both buttons (e.g. movie playback where there is no episode
    /// graph). Re-callable: previously registered targets are replaced each
    /// time, matching how the presenter calls this on every episode nav.
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
    }

    /// Removes the prev/next targets and disables the commands. Idempotent.
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
        center.previousTrackCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
    }
}
