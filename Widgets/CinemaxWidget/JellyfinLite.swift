import Foundation
import Security

// Minimal, dependency-free Jellyfin access for the widget. The extension
// deliberately does NOT link CinemaxKit (widget memory budgets are tight and
// the SDK pulls Nuke + generated entities); it reads the session snapshot the
// app publishes to the shared Keychain access group (`ExtensionSessionBridge`
// — keep the service / account / group / JSON shape in sync) and talks to two
// endpoints directly.
enum JellyfinLite {
    struct Session: Codable {
        let serverURL: URL
        let accessToken: String
        let userId: String
        /// The app's `privacy.maxContentAge` ceiling. Optional so a blob written
        /// by a build predating it still decodes — keep in sync with
        /// `ExtensionSessionBridge.Session`.
        let maxContentAge: Int?
    }

    /// Minimal copy of CinemaxKit's `ContentRatingClassifier`: the extension
    /// deliberately links no package, so the table is duplicated here — the same
    /// precedent as the three hand-copied `Session` shapes. Keep it in step with
    /// the app's; locked by the extension-parity cases in
    /// `ContentRatingClassifierTests`.
    enum ContentRating {
        private static let ageMap: [String: Int] = [
            "G": 0, "PG": 10, "PG-13": 13, "R": 17, "NC-17": 18,
            "TV-Y": 0, "TV-Y7": 7, "TV-G": 0, "TV-PG": 10, "TV-14": 14, "TV-MA": 17,
            "U": 0, "12": 12, "12A": 12, "15": 15, "18": 18,
            "-10": 10, "-12": 12, "-16": 16, "-18": 18,
            "TOUS PUBLICS": 0,
            "FSK-0": 0, "FSK-6": 6, "FSK-12": 12, "FSK-16": 16, "FSK-18": 18
        ]

        /// Unknown or missing ⇒ `0`, i.e. permissive. Same rule as the app: an
        /// episode routinely inherits its rating from its series and arrives
        /// absent, so filtering on missing data would empty most catalogues.
        static func age(forRating rating: String?) -> Int {
            guard let rating else { return 0 }
            return ageMap[rating.trimmingCharacters(in: .whitespaces).uppercased()] ?? 0
        }

        static func passes(rating: String?, maxAge: Int?) -> Bool {
            guard let maxAge, maxAge > 0 else { return true }
            return age(forRating: rating) <= maxAge
        }

        /// The `maxOfficialRating` string to send on `/Items` queries, which the
        /// server filters itself. Mirrors the app's own per-endpoint split:
        /// server-side on the `/Items` family, local everywhere else.
        static func maxOfficialRatingCode(forAge maxAge: Int?) -> String? {
            guard let maxAge, maxAge > 0 else { return nil }
            switch maxAge {
            case 1...10:  return "TV-PG"
            case 11...12: return "PG-13"
            case 13...14: return "TV-14"
            case 15...16: return "TV-MA"
            default:      return "NC-17"
            }
        }
    }

