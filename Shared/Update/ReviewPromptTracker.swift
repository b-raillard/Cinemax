#if os(iOS)
import StoreKit
import SwiftUI
import UIKit

/// Counts engaged playback sessions and decides, when the player closes or
/// a signed-in launch settles, whether the App Store rating request is due. `ReviewPromptPolicy` owns
/// every rule; this type owns storage. iOS only: StoreKit marks the request
/// `tvOS unavailable`.
@MainActor
@Observable
final class ReviewPromptTracker {
    /// Set when the player closed (or the app launched) and the policy says
    /// now is the time.
    /// Consumed by `ReviewPromptPresentation`.
    private(set) var isDue = false
    /// How long `ReviewPromptPresentation` waits once `isDue` flips: set by
    /// whichever moment raised it.
    private(set) var dueDelay: Duration = ReviewPromptPolicy.afterCloseDelay
    /// `appDidLaunch()` asks once per process.
    private var didCheckLaunch = false

    private let defaults: UserDefaults
    private let installedVersion: String?

    init(
        defaults: UserDefaults = .standard,
        installedVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    ) {
        self.defaults = defaults
        self.installedVersion = installedVersion
    }

    /// From the reporter's notification: counts the session if it qualifies,
    /// persists the count.
    func recordSession(watchedSeconds: Int) {
        guard ReviewPromptPolicy.qualifies(watchedSeconds: watchedSeconds) else { return }
        qualifyingPlaybacks += 1
    }

    /// From `VideoPlayerView.onDismiss`: the first of the two moments a
    /// request may be raised — never mid-chain, never over the player.
    func playerDidClose(now: Date = Date()) {
        guard let installedVersion else { return }
        dueDelay = ReviewPromptPolicy.afterCloseDelay
        isDue = isPromptDue(installedVersion: installedVersion, now: now)
    }

    /// From `AppNavigation`'s launch `.task`, once the session is restored and
    /// signed in: the second moment. Someone who ends every evening by swiping
    /// the app away with the player still open never closes a player, so the
    /// close alone never asked them (their sessions are counted on the way to
    /// the background — `PlaybackReporter.creditEngagementIfQualified`). Asked
    /// `afterLaunchDelay` later, i.e. on the app's first screen; a player
    /// opened meanwhile withdraws it like any other. Once per process.
    func appDidLaunch(now: Date = Date()) {
        guard !didCheckLaunch else { return }
        didCheckLaunch = true
        guard let installedVersion,
              isPromptDue(installedVersion: installedVersion, now: now) else { return }
        dueDelay = ReviewPromptPolicy.afterLaunchDelay
        isDue = true
    }

    /// From `VideoPlayerView.onAppear`: a player opening withdraws a request
    /// still waiting out `ReviewPromptPresentation`'s delay. `isDue` flips
    /// at the START of the close, so « Lire » tapped within that second used to
    /// put the system sheet over the new player's loading screen (recette
    /// 2026-10-02). Nothing is stamped: the next close asks the policy again.
    func playerDidOpen() {
        withdraw()
    }

    /// Drops a pending request without stamping anything — the count stands
    /// and the next close asks again. Also what lets `isDue` flip back to
    /// true, which is the only thing `ReviewPromptPresentation` reacts to.
    func withdraw() {
        isDue = false
    }

    private func isPromptDue(installedVersion: String, now: Date) -> Bool {
        ReviewPromptPolicy.shouldPrompt(
            qualifyingPlaybacks: qualifyingPlaybacks,
            installedVersion: installedVersion,
            lastPromptedVersion: lastPromptedVersion,
            lastPromptedAt: lastPromptedAt,
            now: now
        )
    }

    /// After `requestReview()` was called: stamp version + date, reset the
    /// count, clear `isDue`. StoreKit gives no feedback on whether the sheet
    /// showed, so the request itself is what is stamped.
    func didPrompt(now: Date = Date()) {
        lastPromptedVersion = installedVersion
        lastPromptedAt = now
        qualifyingPlaybacks = 0
        isDue = false
    }

    // MARK: - Storage

    private var qualifyingPlaybacks: Int {
        get { defaults.integer(forKey: SettingsKey.reviewQualifyingPlaybacks) }
        set { defaults.set(newValue, forKey: SettingsKey.reviewQualifyingPlaybacks) }
    }

    private var lastPromptedVersion: String? {
        get {
            let raw = defaults.string(forKey: SettingsKey.reviewLastPromptedVersion) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set { defaults.set(newValue ?? "", forKey: SettingsKey.reviewLastPromptedVersion) }
    }

    private var lastPromptedAt: Date? {
        get {
            let stamp = defaults.double(forKey: SettingsKey.reviewLastPromptedAt)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: SettingsKey.reviewLastPromptedAt) }
    }
}

/// Root-hosted: turns `isDue` into the system rating sheet, `dueDelay` after
/// the flag flips (1 s after a close so the player's dismiss animation has
/// finished, 5 s after a launch); the system decides whether the sheet
/// actually shows. A request that would land over another presentation
/// (`isBlocked`: « Quoi de neuf », the update alert) or while the app is not
/// in the foreground is withdrawn, never stamped — StoreKit would show
/// nothing there, or show it over a screen the user is reading.
struct ReviewPromptPresentation: ViewModifier {
    let tracker: ReviewPromptTracker
    /// Read when the delay ends, not when the modifier was built.
    let isBlocked: @MainActor () -> Bool
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .cinemaxPlaybackSessionEnded)) { note in
                tracker.recordSession(watchedSeconds: note.userInfo?[PlaybackReporter.watchedSecondsKey] as? Int ?? 0)
            }
            .onChange(of: tracker.isDue) { _, due in
                guard due else { return }
                let delay = tracker.dueDelay
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard tracker.isDue else { return }
                    guard !isBlocked(), UIApplication.shared.applicationState == .active else {
                        tracker.withdraw()
                        return
                    }
                    requestReview()
                    tracker.didPrompt()
                }
            }
    }
}
#endif
