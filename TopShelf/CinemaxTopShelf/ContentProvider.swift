import TVServices
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cinemax", category: "TopShelf")

// Apple TV Top Shelf: a "Continue Watching" row above the app icon when
// Cinemax sits in the dock's top row. Reads the session snapshot the app
// publishes to the App Group (`ExtensionSessionBridge` in CinemaxKit — keep
// the suite / key / JSON shape in sync; the extension stays dependency-free),
// then queries the resume list. Item artwork is served straight off the
// Jellyfin image endpoints (the system fetches the URLs itself), and
// selecting an item deep-links via cinemax://item/{id}.
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
        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", seriesName = "SeriesName"
            case seriesId = "SeriesId", parentBackdropItemId = "ParentBackdropItemId"
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
            logger.error("TopShelf ▸ no session snapshot in App Group (app not opened since install, or App Group not shared)")
            // No session snapshot visible from the extension. Either the app
            // hasn't been opened since install, or the App Group entitlement
            // isn't provisioned (each side then writes/reads its own private
            // container). A diagnostic tile beats a silent static image.
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

    private static func readSession() -> Session? {
        guard let defaults = UserDefaults(suiteName: "group.com.cinemax.shared"),
              let data = defaults.data(forKey: "extension.session") else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    /// nil = the request failed (network / auth); empty = nothing in progress.
    private static func fetchResumeItems(session: Session, limit: Int) async -> [Item]? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = "/UserItems/Resume"
        comps.queryItems = [
            URLQueryItem(name: "userId", value: session.userId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "mediaTypes", value: "Video"),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode(ItemsResponse.self, from: data) else { return nil }
        return decoded.items
    }

    private static func imageURL(session: Session, itemId: String, type: String, maxWidth: Int) -> URL? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = "/Items/\(itemId)/Images/\(type)"
        comps.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        return comps.url
    }
}
