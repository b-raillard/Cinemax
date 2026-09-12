import TVServices
import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "com.cinemax", category: "TopShelf")

// Apple TV Top Shelf: a "Continue Watching" row above the app icon when
// Cinemax sits in the dock's top row. Reads the session snapshot the app
// publishes to the shared Keychain access group (`ExtensionSessionBridge` in
// CinemaxKit — keep the service / account / group / JSON shape in sync; the
// extension stays dependency-free), then queries the resume list. Item
// artwork is served straight off the Jellyfin image endpoints (the system
// fetches the URLs itself), and selecting an item deep-links via
// cinemax://item/{id}.
/// Stable ObjC name: `NSExtensionPrincipalClass` resolution of Swift
/// module-qualified names ("CinemaxTopShelf.ContentProvider") proved flaky
/// here — the extension process launched and exited within ~60ms without
/// ever instantiating the provider. `@objc(ContentProvider)` + the plain
/// class name in Info.plist removes the demangling dependency entirely.
@objc(ContentProvider)
final class ContentProvider: TVTopShelfContentProvider {
    override init() {
        super.init()
        logger.info("TopShelf ▸ ContentProvider instantiated")
    }

    private struct Session: Codable, Sendable {
        let serverURL: URL
        let accessToken: String
        let userId: String
        /// The app's `privacy.maxContentAge` ceiling. Optional so a blob written
        /// by a build predating it still decodes — keep in sync with
        /// `ExtensionSessionBridge.Session`.
        let maxContentAge: Int?
    }

    /// Minimal copy of CinemaxKit's `ContentRatingClassifier`: this extension
    /// deliberately links no package, so the table is duplicated here — the same
    /// precedent as the three hand-copied `Session` shapes. Locked by the
    /// extension-parity cases in `ExtensionSessionContractTests`.
    private enum ContentRating {
        private static let ageMap: [String: Int] = [
            "G": 0, "PG": 10, "PG-13": 13, "R": 17, "NC-17": 18,
            "TV-Y": 0, "TV-Y7": 7, "TV-G": 0, "TV-PG": 10, "TV-14": 14, "TV-MA": 17,
            "U": 0, "12": 12, "12A": 12, "15": 15, "18": 18,
            "-10": 10, "-12": 12, "-16": 16, "-18": 18,
            "TOUS PUBLICS": 0,
            "FSK-0": 0, "FSK-6": 6, "FSK-12": 12, "FSK-16": 16, "FSK-18": 18
        ]

        /// Unknown or missing ⇒ `0`, i.e. permissive — the app's own rule, since
        /// an episode routinely inherits its rating from its series and arrives
        /// absent.
        static func age(forRating rating: String?) -> Int {
            guard let rating else { return 0 }
            return ageMap[rating.trimmingCharacters(in: .whitespaces).uppercased()] ?? 0
        }

        static func passes(rating: String?, maxAge: Int?) -> Bool {
            guard let maxAge, maxAge > 0 else { return true }
            return age(forRating: rating) <= maxAge
        }
    }

    private struct ItemsResponse: Decodable, Sendable {
        let items: [Item]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    private struct Item: Decodable, Sendable {
        let id: String
        let name: String?
        let seriesName: String?
        let seriesId: String?
        let parentBackdropItemId: String?
        let officialRating: String?
        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", seriesName = "SeriesName"
            case seriesId = "SeriesId", parentBackdropItemId = "ParentBackdropItemId"
            case officialRating = "OfficialRating"
        }
    }

    /// Wraps the framework's non-Sendable completion so it can cross into the
    /// fetch Task (same pattern as the app's `PiPRestoreHandlerBox`). Safe:
    /// the handler is invoked exactly once, and TVServices documents no queue
    /// affinity for it.
    private final class HandlerBox: @unchecked Sendable {
        let call: ((any TVTopShelfContent)?) -> Void
        init(call: @escaping ((any TVTopShelfContent)?) -> Void) {
            self.call = call
        }
    }