    struct ResumeItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        /// Item whose Primary image to show — the parent series for episodes,
        /// so the widget grid stays poster-shaped.
        let posterItemId: String
    }

    /// Account + service the app's `KeychainService` writes the shared session
    /// under. Hardcoded here because the extension can't link CinemaxKit — keep
    /// in sync with `KeychainService.serviceName` / `sharedSessionAccount`.
    private static let keychainService = "com.cinemax.jellyfin"
    private static let keychainAccount = "extension_session"

    /// Every request goes through an EPHEMERAL session, never
    /// `URLSession.shared`: the shared session carries a disk-backed
    /// `URLCache`, so authenticated Jellyfin responses (and the poster bytes)
    /// would be written to a cache file inside the extension container. The
    /// widget refetches on its own timeline anyway, so there is nothing to
    /// gain from an on-disk HTTP cache here.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Sole store: the shared, device-only Keychain group the app publishes
    /// to. The legacy plaintext App Group fallback is gone — the app has
    /// written the Keychain copy since 1.0.3, and the app scrubs the old
    /// cleartext blob on its next `publish`.
    static func readSession() -> Session? {
        readSessionFromKeychain()
    }

    private static func readSessionFromKeychain() -> Session? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: prefix + "com.cinemax.shared",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private struct ItemsResponse: Decodable {
        let items: [Item]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    private struct Item: Decodable {
        let id: String
        let name: String?
        let type: String?
        let seriesName: String?
        let seriesId: String?
        let parentIndexNumber: Int?
        let indexNumber: Int?
        let officialRating: String?
        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", type = "Type", seriesName = "SeriesName"
            case seriesId = "SeriesId", parentIndexNumber = "ParentIndexNumber", indexNumber = "IndexNumber"
            case officialRating = "OfficialRating"
        }
    }

    /// Every query that gets locally filtered asks for `OfficialRating`
    /// EXPLICITLY rather than relying on the server's default field set.
    /// Measured on the captured fixtures of all three supported generations:
    /// `/UserItems/Resume` returns it unasked, `/Shows/NextUp` returns it on
    /// none of them, and `/Items/Latest` is covered by no fixture — so asking
    /// removes an unknown instead of shipping a filter with nothing to bite on.
    private static let ratingField = URLQueryItem(name: "fields", value: "OfficialRating")

    /// Drops what the user's parental cap hides. Applied before mapping, since
    /// `ResumeItem` carries no rating.
    private static func passingCap(_ items: [Item], _ session: Session) -> [Item] {
        items.filter { ContentRating.passes(rating: $0.officialRating, maxAge: session.maxContentAge) }
    }

    /// nil = the request failed (offline / server unreachable / auth);
    /// empty = the server answered with nothing to resume.
    static func fetchResumeItems(session: Session, limit: Int) async -> [ResumeItem]? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath("/UserItems/Resume", serverURL: session.serverURL)
        comps.queryItems = [
            URLQueryItem(name: "userId", value: session.userId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "mediaTypes", value: "Video"),
            ratingField
        ]
        return await fetchItems(comps: comps, session: session)
    }

    /// User-hearted movies/series, most recently favorited first. Same
    /// nil/empty semantics as `fetchResumeItems`.
    static func fetchFavorites(session: Session, limit: Int) async -> [ResumeItem]? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath("/Items", serverURL: session.serverURL)
        comps.queryItems = [
            URLQueryItem(name: "userId", value: session.userId),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "isFavorite", value: "true"),
            URLQueryItem(name: "sortBy", value: "DateCreated"),
            URLQueryItem(name: "sortOrder", value: "Descending"),
            URLQueryItem(name: "limit", value: String(limit)),
            ratingField
        ]
        // `/Items` is the one family the server filters itself — same split the
        // app makes. The local filter below still runs: belt and braces, since
        // whether an endpoint honours the parameter is not observable from here.
        if let code = ContentRating.maxOfficialRatingCode(forAge: session.maxContentAge) {
            comps.queryItems?.append(URLQueryItem(name: "maxOfficialRating", value: code))
        }
        return await fetchItems(comps: comps, session: session)
    }

    /// Global "Next Up" — the next unwatched episode across in-progress series
    /// (the app's Home "Next Up" rail). `/Shows/NextUp` answers with the same
    /// `{Items:[]}` envelope, so it reuses `fetchItems`. Same nil/empty
    /// semantics as `fetchResumeItems`.
    static func fetchNextUp(session: Session, limit: Int) async -> [ResumeItem]? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath("/Shows/NextUp", serverURL: session.serverURL)
        comps.queryItems = [
            URLQueryItem(name: "userId", value: session.userId),
            URLQueryItem(name: "limit", value: String(limit)),
            ratingField
        ]
        return await fetchItems(comps: comps, session: session)
    }

    /// Recently added movies/series, newest first (the app's Home "Recently
    /// Added" row). `/Items/Latest` answers with a bare JSON array — NOT the
    /// `{Items:[]}` envelope the other endpoints use — so it needs its own
    /// decode. Same nil/empty semantics as `fetchResumeItems`.
    static func fetchRecentlyAdded(session: Session, limit: Int) async -> [ResumeItem]? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath("/Items/Latest", serverURL: session.serverURL)
        comps.queryItems = [
            URLQueryItem(name: "userId", value: session.userId),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "limit", value: String(limit)),
            ratingField
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await Self.session.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return nil }
        return passingCap(decoded, session).map(makeResumeItem)
    }

    /// Shows that just received episodes, most recent first.
    ///
    /// Mirrors the app's `getSeriesWithRecentEpisodes`. `/Items/Latest` over
    /// episodes with grouping ON: the server replaces each episode by its
    /// series, which is what lets a long-owned show resurface when a new season
    /// lands — `fetchRecentlyAdded` alone can't, since it filters episodes out
    /// and a series carries its own (old) creation date.
    ///
    /// Filtered to `Series` because a server that ignores `groupItems` would
    /// otherwise put episode stills in a poster grid.
    static func fetchSeriesWithRecentEpisodes(session: Session, limit: Int) async -> [ResumeItem]? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath("/Items/Latest", serverURL: session.serverURL)
        comps.queryItems = [
            URLQueryItem(name: "userId", value: session.userId),
            URLQueryItem(name: "includeItemTypes", value: "Episode"),
            URLQueryItem(name: "groupItems", value: "true"),
            URLQueryItem(name: "limit", value: String(limit)),
            ratingField
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await Self.session.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return nil }
        return passingCap(decoded.filter { $0.type == "Series" }, session).map(makeResumeItem)
    }

    private static func fetchItems(comps: URLComponents, session: Session) async -> [ResumeItem]? {
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await Self.session.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode(ItemsResponse.self, from: data) else { return nil }
        return passingCap(decoded.items, session).map(makeResumeItem)
    }

    /// Maps a decoded Jellyfin item to a widget poster entry. Episodes show the
    /// parent series title + `SxxExx` and use the series poster so the grid
    /// stays poster-shaped.
    private static func makeResumeItem(_ item: Item) -> ResumeItem {
        let isEpisode = item.seriesName != nil
        let title = isEpisode ? (item.seriesName ?? "") : (item.name ?? "")
        let subtitle: String? = {
            guard isEpisode else { return nil }
            if let s = item.parentIndexNumber, let e = item.indexNumber {
                return String(format: "S%02d:E%02d", s, e)
            }
            return item.name
        }()
        return ResumeItem(
            id: item.id,
            title: title,
            subtitle: subtitle,
            posterItemId: item.seriesId ?? item.id
        )
    }

    /// Token-free poster URL — auth is carried by the `Authorization` header in
    /// `fetchImage`, which the widget always fetches through (unlike Top Shelf,
    /// where the SYSTEM loads the URL and header auth is impossible). Mirrors
    /// the app's `ImageURLBuilder` + `AuthenticatedImageFetch` split.
    static func posterURL(session: Session, itemId: String, maxWidth: Int) -> URL? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath("/Items/\(itemId)/Images/Primary", serverURL: session.serverURL)
        comps.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "85")
        ]
        return comps.url
    }

    static func fetchImage(_ url: URL?, token: String) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await Self.session.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              !data.isEmpty else { return nil }
        return data
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
