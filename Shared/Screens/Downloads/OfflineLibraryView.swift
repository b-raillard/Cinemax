#if os(iOS)
import SwiftUI
import CinemaxKit

/// Drop-in replacement for the Home / Movies / TV-Shows tabs when the device
/// is offline. Renders a banner + a grid of completed downloads scoped to
/// what the tab would normally show.
///
/// Each card navigates back through `MediaDetailScreen` — that screen's own
/// offline shortcut (`OfflineMediaDetailView`) handles the rendering, so we
/// stay on the established navigation contract instead of inventing a
/// parallel one.
struct OfflineLibraryView: View {
    enum Scope {
        case all      // Home tab
        case movies   // Movies tab
        case series   // TV Shows tab
    }

    @Environment(DownloadManager.self) private var downloads
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState

    let scope: Scope

    var body: some View {
        let completed = downloads.completedItems()
        let movies = (scope == .series) ? [] : completed.movies
        let series = (scope == .movies) ? [] : completed.series

        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if movies.isEmpty && series.isEmpty {
                ScrollView {
                    VStack(spacing: CinemaSpacing.spacing4) {
                        offlineBanner
                        EmptyStateView(
                            systemImage: "wifi.slash",
                            title: loc.localized("offline.empty.title"),
                            subtitle: loc.localized("offline.empty.subtitle")
                        )
                    }
                    .padding(.top, CinemaSpacing.spacing3)
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                        offlineBanner

                        if !movies.isEmpty {
                            sectionGrid(title: loc.localized("downloads.section.movies"), entries: movies)
                        }
                        if !series.isEmpty {
                            ForEach(series, id: \.seriesId) { bucket in
                                sectionGrid(
                                    title: bucket.title,
                                    entries: bucket.episodes
                                )
                            }
                        }
                    }
                    .padding(.horizontal, CinemaSpacing.spacing3)
                    .padding(.bottom, CinemaSpacing.spacing8)
                }
            }
        }
    }

    // MARK: - Pieces

    private var offlineBanner: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            Image(systemName: "wifi.slash")
                .font(.system(size: CinemaScale.pt(14), weight: .semibold))
            Text(loc.localized("offline.banner"))
                .font(CinemaFont.label(.medium))
            Spacer()
        }
        .foregroundStyle(themeManager.accent)
        .padding(.horizontal, CinemaSpacing.spacing3)
        .padding(.vertical, CinemaSpacing.spacing2)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
        .padding(.horizontal, CinemaSpacing.spacing2)
    }

    private func sectionGrid(title: String, entries: [DownloadItem]) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            iOSSettingsSectionHeader(title)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: 12)],
                spacing: CinemaSpacing.spacing3
            ) {
                ForEach(entries) { entry in
                    posterCard(for: entry)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing2)
        }
    }

    @ViewBuilder
    private func posterCard(for entry: DownloadItem) -> some View {
        let posterId = entry.kind == .episode ? (entry.seriesId ?? entry.id) : entry.id
        NavigationLink {
            // Routing through MediaDetailScreen so that any subsequent navigation
            // (back to Home etc.) lands in the same place online users expect.
            MediaDetailScreen(itemId: entry.kind == .episode ? (entry.seriesId ?? entry.id) : entry.id,
                              itemType: entry.kind == .episode ? .series : .movie)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(2/3, contentMode: .fit)
                    .overlay {
                        CinemaLazyImage(
                            url: downloads.localPosterURL(forItemId: entry.id)
                                ?? appState.imageBuilder.imageURL(itemId: posterId, imageType: .primary, maxWidth: 360),
                            fallbackIcon: entry.kind == .movie ? "film" : "tv",
                            fallbackBackground: CinemaColor.surfaceContainerHigh
                        )
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: CinemaScale.pt(16), weight: .bold))
                            .foregroundStyle(.white, themeManager.accent)
                            .padding(6)
                    }

                Text(displayTitle(for: entry))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func displayTitle(for entry: DownloadItem) -> String {
        switch entry.kind {
        case .movie: return entry.title
        case .episode: return entry.seriesTitle ?? entry.title
        }
    }
}
#endif
