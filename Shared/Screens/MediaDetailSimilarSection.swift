import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - Similar Items Section

/// "More like this" horizontal carousel. Equatable so non-similar mutations
/// on the parent view model don't re-render this row.
struct MediaDetailSimilarSection: View, Equatable {
    let items: [BaseItemDto]
    let cardWidth: CGFloat
    /// Custom row title — the collection row ("Part of: …") reuses this whole
    /// section with its own header; nil keeps the "More like this" default.
    var titleOverride: String? = nil

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // SwiftUI calls `==` on the main actor during view diffing —
        // `assumeIsolated` lets us read the non-Sendable `BaseItemDto`
        // payload without a `nonisolated`-context warning.
        MainActor.assumeIsolated {
            guard lhs.cardWidth == rhs.cardWidth,
                  lhs.titleOverride == rhs.titleOverride,
                  lhs.items.count == rhs.items.count else { return false }
            for (a, b) in zip(lhs.items, rhs.items) {
                if a.id != b.id || a.name != b.name || a.productionYear != b.productionYear { return false }
            }
            return true
        }
    }

    var body: some View {
        ContentRow(
            title: titleOverride ?? loc.localized("detail.moreLikeThis"),
            data: items,
            id: \.id
        ) { item in
            NavigationLink {
                if let id = item.id {
                    MediaDetailScreen(
                        itemId: id,
                        itemType: item.type ?? .movie
                    )
                }
            } label: {
                PosterCard(
                    title: item.name ?? "",
                    imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) },
                    subtitle: item.productionYear.map(String.init)
                )
                .frame(width: cardWidth)
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel([item.name, item.productionYear.map(String.init)].compactMap { $0 }.joined(separator: ", "))
        }
    }
}
