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
        imageURLRaw(itemId: itemId, imageTypeRaw: imageType.rawValue, maxWidth: maxWidth)
    }

    /// Raw-string overload for admin-only image types (Disc, Art, BoxRear,
    /// Screenshot, Menu, Chapter, Profile) that fall outside the narrower
    /// `CinemaxKit.ImageType`. Admin screens build URLs directly via this;
    /// standard media surfaces keep using the typed overload.
    public func imageURLRaw(itemId: String, imageTypeRaw: String, maxWidth: Int? = nil) -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        components.path = "/Items/\(itemId)/Images/\(imageTypeRaw)"

        var queryItems: [URLQueryItem] = []
        if let maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        queryItems.append(URLQueryItem(name: "quality", value: "90"))
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        return components.url ?? serverURL
    }

    /// Returns `maxWidth` based on the device's native screen width in pixels.
    /// Falls back to 1920 when UIKit is unavailable or no scene is active.
    @MainActor
    public static var screenPixelWidth: Int {
        #if canImport(UIKit)
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = windowScenes.first(where: { $0.activationState == .foregroundActive })
            ?? windowScenes.first
        guard let screen = scene?.screen else { return 1920 }
        return Int(screen.bounds.width * screen.scale)
        #else
        1920
        #endif
    }

    /// Builds the URL for a chapter thumbnail. Jellyfin exposes chapter images at
    /// `/Items/{id}/Images/Chapter/{index}` (0-based index into the chapter list).
    public func chapterImageURL(itemId: String, imageIndex: Int, tag: String? = nil, maxWidth: Int? = nil) -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        components.path = "/Items/\(itemId)/Images/Chapter/\(imageIndex)"

        var queryItems: [URLQueryItem] = []
        if let maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let tag {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        queryItems.append(URLQueryItem(name: "quality", value: "85"))
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        return components.url ?? serverURL
    }

    public func userImageURL(userId: String, tag: String? = nil, maxWidth: Int? = nil) -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
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

        return components.url ?? serverURL
    }
}
