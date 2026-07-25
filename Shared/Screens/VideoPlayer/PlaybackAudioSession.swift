import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.cinemax", category: "AudioSession")

/// Single owner of the app's playback `AVAudioSession`, kept off the main thread.
///
/// `setCategory` / `setActive` are synchronous XPC round-trips to `mediaserverd`
/// — tens of milliseconds, unbounded when the audio server is busy. Called from
/// the main actor they trip Apple's own warnings (`AVAudioSession_iOS.mm:978`
/// "This method can lead to UI unresponsiveness…", `SessionCore.mm:631`) and
/// stall the player's open / teardown for the duration.
///
/// Both presenters used to call them inline on `@MainActor`. The work now runs
/// on one serial queue, and `activate()` *suspends* its caller instead of
/// blocking it — so the ordering the engines depend on (session configured AND
/// active **before** the audio output opens) is enforced by the queue rather
/// than by main-thread blocking. Never fire-and-forget the activation: libVLC's
/// aout loops forever on `CannotStartPlaying` if it opens onto an inactive
/// session (the black-screen-after-wake bug).
enum PlaybackAudioSession {
    /// Serial, so an activation and a deactivation can never overlap on the
    /// session itself.
    ///
    /// It orders work by *enqueue* time and cannot cancel a superseded
    /// activation, so it does NOT by itself prevent a teardown's `deactivate()`
    /// from being enqueued ahead of an activation that was requested for a player
    /// already gone — which would leave the session active with nothing behind
    /// it. Callers own that: check liveness *before* awaiting `activate()`
    /// (`withCheckedContinuation` enqueues in the same main-actor slice, so a
    /// later `deactivate()` is necessarily enqueued after). See
    /// `VLCStreamPresenter.activateSessionThenPlay`.
    private static let queue = DispatchQueue(label: "com.cinemax.audiosession", qos: .userInitiated)

    /// Configure `.playback` / `.moviePlayback` and activate, returning only once
    /// the session is live. A failure is logged and still returns — playback is
    /// attempted regardless, since libVLC and AVKit both try to activate the
    /// session themselves and may well succeed.
    ///
    /// `.playback` + `.moviePlayback` is the Apple-recommended pairing for a video
    /// player: audio keeps flowing over AirPlay when the ringer is silent or the
    /// device locks, and interruption handling cooperates with other media apps.
    static func activate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playback, mode: .moviePlayback, options: [])
                    try session.setActive(true, options: [])
                } catch {
                    logger.error("Failed to activate playback audio session: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume()
            }
        }
    }

    /// Fire-and-forget — this runs during teardown and nothing the caller does
    /// next depends on the session being down.
    static func deactivate() {
        queue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logger.error("Failed to deactivate playback audio session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
