#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Results pane of the Identify wizard. `LazyVGrid` of poster tiles — matches
/// Jellyfin iOS's "Résultats de la recherche" layout. Tapping a tile fires
/// `onSelect` so the host can transition to the confirm step.
///
/// Empty results render a neutral "no match" notice rather than leaving the
/// pane blank — admins often need a cue that the form ran but returned nothing.
struct IdentifyResultsGridView: View {
    let results: [RemoteSearchResult]
    let onSelect: (RemoteSearchResult) -> Void

    @Environment(LocalizationManager.self) private var loc
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 4 : 3
        return Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing3), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            Text(loc.localized("admin.identify.results"))
                .font(CinemaFont.headline(.medium))
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.horizontal, CinemaSpacing.spacing3)

            if results.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: loc.localized("admin.identify.noResults.title"),
                    subtitle: loc.localized("admin.identify.noResults.subtitle")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, CinemaSpacing.spacing6)
            } else {
                LazyVGrid(columns: columns, spacing: CinemaSpacing.spacing4) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        Button {
                            onSelect(result)
                        } label: {
                            tile(result)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
            }
        }
    }

    @ViewBuilder
    private func tile(_ result: RemoteSearchResult) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            poster(result)
            Text(result.name ?? "—")
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurface)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            if let provider = result.searchProviderName {
                Text(provider)
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
            }
            if let year = result.productionYear {
                Text(String(year))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.outline)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func poster(_ result: RemoteSearchResult) -> some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let raw = result.imageURL, let url = URL(string: raw) {
                    CinemaLazyImage(url: url, fallbackIcon: "photo")
                } else {
                    ZStack {
                        CinemaColor.surfaceContainerHigh
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
            .clipped()
    }
}
#endif
