import Foundation

public struct ServerInfo: Sendable, Codable {
    public let name: String
    public let serverID: String
    public let version: String
    public let url: URL

    public init(name: String, serverID: String, version: String, url: URL) {
        self.name = name
        self.serverID = serverID
        self.version = version
        self.url = url
    }
}
