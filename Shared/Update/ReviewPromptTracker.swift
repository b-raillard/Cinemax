#if os(iOS)
import StoreKit
import SwiftUI

/// Counts engaged playback sessions and decides, when the player closes,
/// whether the App Store rating request is due. `ReviewPromptPolicy` owns
/// every rule; this type owns storage. iOS only: StoreKit marks the request
/// `tvOS unavailable`.
@MainActor
@Observable
final class ReviewPromptTracker {
    /// Set when the player closed and the policy says now is the time.
    /// Consumed by `ReviewPromptPresentation`.
    private(set) var isDue = false

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

    /// From `VideoPlayerView.onDismiss`: the only moment a request may be
    /// raised — never mid-chain, never over the player.
    func playerDidClose(now: Date = Date()) {
        guard let installedVersion else { return }
        isDue = ReviewPromptPolicy.shouldPrompt(
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

/// Root-hosted: turns `isDue` into the system rating sheet. 1 s after the flag
/// flips so the player's dismiss animation (fullScreenCover / navigation pop,
/// ~0.4 s) has finished; the system decides whether the sheet actually shows.
struct ReviewPromptPresentation: ViewModifier {
    let tracker: ReviewPromptTracker
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .cinemaxPlaybackSessionEnded)) { note in
                tracker.recordSession(watchedSeconds: note.userInfo?[PlaybackReporter.watchedSecondsKey] as? Int ?? 0)
            }
            .onChange(of: tracker.isDue) { _, due in
                guard due else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    guard tracker.isDue else { return }
                    requestReview()
                    tracker.didPrompt()
                }
            }
    }
}
#endif
