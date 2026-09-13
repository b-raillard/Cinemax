import Foundation
import CinemaxKit

/// Decides whether the first launch on a new version shows « Quoi de neuf ».
///
/// Sits next to `OnboardingPolicy`, whose job it mirrors: both answer a
/// question asked once at launch, both are pure so the routing is locked by
/// tests rather than by reading SwiftUI, and **neither may ever answer at the
/// same time as the other** — see the `isFirstRun` rule below.
enum WhatsNewPolicy {
    /// What a launch should do about the reel.
    enum Outcome: Equatable {
        /// Show nothing and leave the stamp alone. The state of every launch
        /// that is not the first one on a new version.
        case nothing
        /// Show these pages, then stamp the installed version.
        case show([WhatsNewPage])
        /// Stamp the installed version WITHOUT showing anything.
        ///
        /// Load-bearing, and the half that is easy to forget: a genuine first
        /// run, and a version that ships no pages at all (a pure bug-fix
        /// release), must both move the stamp forward. Otherwise the next
        /// version's launch would hand the user everything accumulated since —
        /// including the announcements for a version they started on, which is
        /// exactly the "greeted as a newcomer" failure `shouldStampSeen` exists
        /// to prevent on the onboarding side.
        case stampOnly
    }

    /// - Parameters:
    ///   - lastSeenVersion: `whatsNew.lastSeenVersion`, or `nil` on an install
    ///     that has never stamped one. **`nil` is NOT "first run"** — it is
    ///     also every install upgrading from a build that predates this
    ///     feature, and showing them what is new is the entire point. The two
    ///     are told apart by `isFirstRun`, never by this being absent.
    ///   - installed: this build's version. `nil` (unreadable) resolves to
    ///     `.nothing`: an app that does not know its own version cannot claim
    ///     anything is new in it.
    ///   - isFirstRun: `OnboardingPolicy.shouldShow(...)` — somebody meeting
    ///     the app for the first time. They get the welcome and nothing else:
    ///     the news of a version they have never known is not news, it is
    ///     noise in front of somebody still trying to reach their server.
    static func decide(
        lastSeenVersion: String?,
        installed: ServerVersion?,
        isFirstRun: Bool,
        catalogue: [WhatsNewRelease] = WhatsNewCatalogue.releases
    ) -> Outcome {
        guard let installed else { return .nothing }
        if isFirstRun { return .stampOnly }

        let lastSeen = lastSeenVersion.flatMap(ServerVersion.init)
        // Already caught up — or ahead of this build, which happens on a
        // downgrade and must not replay anything.
        if let lastSeen, lastSeen >= installed { return .nothing }

        let pages = WhatsNewCatalogue.pages(since: lastSeen, upTo: installed, in: catalogue)
        return pages.isEmpty ? .stampOnly : .show(pages)
    }

    /// The value to write into `whatsNew.lastSeenVersion` once the reel has
    /// been shown or skipped. The INSTALLED version, never the newest release
    /// in the catalogue: a catalogue entry written ahead of its release (the
    /// ordinary way a version is prepared) would otherwise silence the very
    /// announcement it was written for.
    static func stamp(installed: ServerVersion?) -> String? {
        installed?.description
    }
}
