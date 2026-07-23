import Foundation
import Security

// Minimal, dependency-free Jellyfin access for the widget. The extension
// deliberately does NOT link CinemaxKit (widget memory budgets are tight and
// the SDK pulls Nuke + generated entities); it reads the session snapshot the
// app publishes to the App Group (`ExtensionSessionBridge` — keep the suite /
// key / JSON shape in sync) and talks to two endpoints directly.
enum JellyfinLite {
    static let appGroupId = "group.com.cinemax.shared"
    static let sessionKey = "extension.session"

    struct Session: Codable {
        let serverURL: URL
        let accessToken: String
        let userId: String
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

    static func readSession() -> Session? {
        // Primary: the shared, device-only Keychain group the app publishes to.
        if let session = readSessionFromKeychain() { return session }
        // Fallback: the legacy plaintext App Group copy (dropped a release after
        // the Keychain migration ships).
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
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
        let seriesName: String?
        let seriesId: String?
        let parentIndexNumber: Int?
        let indexNumber: Int?
        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", seriesName = "SeriesName"
            case seriesId = "SeriesId", parentIndexNumber = "ParentIndexNumber", indexNumber = "IndexNumber"
        }
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
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        return await fetchItems(comps: comps, token: session.accessToken)
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
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        return await fetchItems(comps: comps, token: session.accessToken)
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
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        return await fetchItems(comps: comps, token: session.accessToken)
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
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return nil }
        return decoded.map(makeResumeItem)
    }

    private static func fetchItems(comps: URLComponents, token: String) async -> [ResumeItem]? {
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode(ItemsResponse.self, from: data) else { return nil }
        return decoded.items.map(makeResumeItem)
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

    static func posterURL(session: Session, itemId: String, maxWidth: Int) -> URL? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath("/Items/\(itemId)/Images/Primary", serverURL: session.serverURL)
        comps.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "85"),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        return comps.url
    }

    static func fetchImage(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
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
