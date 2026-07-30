import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - Extras Section (bonus content)

/// "Bonus" carousel — deleted scenes, making-of, featurettes served by
/// `/Items/{id}/SpecialFeatures`. These are playable items in their own right,
/// so each card is a `PlayLink` rather than a push to a detail screen: a
/// featurette has no meaningful detail page, the only thing to do with it is
/// watch it.
///
/// 16:9 cards (`WideCard`), not posters — extras are video clips and the server
/// gives them a still, not artwork.
///
/// Equatable so unrelated view-model mutations don't re-render the row.
struct MediaDetailExtrasSection: View, Equatable {
    let items: [BaseItemDto]
    let cardWidth: CGFloat

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // SwiftUI diffs on the main actor; `assumeIsolated` lets us read the
        // non-Sendable `BaseItemDto` payload without a nonisolated warning.
        MainActor.assumeIsolated {
            guard lhs.cardWidth == rhs.cardWidth,
                  lhs.items.count == rhs.items.count else { return false }
            for (a, b) in zip(lhs.items, rhs.items) {
                if a.id != b.id || a.name != b.name { return false }
            }
            return true
        }
    }

    var body: some View {
        ContentRow(
            title: loc.localized("detail.extras"),
            data: items,
            id: \.id
        ) { item in
            extraCard(item)
        }
    }

    @ViewBuilder
    private func extraCard(_ item: BaseItemDto) -> some View {
        if let id = item.id {
            PlayLink(itemId: id, title: item.name ?? "") {
                WideCard(
                    title: item.name ?? "",
                    imageURL: appState.imageBuilder.imageURL(
                        itemId: id, imageType: .primary, maxWidth: 600,
                        tag: item.primaryImageTagValue
                    ),
                    subtitle: Self.runtimeLabel(for: item)
                )
                .frame(width: cardWidth)
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(item.name ?? "")
        }
    }

    /// Whole minutes, or nil when the server didn't report a runtime — a
    /// featurette with no duration shows its title alone rather than "0 min".
    private static func runtimeLabel(for item: BaseItemDto) -> String? {
        guard let ticks = item.runTimeTicks, ticks > 0 else { return nil }
        let minutes = Int((Double(ticks) / 10_000_000 / 60).rounded())
        guard minutes > 0 else { return nil }
        return "\(minutes) min"
    }
}
