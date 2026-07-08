#if os(iOS)
import SwiftUI
import CinemaxKit

/// Lightweight stand-in for `MediaDetailScreen` used when the device is
/// offline. Renders directly from the cached `DownloadItem` metadata so the
/// user can browse / replay downloaded content without any server round-trip.
///
/// Two distinct shapes:
///   - `entry.kind == .movie`     → single Play button + Remove
///   - `entry.kind == .episode`   → series header, episode list for the same
///                                  `seriesId`, per-episode Play / Remove
struct OfflineMediaDetailView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// The download record this screen represents. For a series, callers
    /// usually pass *any* episode entry from that series — the view picks
    /// up the rest via `seriesId`.
    let entry: DownloadItem

    @State private var pendingRemoval: DownloadItem?

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    header
                    if let overview = entry.overview, !overview.isEmpty {
                        Text(overview)
                            .font(CinemaFont.dynamicBody)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .padding(.horizontal, CinemaSpacing.spacing4)
                    }
                    metadataChips
                        .padding(.horizontal, CinemaSpacing.spacing4)
                    if entry.kind == .episode {
                        seriesEpisodeList
                    }
                    Spacer(minLength: 80)
                }
                .padding(.top, CinemaSpacing.spacing4)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            loc.localized("downloads.confirmRemove.title"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(loc.localized("downloads.action.remove"), role: .destructive) {
                if let p = pendingRemoval {
                    downloads.remove(p.id)
                }
                pendingRemoval = nil
                // If the removed entry is what we were displaying and no
                // other series episodes are left, pop back.
                if downloads.item(for: entry.id) == nil
                    && downloads.episodes(forSeriesId: entry.seriesId ?? "").isEmpty {
                    dismiss()
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(loc.localized("downloads.confirmRemove.message"))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            // Cover artwork — pulled from disk (Nuke) cache or the placeholder
            // when no cached image exists.
            ZStack(alignment: .bottomLeading) {
                CinemaLazyImage(
                    url: downloads.localBackdropURL(forItemId: entry.id)
                        ?? appState.imageBuilder.imageURL(
                            itemId: entry.backdropItemID ?? entry.seriesId ?? entry.id,
                            imageType: .backdrop,
                            maxWidth: ImageURLBuilder.backdropPixelWidth
                        ),
                    fallbackIcon: entry.kind == .movie ? "film" : "tv",
                    fallbackBackground: CinemaColor.surfaceContainerLow
                )
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipped()
                CinemaGradient.heroOverlay
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                    if let pill = sectionLabel {
                        Text(pill)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(themeManager.accent)
                    }
                    Text(headerTitle)
                        .font(.system(size: CinemaScale.pt(26), weight: .black))
                        .tracking(-1)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                .padding(CinemaSpacing.spacing4)
            }

            // Action row: Play + Remove.
            HStack(spacing: CinemaSpacing.spacing3) {
                PlayLink(itemId: entry.id, title: entry.title) {
                    HStack(spacing: CinemaSpacing.spacing2) {
                        Image(systemName: "play.fill")
                        Text(loc.localized("detail.play"))
                            .font(.system(size: CinemaScale.pt(18), weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CinemaSpacing.spacing2)
                    .background(themeManager.accentContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                }
                .buttonStyle(.plain)
                .frame(width: 160)

                Button {
                    pendingRemoval = entry
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                        .foregroundStyle(CinemaColor.onSurface)
                        .padding(CinemaSpacing.spacing2)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, CinemaSpacing.spacing4)

            // Resume progress from the locally-persisted offline playhead
            // (movies only — episodes show it per-row in the list below). Reads
            // the live catalog entry so it reflects the latest offline session.
            if entry.kind == .movie, let frac = downloads.item(for: entry.id)?.offlineResumeFraction {
                ProgressBarView(progress: frac, height: 3)
                    .padding(.horizontal, CinemaSpacing.spacing4)
            }
        }
    }

    private var headerTitle: String {
        switch entry.kind {
        case .movie:
            return entry.title
        case .episode:
            return entry.seriesTitle ?? entry.title
        }
    }

    private var sectionLabel: String? {
        switch entry.kind {
        case .movie: return nil
        case .episode:
            // For an episode-rooted offline view, show the season name as a
            // pill above the series title (e.g. "Season 1 · Episode 4").
            guard let season = entry.seasonName ?? entry.seasonIndex.map({ "Season \($0)" }) else { return nil }
            if let num = entry.episodeIndex {
                return "\(season) · \(loc.localized("detail.episode", num))"
            }
            return season
        }
    }

    // MARK: - Metadata chips

    private var metadataChips: some View {
        let parts = [
            entry.productionYear.map(String.init),
            entry.runtimeTicks.map { ticks in
                let minutes = ticks.jellyfinMinutes
                return minutes > 60
                    ? loc.localized("detail.runtime.hours", minutes / 60, minutes % 60)
                    : loc.localized("detail.runtime.minutes", minutes)
            },
            entry.officialRating
        ].compactMap { $0 }
        return HStack(spacing: CinemaSpacing.spacing2) {
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            if let rating = entry.communityRating {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(String(format: "%.1f", rating))
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurface)
                }
            }
            if !entry.genres.isEmpty {
                Text(entry.genres.prefix(3).joined(separator: " · "))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(themeManager.accent)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Episode list (series view)

    @ViewBuilder
    private var seriesEpisodeList: some View {
        let seriesEntries = downloads.episodes(forSeriesId: entry.seriesId ?? "")
        if !seriesEntries.isEmpty {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                iOSSettingsSectionHeader(loc.localized("downloads.section.series"))
                VStack(spacing: 0) {
                    ForEach(seriesEntries) { ep in
                        episodeRow(ep)
                        if ep != seriesEntries.last {
                            iOSSettingsDivider
                        }
                    }
                }
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
        }
    }

    @ViewBuilder
    private func episodeRow(_ ep: DownloadItem) -> some View {
        ZStack {
            PlayLink(itemId: ep.id, title: ep.title) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(alignment: .center, spacing: CinemaSpacing.spacing3) {
                CinemaLazyImage(
                    url: downloads.localPosterURL(forItemId: ep.id)
                        ?? appState.imageBuilder.imageURL(itemId: ep.id, imageType: .primary, maxWidth: 240),
                    fallbackIcon: "play.circle",
                    fallbackBackground: CinemaColor.surfaceContainerHigh
                )
                .frame(width: 96, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))

                VStack(alignment: .leading, spacing: 3) {
                    if let s = ep.seasonIndex, let e = ep.episodeIndex {
                        Text(String(format: "S%02d:E%02d", s, e))
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                    Text(ep.title)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                    if let frac = ep.offlineResumeFraction {
                        ProgressBarView(progress: frac, height: 3)
                            .padding(.top, 3)
                    }
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaSpacing.spacing3)
        }
    }
}
#endif
