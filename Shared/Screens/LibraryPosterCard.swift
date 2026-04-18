import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Poster card with a navigation link into `MediaDetailScreen`, used by
/// `LibraryGenreRow` and by the filtered grids in `MediaLibraryScreen`.
/// Subtitle composition differs by `itemType` (series show season counts,
/// movies show community rating).
struct LibraryPosterCard: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc

    let item: BaseItemDto
    let itemType: BaseItemKind

    var body: some View {
        let subtitle = subtitleText

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: itemType)
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300) },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if itemType == .series {
            if let count = item.childCount {
                parts.append(loc.localized(count == 1 ? "tvShows.season" : "tvShows.seasonsPlural", count))
            }
        } else {
            if let rating = item.communityRating {
                parts.append(String(format: "%.1f", rating))
            }
        }
        return parts.joined(separator: " · ")
    }
}
