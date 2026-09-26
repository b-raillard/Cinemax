import Foundation
import OSLog
import CinemaxKit
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "com.cinemax", category: "Update")

/// Orchestrates the launch version check and owns what the alert binds to.
///
/// **The decision is recomputed on every launch; only the QUERY is throttled.**
/// The last release the Store reported is persisted, so a standing offer is
/// re-derived locally at each cold launch without a request — which is what
/// lets the network check run at most once a day without the offer vanishing
/// for the rest of that day. `AppUpdatePolicy` owns every rule; this type owns
/// storage, the network hop and the platform's own capabilities.
@MainActor
@Observable
final class AppUpdateChecker {
    /// What the alert renders. `.none` is the resting state and the state every
    /// failure falls back to.
    private(set) var decision: AppUpdateDecision = .none

    private let defaults: UserDefaults
    private let bundleId: String?
    /// The Store lookup. Injected so a test can count calls and hold one open
    /// (the « stamp before the await » rule below); production passes nothing.
    private let lookup: @Sendable (String) async -> AppStoreRelease?

    init(
        defaults: UserDefaults = .standard,
        bundleId: String? = AppStoreLookup.bundleIdentifier,
        lookup: @escaping @Sendable (String) async -> AppStoreRelease? = { await AppStoreLookup.fetch(bundleId: $0) }
    ) {
        self.defaults = defaults
        self.bundleId = bundleId
        self.lookup = lookup
    }

    // MARK: - Entry points

    /// Called after the session check at launch, and again on every foreground.
    /// Cheap by construction: the stored release answers without a request, and
    /// the request itself is behind a one-a-day throttle.
    func refresh(now: Date = Date()) async {
        recompute()
        guard AppUpdatePolicy.shouldQueryStore(lastCheckedAt: lastCheckedAt, now: now) else { return }
        guard let bundleId else { return }

        // Stamped BEFORE the await, not after: a server that is slow or down
        // would otherwise let every foreground in the meantime start its own
        // lookup, since none of them would see a stamp yet.
        lastCheckedAt = now
        guard let release = await lookup(bundleId) else { return }
        store(release)
        recompute()
    }

    /// « Plus tard ». Suppresses THIS version only.
    func decline() {
        guard case .offer(let release) = decision else { return }
        defaults.set(release.displayVersion, forKey: SettingsKey.updateDeclinedVersion)
        decision = .none
        logger.debug("update offer declined for \(release.displayVersion, privacy: .public)")
    }

    /// The URL « Mettre à jour » opens, or `nil` when this device cannot open
    /// one — in which case the alert renders no button at all.
    ///
    /// **RULE — the tvOS button exists only when `canOpenURL` says the App
    /// Store answers.** tvOS has no browser and no `SKStoreProductViewController`;
    /// what it does have is the App Store app's `com.apple.TVAppStore://` scheme
    /// (declared in `LSApplicationQueriesSchemes`, or `canOpenURL` always says
    /// no). The simulator has no App Store app, so there the answer is `nil`
    /// and the alert keeps its « open the App Store » hint — never a button
    /// that does nothing (the project's dead-button rule).
    var storeURLToOpen: URL? {
        guard let page = pendingRelease?.storeURL else { return nil }
        #if os(tvOS)
        guard let url = AppStoreLookup.tvAppStoreURL(for: page),
              UIApplication.shared.canOpenURL(url) else { return nil }
        return url
        #else
        return page
        #endif
    }

    /// Opens the Store page. Leaving the app for the Store is what the user
    /// just asked for, so there is no "you are leaving" confirmation.
    func openStore() {
        guard let url = storeURLToOpen else { return }
        UIApplication.shared.open(url)
    }

    /// The release the current decision is about, whether merely offered or
    /// imposed. `nil` when there is nothing to say.
    private var pendingRelease: AppStoreRelease? {
        switch decision {
        case .offer(let release), .required(let release): release
        case .none: nil
        }
    }

    // MARK: - Decision

    private func recompute() {
        let installed = Self.installedVersion
        decision = AppUpdatePolicy.decide(
            installed: installed,
            release: storedRelease,
            minimumSupported: AppUpdatePolicy.minimumSupportedVersion,
            declinedVersion: defaults.string(forKey: SettingsKey.updateDeclinedVersion)
        )
    }

    /// This build's marketing version. `nil` when unreadable, which
    /// `AppUpdatePolicy.decide` answers with silence.
    static var installedVersion: ServerVersion? {
        guard let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        return ServerVersion(raw)
    }

    // MARK: - Storage

    private var lastCheckedAt: Date? {
        get {
            let stamp = defaults.double(forKey: SettingsKey.updateLastCheckedAt)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: SettingsKey.updateLastCheckedAt)
        }
    }

    private var storedRelease: AppStoreRelease? {
        guard let raw = defaults.string(forKey: SettingsKey.updateLatestVersion),
              let version = ServerVersion(raw) else { return nil }
        let link = defaults.string(forKey: SettingsKey.updateLatestStoreURL)
        return AppStoreRelease(
            version: version,
            displayVersion: raw,
            storeURL: link.flatMap(URL.init(string:))
        )
    }

    private func store(_ release: AppStoreRelease) {
        defaults.set(release.displayVersion, forKey: SettingsKey.updateLatestVersion)
        defaults.set(release.storeURL?.absoluteString, forKey: SettingsKey.updateLatestStoreURL)
    }
}
