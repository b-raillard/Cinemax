import Foundation

/// The first-run onboarding's pure decisions — whether it appears at all, how
/// its pages chain, and what the tvOS Menu button does on each of them. Kept
/// out of `OnboardingScreen` so the routing that decides who ever sees it is
/// locked by `OnboardingPolicyTests` rather than by reading SwiftUI.
enum OnboardingPolicy {
    /// Whether `AppNavigation` renders the onboarding in place of
    /// `ServerSetupScreen` on its no-server branch.
    ///
    /// A genuine first run only: nothing registered, nothing mirrored, not
    /// reusing the pre-auth flow to ADD a server, and never seen. Every other
    /// input shape describes somebody who already knows the app — an upgrade
    /// (the multi-server migration has seeded an entry), a logout from their
    /// only server (the tokenless entry stays), an add from Réglages
    /// (`isAddingServer`) — and putting three pages of introduction in front
    /// of them would be an obstacle, not a welcome.
    static func shouldShow(
        seen: Bool,
        hasRegisteredServer: Bool,
        hasServer: Bool,
        isAddingServer: Bool
    ) -> Bool {
        !seen && !hasRegisteredServer && !hasServer && !isAddingServer
    }

    /// Whether a launch should latch `onboarding.seen` on its own.
    ///
    /// An install that already knows a server is not a first run whatever the
    /// flag says — it upgraded from a version that had no onboarding. Latching
    /// it at launch is what keeps that user out for good: without it, deleting
    /// their last server from the servers list would empty the registry and
    /// the policy above would greet a long-standing user as a newcomer.
    static func shouldStampSeen(hasRegisteredServer: Bool, hasServer: Bool) -> Bool {
        hasRegisteredServer || hasServer
    }
}

/// The three pages, in order. `rawValue` is the page's position.
enum OnboardingPage: Int, CaseIterable, Identifiable, Hashable, Sendable {
    /// What Jellyfin is, LAN discovery, the link to `ServerHelpSheet`.
    case server
    /// Quick Connect — signing in without typing a password on a remote.
    case quickConnect
    /// The custom menu and the accent colour.
    case personalize

    var id: Int { rawValue }

    /// `nil` on the last page — the CTA finishes instead of advancing.
    var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }

    /// `nil` on the first page — Menu / swipe-back has nowhere to go.
    var previous: OnboardingPage? { OnboardingPage(rawValue: rawValue - 1) }

    var isLast: Bool { next == nil }
}

/// What the tvOS Menu button does on an onboarding page.
enum OnboardingExit: Equatable, Sendable {
    /// Back one page.
    case previousPage
    /// Close the cover (the Settings re-open), per the one-chrome-per-cover RULE.
    case dismiss
    /// Install no handler — the system default, i.e. suspend the app. What the
    /// pre-auth screens do when there is nothing to go back to.
    case systemDefault

    static func decide(page: OnboardingPage, isReplay: Bool) -> OnboardingExit {
        if page.previous != nil { return .previousPage }
        return isReplay ? .dismiss : .systemDefault
    }
}
