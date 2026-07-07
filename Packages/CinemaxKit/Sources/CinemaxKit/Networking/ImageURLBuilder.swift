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

    /// - Parameter tag: the server's image tag (e.g. `item.imageTags["Primary"]`).
    ///   Passing it appends `&tag=` so the URL changes whenever the underlying
    ///   image does — without it the URL is identical across edits and Nuke
    ///   serves a stale poster/backdrop until the app is reinstalled.
    public func imageURL(itemId: String, imageType: ImageType, maxWidth: Int? = nil, tag: String? = nil) -> URL {
        imageURLRaw(itemId: itemId, imageTypeRaw: imageType.rawValue, maxWidth: maxWidth, tag: tag)
    }

    /// Raw-string overload for admin-only image types (Disc, Art, BoxRear,
    /// Screenshot, Menu, Chapter, Profile) that fall outside the narrower
    /// `CinemaxKit.ImageType`. Admin screens build URLs directly via this;
    /// standard media surfaces keep using the typed overload.
    public func imageURLRaw(itemId: String, imageTypeRaw: String, maxWidth: Int? = nil, tag: String? = nil) -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        components.setEndpointPath("/Items/\(itemId)/Images/\(imageTypeRaw)", preservingBasePathOf: serverURL)

        var queryItems: [URLQueryItem] = []
        if let maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let tag, !tag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
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

    /// Pixel width for full-bleed hero backdrops. Capped at 1920 because the
    /// hero sits behind a dark gradient scrim — higher-resolution frames are
    /// invisible but the bytes (and decode memory) are real. Use for hero /
    /// detail / library-hero backdrops, not for foreground imagery.
    @MainActor
    public static var backdropPixelWidth: Int {
        min(screenPixelWidth, 1920)
    }

    /// Builds the URL for a chapter thumbnail. Jellyfin exposes chapter images at
    /// `/Items/{id}/Images/Chapter/{index}` (0-based index into the chapter list).
    public func chapterImageURL(itemId: String, imageIndex: Int, tag: String? = nil, maxWidth: Int? = nil) -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        components.setEndpointPath("/Items/\(itemId)/Images/Chapter/\(imageIndex)", preservingBasePathOf: serverURL)

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

    /// Builds the URL for a trickplay tile sheet — a JPEG grid of scrub-preview
    /// thumbnails at `/Videos/{itemId}/Trickplay/{width}/{index}.jpg`. The
    /// manifest (`BaseItemDto.trickplay`) describes the grid geometry; tiles
    /// are deliberately tag-less (regenerating trickplay changes the manifest,
    /// and the player re-fetches per session anyway).
    public func trickplayTileURL(itemId: String, width: Int, index: Int, mediaSourceId: String? = nil) -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        components.setEndpointPath("/Videos/\(itemId)/Trickplay/\(width)/\(index).jpg", preservingBasePathOf: serverURL)
        if let mediaSourceId, !mediaSourceId.isEmpty {
            components.queryItems = [URLQueryItem(name: "mediaSourceId", value: mediaSourceId)]
        }
        return components.url ?? serverURL
    }

    public func userImageURL(userId: String, tag: String? = nil, maxWidth: Int? = nil) -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        components.setEndpointPath("/Users/\(userId)/Images/Primary", preservingBasePathOf: serverURL)

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
