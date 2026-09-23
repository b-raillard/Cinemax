import Foundation
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Update")

/// Asks the App Store which version of this app it currently serves.
///
/// **RULE — this must never touch the shared session machinery**, same
/// discipline as `ServerReachability`: it talks to Apple, not to the user's
/// Jellyfin server, on its own cache-less `URLSession` with no auth header of
/// any kind. A 401 is structurally impossible here, so nothing this does can
/// ever reach `notifyIfUnauthorized` and start a session-expiry cycle — the
/// same rule the diagnostics upload carries, for the same reason: a piece of
/// housekeeping must never be what signs the user out.
///
/// **Every failure is silence.** No network, a storefront that has never heard
/// of this bundle id, a malformed answer, a timeout — all return `nil`, and
/// `AppUpdatePolicy.decide` turns `nil` into `.none`. An update prompt that
/// appears because a request failed would be the worst possible outcome of a
/// feature whose whole purpose is to be helpful once in a while.
enum AppStoreLookup {
    /// Short leash: this runs at launch, off the critical path, and nothing
    /// downstream waits for it.
    static let timeout: TimeInterval = 8

    /// The storefront to ask. The Store's version is the same everywhere, but
    /// the lookup answers `resultCount: 0` for a storefront that does not carry
    /// the app — so asking the user's own region is what stops an app published
    /// outside the US from looking unpublished.
    static var region: String? {
        Locale.current.region?.identifier
    }

    /// This binary's own identifier, never a literal: the iOS and tvOS apps
    /// have different ones (`com.cinemax.ios` / `com.cinemax.tvos`) and a
    /// hardcoded id would have one platform quietly reading the other's
    /// release.
    static var bundleIdentifier: String? {
        Bundle.main.bundleIdentifier
    }

    static func fetch(
        bundleId: String,
        region: String? = nil,
        session: URLSession? = nil
    ) async -> AppStoreRelease? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        var items = [URLQueryItem(name: "bundleId", value: bundleId)]
        // `nil` means « ask the device's own storefront »; an explicit value is
        // for a caller that knows better. A device with no region at all simply
        // asks the default storefront rather than failing.
        if let storefront = region ?? Self.region {
            items.append(URLQueryItem(name: "country", value: storefront))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        // The whole point is what the Store serves RIGHT NOW; a cached answer
        // would keep proposing a version the user already installed.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let client = session ?? makeSession()
        do {
            let (data, response) = try await client.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.debug("app store lookup: unexpected response")
                return nil
            }
            return parse(data)
        } catch {
            logger.debug("app store lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pure, so the wire shape is locked by a test instead of by a live
    /// request to Apple.
    static func parse(_ data: Data) -> AppStoreRelease? {
        guard let payload = try? JSONDecoder().decode(LookupPayload.self, from: data),
              let entry = payload.results.first,
              let raw = entry.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let version = ServerVersion(raw) else { return nil }

        // `ServerVersion` is the project's ONE version comparator — it already
        // knows that 2.10 is newer than 2.9, which is the single mistake a
        // second, hand-rolled comparison would inevitably make.
        var storeURL: URL?
        if let link = entry.trackViewUrl, let parsed = URL(string: link),
           parsed.scheme == "https" {
            storeURL = parsed
        }
        return AppStoreRelease(version: version, displayVersion: raw, storeURL: storeURL)
    }

    /// The Apple TV's App Store page for the release the lookup described.
    ///
    /// tvOS has no browser and no `SKStoreProductViewController`, but its App
    /// Store app answers `com.apple.TVAppStore://itunes.apple.com/app/id<ID>`.
    /// The id is read from the https page the lookup already returned
    /// (`…/app/<slug>/id1234567890`), so no extra request and no stored field.
    /// `nil` when the link carries no numeric `id…` component — the caller then
    /// renders no button rather than one that goes nowhere.
    nonisolated static func tvAppStoreURL(for storeURL: URL) -> URL? {
        guard let component = storeURL.pathComponents.last(where: { $0.hasPrefix("id") }) else {
            return nil
        }
        let digits = component.dropFirst(2)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return nil }
        return URL(string: "com.apple.TVAppStore://itunes.apple.com/app/id\(digits)")
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        // Offline is an ordinary state at launch; never queue this for later.
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    private struct LookupPayload: Decodable {
        let results: [Entry]

        struct Entry: Decodable {
            let version: String?
            let trackViewUrl: String?
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
