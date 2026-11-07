import Foundation
import JellyfinAPI

extension JellyfinAPIClient: UserPreferencesAPI {
    /// Read through `DisplayPreferencesDecoding`, never the SDK's own decoding:
    /// a real server's body does not fit the SDK's type (see there).
    public func getDisplayPreferences(id: String, client: String, userId: String?) async throws -> DisplayPreferencesDto {
        guard let jf = getClient() else { throw JellyfinError.notConnected }
        do {
            let response = try await jf.data(for: Paths.getDisplayPreferences(displayPreferencesID: id, userID: userId, client: client))
            return try DisplayPreferencesDecoding.decode(response.data)
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    public func updateDisplayPreferences(_ prefs: DisplayPreferencesDto, id: String, client: String, userId: String?) async throws {
        guard let jf = getClient() else { throw JellyfinError.notConnected }
        do {
            _ = try await jf.send(Paths.updateDisplayPreferences(displayPreferencesID: id, userID: userId, client: client, prefs))
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }
}

/// A DisplayPreferences body as servers send it. Jellyfin injects legacy keys
/// into the `CustomPrefs` of EVERY entity, two of them `null` (`tvhome`,
/// `dashboardTheme` — body measured on 10.11.0 on 2026-11-07, and the same
/// read failure logged against a 12.2.0 server); the SDK
/// types `customPrefs` as `[String: String]`, which cannot hold a `null`, so
/// its decoding threw and no preference was ever read. The `null` values are
/// dropped before decoding: a write omits them, and Jellyfin resets an omitted
/// legacy key itself — scoped to the entity written (spec, Spike findings 8).
enum DisplayPreferencesDecoding {
    static func decode(_ data: Data) throws -> DisplayPreferencesDto {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a JSON object"))
        }
        if let prefs = object["CustomPrefs"] as? [String: Any] {
            object["CustomPrefs"] = prefs.filter { !($0.value is NSNull) }
        }
        return try JSONDecoder().decode(DisplayPreferencesDto.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
