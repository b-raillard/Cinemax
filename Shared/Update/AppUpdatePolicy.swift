import Foundation
import CinemaxKit

/// One release of Cinemax as the App Store describes it.
///
/// Deliberately carries no release notes. The Store's own "what's new" text is
/// written for the Store listing, and the app has its own curated account of a
/// version — so putting the Store's copy in an alert would be a second, worse
/// voice for the same thing.
struct AppStoreRelease: Equatable, Sendable {
    /// Parsed for COMPARISON. Never rendered: `ServerVersion.description`
    /// normalises to four components, so a `2.1.0` release would print as
    /// `2.1.0.0` in front of the user.
    let version: ServerVersion
    /// Exactly what the Store reported, for display.
    let displayVersion: String
    /// The Store page. Absent on tvOS by construction — see the RULE on the
    /// missing CTA there — and absent whenever the lookup omitted it.
    let storeURL: URL?
}

/// What the launch check decided to put in front of the user.
enum AppUpdateDecision: Equatable {
    /// Say nothing. The overwhelmingly common answer, and the answer to every
    /// uncertainty: a failed lookup, an unreadable version, an app the Store
    /// has never heard of.
    case none
    /// A newer version exists. Dismissible, and dismissed FOR THAT VERSION.
    case offer(AppStoreRelease)
    /// This build is below the supported floor. No « Plus tard ».
    case required(AppStoreRelease)
}

/// The pure decisions behind « une nouvelle version est disponible ».
///
/// Everything that decides WHETHER to speak lives here, so it is locked by
/// `AppUpdatePolicyTests` rather than by reading SwiftUI — the same arrangement
/// as `OnboardingPolicy`, whose job this one sits next to: both answer a
/// question asked once at launch, and neither may ever answer at the same time
/// as the other (see `AppUpdateChecker`).
enum AppUpdatePolicy {
    /// **The mandatory-update switch, decided at development time.**
    ///
    /// `nil` — today's value — means no version is ever compulsory: the user is
    /// offered the update and can decline it for as long as they like. Setting
    /// it to a version makes every build strictly below that version refuse to
    /// carry on without updating.
    ///
    /// **RULE — a mandatory update is a promise the app cannot keep alone, so
    /// it is only ever honoured when the Store actually has something newer.**
    /// `decide` refuses to return `.required` unless a newer release exists;
    /// a floor raised above what the Store offers would otherwise lock the user
    /// out of an app they have no way to repair. That guard is what makes this
    /// constant safe to set in a hurry, which is precisely when it gets set.
    static let minimumSupportedVersion: ServerVersion? = nil

    /// How often the Store is asked. A day: an update the user declines this
    /// morning is not more interesting this afternoon, and the answer changes
    /// at the pace App Review works.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Whether the network lookup is due. The DECISION is recomputed from the
    /// stored release on every launch regardless — see `AppUpdateChecker` —
    /// so a throttled check still shows a standing offer.
    static func shouldQueryStore(
        lastCheckedAt: Date?,
        now: Date,
        interval: TimeInterval = checkInterval
    ) -> Bool {
        guard let lastCheckedAt else { return true }
        // A clock moved backwards (timezone edit, NTP correction) must not
        // silence the check until the future catches up.
        if lastCheckedAt > now { return true }
        return now.timeIntervalSince(lastCheckedAt) >= interval
    }

    /// - Parameters:
    ///   - installed: this build's `CFBundleShortVersionString`, parsed. `nil`
    ///     when it cannot be read at all, which resolves to silence: an app
    ///     that does not know its own version has no business claiming another
    ///     one is newer.
    ///   - release: the newest release the Store reported, or `nil` if it has
    ///     never answered.
    ///   - minimumSupported: `AppUpdatePolicy.minimumSupportedVersion`, passed
    ///     in so the truth table is testable without editing a constant.
    ///   - declinedVersion: the `displayVersion` the user already answered
    ///     « Plus tard » to. It suppresses THAT version only — a later one is a
    ///     new question, and a refusal is not a standing instruction to stop
    ///     talking for ever.
    static func decide(
        installed: ServerVersion?,
        release: AppStoreRelease?,
        minimumSupported: ServerVersion?,
        declinedVersion: String?
    ) -> AppUpdateDecision {
        guard let installed, let release else { return .none }
        // Equal or older: the Store is behind us (a TestFlight build, a staged
        // rollout) — never a reason to say anything.
        guard release.version > installed else { return .none }

        if let minimumSupported, installed < minimumSupported {
            return .required(release)
        }
        if let declinedVersion, declinedVersion == release.displayVersion {
            return .none
        }
        return .offer(release)
    }
}
