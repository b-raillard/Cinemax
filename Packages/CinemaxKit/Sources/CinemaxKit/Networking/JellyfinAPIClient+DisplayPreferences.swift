import Foundation
import JellyfinAPI

extension JellyfinAPIClient: UserPreferencesAPI {
    public func getDisplayPreferences(id: String, client: String, userId: String?) async throws -> DisplayPreferencesDto {
        guard let jf = getClient() else { throw JellyfinError.notConnected }
        do {
            return try await jf.send(Paths.getDisplayPreferences(displayPreferencesID: id, userID: userId, client: client)).value
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
