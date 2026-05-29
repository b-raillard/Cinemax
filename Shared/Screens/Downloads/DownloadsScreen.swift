#if os(iOS)
import SwiftUI
import CinemaxKit
import JellyfinAPI

/// Management surface for offline downloads.
///
/// Pushed from Settings → Downloads. Renders a grouped list of movies and
/// per-series episode bundles, each with status / progress / per-row actions
/// (pause, resume, retry, remove). Empty state nudges the user to the detail
/// screens where the actual download button lives.
struct DownloadsScreen: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var pendingRemoval: DownloadItem?
    @State private var showRemoveAllConfirm = false

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            if downloads.items.isEmpty {
                EmptyStateView(
                    systemImage: "arrow.down.circle",
                    title: loc.localized("downloads.empty.title"),
                    subtitle: loc.localized("downloads.empty.subtitle")
                )
            } else {
                content
            }
        }
        .navigationTitle(loc.localized("downloads.title"))
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            loc.localized("downloads.confirmRemove.title"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(loc.localized("downloads.action.remove"), role: .destructive) {
                if let entry = pendingRemoval {
                    downloads.remove(entry.id)
                    toasts.info(loc.localized("toast.download.removed"))
                }
                pendingRemoval = nil
            }
            Button(loc.localized("action.cancel"), role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(loc.localized("downloads.confirmRemove.message"))
        }
    }

    // MARK: - Sections

    private var content: some View {
        let groups = grouped(downloads.items)
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                diskUsageBanner

                if !groups.movies.isEmpty {
                    section(title: loc.localized("downloads.section.movies"), rows: {
                        ForEach(groups.movies) { entry in
                            row(for: entry)
                        }
                    })
                }

                ForEach(groups.seriesOrder, id: \.self) { seriesKey in
                    if let bucket = groups.series[seriesKey] {
                        section(title: bucket.title, rows: {
                            ForEach(bucket.episodes) { entry in
                                row(for: entry)
                            }
                        })
                    }
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
    }

    private var diskUsageBanner: some View {
        Menu {
            Button(role: .destructive) {
                showRemoveAllConfirm = true
            } label: {
                Label(loc.localized("downloads.action.removeAll"), systemImage: "trash")
            }
        } label: {
            HStack {
                Image(systemName: "internaldrive")
                    .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                Text(loc.localized("downloads.totalSpace", formatBytes(downloads.totalDiskBytes)))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                    .foregroundStyle(CinemaColor.outlineVariant)
            }
            .padding(CinemaSpacing.spacing3)
            .glassPanel(cornerRadius: CinemaRadius.large)
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            loc.localized("downloads.removeAll.title"),
            isPresented: $showRemoveAllConfirm,
            titleVisibility: .visible
        ) {
            Button(loc.localized("downloads.action.removeAll"), role: .destructive) {
                downloads.removeAll()
                toasts.info(loc.localized("toast.download.removed"))
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("downloads.removeAll.message"))
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            iOSSettingsSectionHeader(title)
            VStack(spacing: 0) {
                rows()
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for entry: DownloadItem) -> some View {
        VStack(spacing: 0) {
            ZStack {
                // Tappable layer — only active when the file is fully on disk.
                // Sits underneath the inline action menu so the ellipsis still
                // wins the gesture for live downloads.
                if entry.status == .completed {
                    PlayLink(
                        itemId: entry.id,
                        title: rowTitle(for: entry)
                    ) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .center, spacing: CinemaSpacing.spacing3) {
                    thumbnail(for: entry)
                        .frame(width: 72, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))
                        .overlay(
                            RoundedRectangle(cornerRadius: CinemaRadius.small)
                                .strokeBorder(CinemaColor.onSurface.opacity(0.08), lineWidth: 1)
                        )
                        .overlay {
                            if entry.status == .completed {
                                Image(systemName: "play.fill")
                                    .font(.system(size: CinemaScale.pt(14), weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background(Circle().fill(.black.opacity(0.55)))
                            }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rowTitle(for: entry))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                            .lineLimit(1)
                        Text(rowSubtitle(for: entry))
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(statusTint(for: entry.status))
                            .lineLimit(1)
                    }
                    Spacer(minLength: CinemaSpacing.spacing2)
                    trailingControl(for: entry)
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.vertical, CinemaSpacing.spacing3)
            }

            if entry.status == .downloading || (entry.status == .paused && entry.bytesReceived > 0) {
                ProgressBarView(progress: entry.progress)
                    .padding(.horizontal, CinemaSpacing.spacing3)
                    .padding(.bottom, CinemaSpacing.spacing3)
            }

            if entry != lastEntry(in: entry) {
                iOSSettingsDivider
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for entry: DownloadItem) -> some View {
        let imgID = (entry.kind == .episode ? entry.seriesId : entry.id) ?? entry.id
        // Locally-cached art wins over the remote URL so offline users still
        // see thumbnails. We key the on-disk poster by the download's own id,
        // which matches what `enqueue` saves regardless of series/movie kind.
        let url = downloads.localPosterURL(forItemId: entry.id)
            ?? appState.imageBuilder.imageURL(itemId: imgID, imageType: .primary, maxWidth: 180)
        CinemaLazyImage(
            url: url,
            fallbackIcon: entry.kind == .movie ? "film" : "tv",
            fallbackBackground: CinemaColor.surfaceContainerHigh
        )
    }

    @ViewBuilder
    private func trailingControl(for entry: DownloadItem) -> some View {
        Menu {
            switch entry.status {
            case .downloading, .queued:
                Button {
                    downloads.pause(entry.id)
                } label: {
                    Label(loc.localized("downloads.action.pause"), systemImage: "pause.fill")
                }
            case .paused:
                Button {
                    downloads.resume(entry.id)
                } label: {
                    Label(loc.localized("downloads.action.resume"), systemImage: "play.fill")
                }
            case .failed:
                Button {
                    downloads.resume(entry.id)
                } label: {
                    Label(loc.localized("downloads.action.retry"), systemImage: "arrow.triangle.2.circlepath")
                }
            case .completed:
                EmptyView()
            }
            Button(role: .destructive) {
                pendingRemoval = entry
            } label: {
                Label(loc.localized("downloads.action.remove"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                .foregroundStyle(themeManager.accent)
        }
    }

    // MARK: - Helpers

    private func rowTitle(for entry: DownloadItem) -> String {
        switch entry.kind {
        case .movie:
            return entry.title
        case .episode:
            if let s = entry.seasonIndex, let e = entry.episodeIndex {
                return String(format: "S%02d:E%02d · %@", s, e, entry.title) as String
            }
            return entry.title
        }
    }

    private func rowSubtitle(for entry: DownloadItem) -> String {
        switch entry.status {
        case .queued:
            return loc.localized("downloads.status.queued")
        case .downloading:
            return "\(loc.localized("downloads.status.downloading")) · \(Int(entry.progress * 100)) %"
        case .paused:
            return loc.localized("downloads.status.paused")
        case .completed:
            return "\(loc.localized("downloads.status.completed")) · \(formatBytes(entry.totalBytes > 0 ? entry.totalBytes : entry.bytesReceived))"
        case .failed:
            return entry.errorMessage ?? loc.localized("downloads.status.failed")
        }
    }

    private func statusTint(for status: DownloadStatus) -> Color {
        switch status {
        case .failed: return CinemaColor.error
        case .completed: return themeManager.accent
        default: return CinemaColor.onSurfaceVariant
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    // Hoisted to avoid allocating a `ByteCountFormatter` on every row render.
    // Main-actor render only, so `nonisolated(unsafe)` is safe.
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    // MARK: - Grouping

    private struct GroupedDownloads {
        var movies: [DownloadItem]
        var series: [String: SeriesBucket]
        /// Series keys in insertion order so the screen is stable across rebuilds.
        var seriesOrder: [String]
    }

    private struct SeriesBucket {
        var title: String
        var episodes: [DownloadItem]
    }

    private func grouped(_ all: [DownloadItem]) -> GroupedDownloads {
        var result = GroupedDownloads(movies: [], series: [:], seriesOrder: [])
        let sorted = all.sorted { $0.createdAt < $1.createdAt }
        for entry in sorted {
            switch entry.kind {
            case .movie:
                result.movies.append(entry)
            case .episode:
                let key = entry.seriesId ?? entry.title
                if result.series[key] == nil {
                    result.series[key] = SeriesBucket(title: entry.seriesTitle ?? entry.title, episodes: [])
                    result.seriesOrder.append(key)
                }
                result.series[key]?.episodes.append(entry)
            }
        }
        // Episodes within a series sort by season + episode index for predictability.
        for key in result.seriesOrder {
            result.series[key]?.episodes.sort { lhs, rhs in
                (lhs.seasonIndex ?? 0, lhs.episodeIndex ?? 0) < (rhs.seasonIndex ?? 0, rhs.episodeIndex ?? 0)
            }
        }
        return result
    }

    /// Returns the entry that should *not* render a trailing divider — the last
    /// one inside its section. Used to draw section-aware dividers without
    /// nesting view hierarchies.
    private func lastEntry(in entry: DownloadItem) -> DownloadItem {
        let groups = grouped(downloads.items)
        if entry.kind == .movie {
            return groups.movies.last ?? entry
        }
        let key = entry.seriesId ?? entry.title
        return groups.series[key]?.episodes.last ?? entry
    }
}

#endif
