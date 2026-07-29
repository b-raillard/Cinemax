#if os(iOS)
import AppIntents
import Foundation
import CinemaxKit
@preconcurrency import JellyfinAPI

/// A library item as Siri and the Shortcuts editor see it.
///
/// Deliberately flat and self-contained: whatever App Intents persists in a
/// saved shortcut has to survive without the app running, so the entity carries
/// only display text plus the composite identity needed to re-resolve it.
struct MediaItemEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: LocalizedStringResource("intent.entity.mediaItem"))
    }

    static let defaultQuery = MediaItemQuery()

    /// `MediaEntityID.rawValue` — composite (server, item).
    let id: String
    let title: String
    let subtitle: String?
    /// Lets `PlayNextEpisodeIntent` refuse a movie without a second round-trip.
    let isEpisodic: Bool

    var displayRepresentation: DisplayRepresentation {
        guard let subtitle else {
            return DisplayRepresentation(title: "\(title)")
        }
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    /// The parsed identity, or `nil` if the stored raw value is malformed.
    var entityID: MediaEntityID? { MediaEntityID(rawValue: id) }
}

extension MediaItemEntity {

    /// Builds an entity from a server item.
    ///
    /// Returns `nil` when the item id isn't a shape we can round-trip, so we
    /// never mint an identity that `MediaEntityID(rawValue:)` would later
    /// reject — that asymmetry would show up as a shortcut that saves fine and
    /// then silently stops resolving.
    init?(item: BaseItemDto, serverId: String) {
        guard let itemId = item.id, AppState.isValidItemId(itemId) else { return nil }
        guard let name = item.name, !name.isEmpty else { return nil }

        self.id = MediaEntityID(serverId: serverId, itemId: itemId).rawValue
        self.title = name
        self.subtitle = Self.subtitle(for: item)
        self.isEpisodic = item.type == .series || item.type == .episode || item.type == .season
    }

    /// Enough context to tell two similarly-named rows apart in a picker:
    /// the series and episode number for an episode, the year otherwise.
    private static func subtitle(for item: BaseItemDto) -> String? {
        if item.type == .episode {
            var parts: [String] = []
            if let series = item.seriesName, !series.isEmpty { parts.append(series) }
            if let season = item.parentIndexNumber, let episode = item.indexNumber {
                parts.append(String(format: "S%02dE%02d", season, episode))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        if let year = item.productionYear { return String(year) }
        return nil
    }
}
#endif
