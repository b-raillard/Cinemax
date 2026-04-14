import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

    /// Returns `maxWidth` based on the device's native screen width in pixels.
    /// Falls back to 1920 when UIKit is unavailable.
    @MainActor
    public static var screenPixelWidth: Int {
        #if canImport(UIKit)
        Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        #else
        1920
        #endif
    }

    public func userImageURL(userId: String, tag: String? = nil, maxWidth: Int? = nil) -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.path = "/Users/\(userId)/Images/Primary"

        var queryItems: [URLQueryItem] = []
        if let maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let tag {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        queryItems.append(URLQueryItem(name: "quality", value: "90"))
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        return components.url!
    }
}
