import Foundation

public struct UserSession: Sendable, Codable {
    public let userID: String
    public let username: String
    public let accessToken: String
    public let serverID: String

    public init(userID: String, username: String, accessToken: String, serverID: String) {
        self.userID = userID
        self.username = username
        self.accessToken = accessToken
        self.serverID = serverID
    }
}
