import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Poster card with a navigation link into `MediaDetailScreen`, used by
/// `LibraryGenreRow` and by the filtered grids in `MediaLibraryScreen`.
/// Subtitle composition differs by `itemType` (series show season counts,
/// movies show community rating).
///
/// Admin overlay (iOS): when `appState.isAdministrator` is true the image
/// carries a small blur-circle ellipsis at the bottom-right that opens the
/// shared `AdminItemMenu` (Identifier / Edit metadata / Refresh / Delete).
/// The admin menu is a `ZStack` sibling of the image `NavigationLink`, not
/// nested inside its label — taps on the ellipsis hit the Menu, taps on the
/// rest of the poster hit the link. The title/subtitle row is plain text —
/// not a separate focusable target — so tvOS focus moves directly between
/// posters without an extra step landing on the label.
struct LibraryPosterCard: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc

    let item: BaseItemDto
    let itemType: BaseItemKind
    #if os(iOS)
    /// Caller-provided hook for the admin 3-dot menu's destination
    /// selection. The card is rendered inside a lazy grid/row, so the
    /// matching `navigationDestination(item:)` MUST live on a non-lazy
    /// ancestor — the screen body. This callback bubbles the
    /// `(item, destination)` pair up; the screen stores it in a
    /// `@State AdminMenuPushIntent?` and hosts the destination there.
    var onAdminAction: ((BaseItemDto, AdminItemMenu.Destination) -> Void)? = nil
    #endif

    var body: some View {
        let subtitle = subtitleText
        let destination: URL? = item.id.map {
            appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300)
        }

        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            ZStack(alignment: .bottomTrailing) {
                NavigationLink {
                    if let id = item.id {
                        MediaDetailScreen(itemId: id, itemType: itemType)
                    }
                } label: {
                    Color.clear
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            CinemaLazyImage(url: destination, fallbackIcon: "film")
                        }
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                        .cinemaFocus()
                }
                #if os(tvOS)
                .buttonStyle(CinemaTVCardButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))

                #if os(iOS)
                if appState.isAdministrator {
                    AdminItemMenu(
                        item: item,
                        onSelectDestination: { dest in
                            onAdminAction?(item, dest)
                        }
                    )
                    .background(Circle().fill(.ultraThinMaterial))
                    .padding(CinemaSpacing.spacing2)
                }
                #endif
            }

            titleRows(subtitle: subtitle)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func titleRows(subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Text("M\nM")
                .font(CinemaFont.label(.large))
                .lineLimit(2)
                .hidden()
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    Text(item.name ?? "")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(2)
                }

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.outline)
                    .lineLimit(1)
            }
        }
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
