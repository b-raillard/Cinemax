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
        /// The approved certificate of a self-signed server, or `nil`. Optional
        /// for the same reason — keep in sync with `ExtensionSessionBridge.Session`.
        /// In a session returned by `dialing(_:)`, the pin of the address dialled.
        let pinnedCertificateSHA256: String?
        /// The server's LAN address, its Jellyfin `Id` and the LAN certificate's
        /// pin — what `dialing(_:)` probes. Optional for the same reason; keep
        /// the three names in sync with `ExtensionSessionBridge.Session`.
        let localServerURL: URL?
        let serverID: String?
        let localPinnedCertificateSHA256: String?
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
        // No session delegate: every request carries its own `ExtensionServerTrust`
        // through `send(_:session:)`, built from the pin of the session it
        // serves (see there).
        return URLSession(configuration: config)
    }()

    /// Every request goes through here: the task delegate honours the
    /// certificate the user approved in the app for THIS session's address —
    /// the LAN pin on the LAN host:port once `dialing(_:)` chose the LAN, the
    /// public pin otherwise. Bound per request rather than read from shared
    /// state, so two timelines dialling different roads can never cross pins
    /// (a per-task delegate receives the server-trust challenge — checked).
    private static func send(_ request: URLRequest, session: Session) async throws -> (Data, URLResponse) {
        let pin = ExtensionServerTrust.pin(serverURL: session.serverURL, fingerprint: session.pinnedCertificateSHA256)
        return try await Self.session.data(for: request, delegate: ExtensionServerTrust { pin })
    }

    /// A copy of `stored` whose `serverURL` is the address to dial — the LAN
    /// one when `ExtensionServerRoute`'s probe proves it is this server over a
    /// local connection, the public one otherwise — with the pin that goes
    /// with it. Every fetch derives from `session.serverURL`, so resolving
    /// once per timeline routes them all.
    static func dialing(_ stored: Session) async -> Session {
        let dial = await ExtensionServerRoute.dialURL(
            publicURL: stored.serverURL,
            localURL: stored.localServerURL,
            serverID: stored.serverID,
            localPin: stored.localPinnedCertificateSHA256
        )
        let endpoint = ExtensionServerRoute.endpoint(
            publicURL: stored.serverURL,
            publicPin: stored.pinnedCertificateSHA256,
            dialURL: dial,
            localPin: stored.localPinnedCertificateSHA256
        )
        return Session(
            serverURL: endpoint.serverURL,
            accessToken: stored.accessToken,
            userId: stored.userId,
            maxContentAge: stored.maxContentAge,
            pinnedCertificateSHA256: endpoint.pinnedCertificateSHA256,
            localServerURL: stored.localServerURL,
            serverID: stored.serverID,
            localPinnedCertificateSHA256: stored.localPinnedCertificateSHA256
        )
    }

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
        items.filter { ContentRatingClassifier.passes(rating: $0.officialRating, maxAge: session.maxContentAge ?? 0) }
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
        if let code = ContentRatingClassifier.maxOfficialRatingCode(forAge: session.maxContentAge ?? 0) {
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
        guard let server = await get(Envelope<Item>.self, comps: comps, session: session)?.items else { return nil }
        // The app's own reading of « À suivre » (`correctedNextUp` below), so
        // the widget names the same episodes as Home's rail.
        let rail = await correctedNextUp(passingCap(server, session), session: session, limit: limit)
        return rail.map(makeResumeItem)
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
        guard let (data, resp) = try? await Self.send(request, session: session),
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
        guard let (data, resp) = try? await Self.send(request, session: session),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return nil }
        return passingCap(decoded.filter { $0.type == "Series" }, session).map(makeResumeItem)
    }

    private static func fetchItems(comps: URLComponents, session: Session) async -> [ResumeItem]? {
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await Self.send(request, session: session),
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

    static func fetchImage(_ url: URL?, session: Session) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await Self.send(request, session: session),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              !data.isEmpty else { return nil }
        return data
    }
}

// MARK: - « À suivre » as the app reads it

/// A copy of CinemaxKit's `NextUpCorrection` + `NextUpHiddenList` (this
/// extension cannot link the package — keep the two in step): the episode
/// after the one watched most RECENTLY wins over the server's answer, and a
/// series removed from « À suivre » stays out until its next-up episode
/// changes. Every lookup that fails leaves the server's rail as it is.
extension JellyfinLite {
    private struct Envelope<Element: Decodable>: Decodable {
        let items: [Element]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    private struct PlayedEpisode: Decodable {
        struct UserData: Decodable {
            let lastPlayedDate: String?
            enum CodingKeys: String, CodingKey { case lastPlayedDate = "LastPlayedDate" }
        }
        let id: String
        let seriesId: String?
        let userData: UserData?
        enum CodingKeys: String, CodingKey { case id = "Id", seriesId = "SeriesId", userData = "UserData" }
    }

