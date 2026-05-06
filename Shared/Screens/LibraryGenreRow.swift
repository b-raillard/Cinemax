import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Horizontally-scrolling row of posters for a single genre, with a
/// "See all" affordance that should pin the catalogue to that genre.
/// Caller owns the `onViewAll` closure so the view is agnostic about where
/// the filter state lives.
struct LibraryGenreRow: View {
    let genre: String
    let items: [BaseItemDto]
    let itemType: BaseItemKind
    let onViewAll: () -> Void
    #if os(iOS)
    /// Forwarded to each `LibraryPosterCard` in the row. The row itself
    /// is rendered inside `ContentRow`'s `LazyHStack`, so it cannot host
    /// `navigationDestination(item:)` either. See `AdminItemMenu` for
    /// the contract.
    var onAdminAction: ((BaseItemDto, AdminItemMenu.Destination) -> Void)? = nil
    #endif

    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        ContentRow(
            title: genre,
            showViewAll: true,
            onViewAll: onViewAll,
            data: items,
            id: \.id
        ) { item in
            #if os(iOS)
            LibraryPosterCard(item: item, itemType: itemType, onAdminAction: onAdminAction)
                .frame(width: posterCardWidth)
            #else
            LibraryPosterCard(item: item, itemType: itemType)
                .frame(width: posterCardWidth)
            #endif
        }
    }

    private var posterCardWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        AdaptiveLayout.posterCardWidth(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }
}