    // Completion-based override (not the async variant): `TVTopShelfContent`
    // isn't Sendable, so returning it from a nonisolated async override trips
    // strict concurrency. Content is built and handed off inside one Task region.
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        let handler = HandlerBox(call: completionHandler)
        Task { await ContentProvider.run(handler: handler) }
    }

    private static func run(handler: HandlerBox) async {
        logger.info("TopShelf ▸ loadTopShelfContent invoked")
        guard let session = readSession() else {
            logger.error("TopShelf ▸ no session snapshot in the shared Keychain group (app not opened since install, or keychain-access-group not shared)")
            // No session snapshot visible from the extension. Either the app
            // hasn't been opened since install, or the shared
            // keychain-access-group isn't provisioned (each side then
            // writes/reads its own private items). A diagnostic tile beats a
            // silent static image.
            handler.call(diagnosticContent(
                fr: "Ouvrez Cinemax pour activer cette rangée",
                en: "Open Cinemax to enable this row"
            ))
            return
        }
        logger.info("TopShelf ▸ session ok host=\(session.serverURL.host() ?? "?", privacy: .public)")
        let items = await fetchResumeItems(session: session, limit: 8)
        logger.info("TopShelf ▸ resume fetch → \(items.map { String($0.count) } ?? "FAILED", privacy: .public)")
        deliver(items: items, session: session, handler: handler)
    }

    /// Synchronous tail: builds the (non-Sendable) shelf content and hands it
    /// to the framework callback in one region the isolation checker accepts.
    private static func deliver(items: [Item]?, session: Session, handler: HandlerBox) {
        guard let items else {
            // Session OK but the server didn't answer (network / auth / TLS).
            handler.call(diagnosticContent(
                fr: "Serveur Jellyfin inaccessible",
                en: "Jellyfin server unreachable"
            ))
            return
        }
        guard !items.isEmpty else {
            // Genuinely nothing in progress — the static image is correct.
            handler.call(nil)
            return
        }
        handler.call(makeContent(items: items, session: session))
    }

    /// Single text-only tile naming the failing branch — selecting it opens
    /// the app. Visible only while the shelf is broken/un-activated.
    private static func diagnosticContent(fr: String, en: String) -> any TVTopShelfContent {
        let isFrench = Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
        let item = TVTopShelfSectionedItem(identifier: "cinemax.diagnostic")
        item.title = isFrench ? fr : en
        item.imageShape = .square
        if let url = URL(string: "cinemax://home") {
            item.displayAction = TVTopShelfAction(url: url)
        }
        let section = TVTopShelfItemCollection(items: [item])
        section.title = "Cinemax"
        return TVTopShelfSectionedContent(sections: [section])
    }

    private static func makeContent(items: [Item], session: Session) -> any TVTopShelfContent {
        let isFrench = Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
        let shelfItems = items.map { item -> TVTopShelfSectionedItem in
            let shelf = TVTopShelfSectionedItem(identifier: item.id)
            shelf.title = item.seriesName ?? item.name ?? ""
            shelf.imageShape = .poster
            let posterId = item.seriesId ?? item.id
            if let url = imageURL(session: session, itemId: posterId, type: "Primary", maxWidth: 600) {
                shelf.setImageURL(url, for: [.screenScale1x, .screenScale2x])
            }
            if let deepLink = URL(string: "cinemax://item/\(item.id)") {
                shelf.displayAction = TVTopShelfAction(url: deepLink)
                shelf.playAction = TVTopShelfAction(url: deepLink)
            }
            return shelf
        }

        let section = TVTopShelfItemCollection(items: shelfItems)
        section.title = isFrench ? "Reprendre la lecture" : "Continue Watching"
        return TVTopShelfSectionedContent(sections: [section])
    }

    /// Sole store: the shared, device-only Keychain group the app publishes
    /// to. The legacy plaintext App Group fallback is gone — the app has
    /// written the Keychain copy since 1.0.3, and the app scrubs the old
    /// cleartext blob on its next `publish`.
    private static func readSession() -> Session? {
        readSessionFromKeychain()
    }

    /// Reads the shared session from the Keychain group. Service + account are
    /// hardcoded (the extension can't link CinemaxKit) — keep in sync with
    /// `KeychainService.serviceName` / `sharedSessionAccount`.
    private static func readSessionFromKeychain() -> Session? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.cinemax.jellyfin",
            kSecAttrAccount as String: "extension_session",
            kSecAttrAccessGroup as String: prefix + "com.cinemax.shared",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    /// JSON fetches go through an EPHEMERAL session, never `URLSession.shared`:
    /// the shared session carries a disk-backed `URLCache`, so authenticated
    /// Jellyfin responses would be written to a cache file in the extension
    /// container. Top Shelf re-queries on every invocation anyway.
    private static let httpSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// nil = the request failed (network / auth); empty = nothing in progress.
    private static func fetchResumeItems(session: Session, limit: Int) async -> [Item]? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath("/UserItems/Resume", serverURL: session.serverURL)
        // No `ApiKey` query item — auth rides the Authorization header below,
        // so the token never lands in a URL log or cache key.
        comps.queryItems = [
            URLQueryItem(name: "userId", value: session.userId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "mediaTypes", value: "Video"),
            // `OfficialRating` is asked for EXPLICITLY rather than relying on the
            // server's default field set: measured on the captured fixtures of
            // all three supported generations, `/UserItems/Resume` returns it
            // unasked but `/Shows/NextUp` returns it on none — so the app-side
            // habit of not asking is not a guarantee to inherit here.
            URLQueryItem(name: "fields", value: "OfficialRating")
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await httpSession.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode(ItemsResponse.self, from: data) else { return nil }
        // The Apple TV shelf is the family screen: without this, a title rated
        // above the user's cap reached it with no interaction at all (#230).
        return decoded.items.filter {
            ContentRating.passes(rating: $0.officialRating, maxAge: session.maxContentAge)
        }
    }

    /// The ONE place the token legitimately stays in a URL: these URLs are handed
    /// to `TVTopShelfSectionedItem.setImageURL`, i.e. the SYSTEM fetches them —
    /// we never issue the request, so header auth is impossible here.
    /// `ApiKey`, never `api_key`: the legacy spelling is rejected by Jellyfin
    /// 12.0's default (`EnableLegacyAuthorization = false`).
    private static func imageURL(session: Session, itemId: String, type: String, maxWidth: Int) -> URL? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath("/Items/\(itemId)/Images/\(type)", serverURL: session.serverURL)
        comps.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "ApiKey", value: session.accessToken)
        ]
        return comps.url
    }
}

/// Sets the request path while preserving the server's base path (a server
/// hosted at `https://host/jellyfin` would otherwise lose `/jellyfin` and
/// 404). Mirrors `URLComponents.setEndpointPath` in CinemaxKit — kept in
/// sync manually because this extension can't link the package.
private func endpointPath(_ endpoint: String, serverURL: URL) -> String {
    let base = serverURL.path
    if base.isEmpty || base == "/" { return endpoint }
    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
    return trimmed + endpoint
}
