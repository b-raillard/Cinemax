import Foundation

public enum ImageType: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case thumb = "Thumb"
    case logo = "Logo"
    case banner = "Banner"
}

public struct ImageURLBuilder: Sendable {
    private let serverURL: URL

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    public func imageURL(itemId: String, imageType: ImageType, maxWidth: Int? = nil) -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.path = "/Items/\(itemId)/Images/\(imageType.rawValue)"

        var queryItems: [URLQueryItem] = []
        if let maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        queryItems.append(URLQueryItem(name: "quality", value: "90"))
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        return components.url!
    }
}