    private struct ChainEpisode: Decodable {
        let id: String
        let season: Int?
        let locationType: String?
        enum CodingKeys: String, CodingKey { case id = "Id", season = "ParentIndexNumber", locationType = "LocationType" }
    }

    private struct Preferences: Decodable {
        let customPrefs: [String: String?]?
        enum CodingKeys: String, CodingKey { case customPrefs = "CustomPrefs" }
    }

    private static func get<Body: Decodable>(_ type: Body.Type, comps: URLComponents, session: Session) async -> Body? {
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("MediaBrowser Token=\(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await Self.send(request, session: session),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func components(_ endpoint: String, _ query: [String: String], session: Session) -> URLComponents? {
        guard var comps = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = endpointPath(endpoint, serverURL: session.serverURL)
        comps.queryItems = [URLQueryItem(name: "userId", value: session.userId)]
            + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps
    }

    /// (series id, last played episode id), most recent play first, one per
    /// series, 30 days back, 12 series at most.
    private static func lastPlays(session: Session) async -> [(seriesId: String, episodeId: String)] {
        guard let comps = components("/Items", [
            "recursive": "true", "includeItemTypes": "Episode", "filters": "IsPlayed",
            "sortBy": "DatePlayed,ParentIndexNumber,IndexNumber",
            "sortOrder": "Descending,Descending,Descending",
            "limit": "100", "enableUserData": "true", "enableImages": "false"
        ], session: session),
              let plays = await get(Envelope<PlayedEpisode>.self, comps: comps, session: session)?.items else { return [] }
        // Jellyfin's dates are UTC ISO-8601: they compare as text.
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 24 * 3600))
        var seen = Set<String>()
        var result: [(seriesId: String, episodeId: String)] = []
        for play in plays {
            guard let seriesId = play.seriesId, let date = play.userData?.lastPlayedDate, date >= cutoff,
                  seen.insert(seriesId).inserted else { continue }
            result.append((seriesId, play.id))
            if result.count == 12 { break }
        }
        return result
    }

    /// The episode after `episodeId` in the series' regular seasons.
    private static func successor(of episodeId: String, seriesId: String, session: Session) async -> String? {
        guard let comps = components("/Shows/\(seriesId)/Episodes", [
            "enableUserData": "false", "enableImages": "false"
        ], session: session),
              let all = await get(Envelope<ChainEpisode>.self, comps: comps, session: session)?.items else { return nil }
        let chain = all.enumerated()
            .filter { $0.element.locationType != "Virtual" && $0.element.season != 0 }
            .sorted { lhs, rhs in
                let left = lhs.element.season ?? .max
                let right = rhs.element.season ?? .max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element.id)
        guard let index = chain.firstIndex(of: episodeId), index + 1 < chain.count else { return nil }
        return chain[index + 1]
    }

    /// Series id → the next-up episode the user removed from « À suivre ».
    private static func hiddenNextUp(session: Session) async -> [String: String] {
        guard let comps = components("/DisplayPreferences/jellyglass-nextup", ["client": "jellyglass"], session: session),
              let prefs = await get(Preferences.self, comps: comps, session: session)?.customPrefs,
              let stored = prefs["hidden"].flatMap({ $0 }),
              let pairs = try? JSONDecoder().decode([[String]].self, from: Data(stored.utf8)) else { return [:] }
        var hidden: [String: String] = [:]
        for pair in pairs where pair.count == 2 { hidden[pair[0]] = pair[1] }
        return hidden
    }

    private static func correctedNextUp(_ server: [Item], session: Session, limit: Int) async -> [Item] {
        async let hiddenTask = hiddenNextUp(session: session)
        let plays = await lastPlays(session: session)
        let successors = await withTaskGroup(of: (String, String?).self) { group in
            for play in plays {
                group.addTask { (play.seriesId, await successor(of: play.episodeId, seriesId: play.seriesId, session: session)) }
            }
            var found: [String: String] = [:]
            for await (seriesId, next) in group {
                if let next { found[seriesId] = next }
            }
            return found
        }
        let serverNextUp = Dictionary(server.compactMap { item in item.seriesId.map { ($0, item.id) } }) { first, _ in first }
        let wanted = plays.compactMap { play -> String? in
            guard let next = successors[play.seriesId], serverNextUp[play.seriesId] != next else { return nil }
            return next
        }

        var rail = server
        if !wanted.isEmpty,
           var comps = components("/Items", ["ids": wanted.joined(separator: ","), "enableUserData": "false"], session: session) {
            comps.queryItems?.append(ratingField)
            if let fetched = await get(Envelope<Item>.self, comps: comps, session: session)?.items {
                let corrected = wanted.compactMap { id in fetched.first { $0.id == id } }
                let replaced = Set(corrected.compactMap(\.seriesId))
                rail = passingCap(corrected, session) + server.filter { item in
                    !(item.seriesId.map(replaced.contains) ?? false)
                }
            }
        }
        let hidden = await hiddenTask
        return Array(rail.filter { item in item.seriesId.map { hidden[$0] == item.id } != true }.prefix(limit))
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
