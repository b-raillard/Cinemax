#if os(iOS)
import SwiftUI
import CinemaxKit
import JellyfinAPI

/// Download affordance for `MediaDetailScreen` and similar surfaces.
///
/// Renders a single icon button whose state mirrors `DownloadManager.item(for:)`:
///   * not downloaded → `arrow.down.circle`         (tap → enqueue)
///   * downloading    → progress ring + `%`         (tap → pause)
///   * paused / failed → `play.circle` / `arrow.triangle.2.circlepath` (tap → resume)
///   * completed      → `checkmark.circle.fill`     (long-press menu → remove)
///
/// For a series, callers pass `bulk = .series(seasons:episodes:)` so the
/// menu can offer "Download whole series" alongside "Download this season".
struct DownloadButton: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState

    let item: BaseItemDto
    var bulk: BulkContext? = nil

    @State private var showRemoveConfirm = false
    @State private var isFetchingSeries = false

    enum BulkContext {
        /// `episodes` is the current season's list; `seasonName` labels the menu item.
        case season(episodes: [BaseItemDto], seasonName: String)
        /// Series-level menu: pre-loaded current season + an async loader that
        /// fans out across every season when the user picks "Download whole series".
        /// The loader runs on-demand so we don't pre-fetch episode lists the user
        /// might never need.
        case series(currentSeasonEpisodes: [BaseItemDto],
                    currentSeasonName: String,
                    fetchAllEpisodes: @MainActor () async -> [BaseItemDto])
    }

    /// True once this item's download has finished — drives the completion
    /// haptic. Reading it from the manager keeps it live with the observable.
    private var isCompleted: Bool {
        item.id.flatMap { downloads.item(for: $0)?.status } == .completed
    }

    var body: some View {
        // Single chokepoint for the offline-downloads feature gate: every
        // call site (detail screen chip, per-episode card, series menu)
        // renders through here, so gating the body hides the download
        // affordance everywhere when the admin disabled the feature
        // (globally or for this user).
        if appState.offlineDownloadsEnabled {
            gatedBody
        }
    }

    private var gatedBody: some View {
        Group {
            switch bulk {
            case .none:
                simpleButton
            case .season(let eps, _):
                bulkMenu(seasonEpisodes: eps, fetchSeries: nil)
            case .series(let cur, _, let fetchAll):
                bulkMenu(seasonEpisodes: cur, fetchSeries: fetchAll)
            }
        }
        .sensoryFeedback(.success, trigger: isCompleted) { old, new in !old && new }
        .confirmationDialog(
            loc.localized("downloads.confirmRemove.title"),
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(loc.localized("downloads.action.remove"), role: .destructive) {
                guard let id = item.id else { return }
                downloads.remove(id)
                toasts.info(loc.localized("toast.download.removed"))
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("downloads.confirmRemove.message"))
        }
    }

    // MARK: - Simple (single-item) button

    @ViewBuilder
    private var simpleButton: some View {
        let entry = item.id.flatMap { downloads.item(for: $0) }
        Button {
            handlePrimaryTap(entry: entry)
        } label: {
            iconView(entry: entry)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: entry))
    }

    // MARK: - Bulk (season / series) menu

    @ViewBuilder
    private func bulkMenu(seasonEpisodes: [BaseItemDto], fetchSeries: (@MainActor () async -> [BaseItemDto])?) -> some View {
        let entry = item.id.flatMap { downloads.item(for: $0) }
        Menu {
            Button {
                enqueueMany(seasonEpisodes)
            } label: {
                Label(loc.localized("detail.download.queueSeason"), systemImage: "square.stack.3d.up")
            }
            if let fetchSeries {
                Button {
                    isFetchingSeries = true
                    Task {
                        let all = await fetchSeries()
                        isFetchingSeries = false
                        enqueueMany(all)
                    }
                } label: {
                    Label(loc.localized("detail.download.queueSeries"), systemImage: "rectangle.stack")
                }
                .disabled(isFetchingSeries)
            }
        } label: {
            iconView(entry: entry)
        }
        .accessibilityLabel(loc.localized("detail.download"))
    }

    // MARK: - Icon

    @ViewBuilder
    private func iconView(entry: DownloadItem?) -> some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 44, height: 44)
            switch entry?.status {
            case .none:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
            case .queued:
                Image(systemName: "clock")
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
            case .downloading:
                ProgressRing(progress: entry?.progress ?? 0, tint: themeManager.accent)
                    .frame(width: 28, height: 28)
            case .paused:
                Image(systemName: "play.circle")
                    .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
            case .failed:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                    .foregroundStyle(CinemaColor.error)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
            }
        }
    }

    // MARK: - Actions

    private func handlePrimaryTap(entry: DownloadItem?) {
        guard let id = item.id else { return }
        switch entry?.status {
        case .none:
            enqueueSingle()
        case .downloading, .queued:
            downloads.pause(id)
        case .paused, .failed:
            downloads.resume(id)
        case .completed:
            showRemoveConfirm = true
        }
    }

    private func enqueueSingle() {
        guard let id = item.id, let userId = appState.currentUserId else { return }
        // PlaybackInfo negotiation is async — fire-and-forget so the UI stays
        // responsive. Toast feedback happens once the URL is in hand.
        let item = item
        let posterURLs = artworkURLs(for: item)
        Task {
            do {
                let req = try await appState.apiClient.buildDownloadRequest(itemId: id, userId: userId)
                guard let dl = DownloadItem.from(item: item, request: req) else {
                    toasts.error(loc.localized("toast.download.error"))
                    return
                }
                downloads.enqueue(dl, posterURL: posterURLs.0, backdropURL: posterURLs.1)
                toasts.success(loc.localized("toast.download.queued"))
            } catch {
                toasts.error(loc.localized("toast.download.error"))
            }
        }
    }

    private func enqueueMany(_ episodes: [BaseItemDto]) {
        guard let userId = appState.currentUserId else { return }
        Task {
            var queued = 0
            var failed = 0
            for ep in episodes {
                guard let epId = ep.id else { continue }
                if downloads.item(for: epId) != nil { continue }
                guard let req = try? await appState.apiClient.buildDownloadRequest(itemId: epId, userId: userId),
                      let dl = DownloadItem.from(item: ep, request: req) else {
                    failed += 1
                    continue
                }
                let (poster, backdrop) = artworkURLs(for: ep)
                downloads.enqueue(dl, posterURL: poster, backdropURL: backdrop)
                queued += 1
            }
            emitBulkToast(queued: queued, failed: failed)
        }
    }

    @MainActor
    private func emitBulkToast(queued: Int, failed: Int) {
        if queued == 0 {
            if failed > 0 {
                // Nothing queued because negotiation failed for every episode —
                // a "download queued" pill here would be a lie.
                toasts.error(loc.localized("toast.download.error"))
                return
            }
            toasts.info(loc.localized("toast.download.queued"))
        } else if queued == 1 {
            toasts.success(loc.localized("toast.download.queued"))
        } else {
            toasts.success(loc.localized("toast.download.queuedMany", queued))
        }
    }

    private func accessibilityLabel(for entry: DownloadItem?) -> String {
        switch entry?.status {
        case .completed: loc.localized("detail.downloaded")
        case .downloading, .queued: loc.localized("detail.downloading")
        case .paused: loc.localized("downloads.action.resume")
        case .failed: loc.localized("downloads.action.retry")
        case .none: loc.localized("detail.download")
        }
    }

    /// True when the item's source container is one AVPlayer can decode.
    /// Anything else (MKV, AVI, WebM) downloads fine but renders audio-only —
    /// callers use this to warn at enqueue and to gate playback. The check is
    /// container-only; for codec mismatches AVPlayer surfaces its own error.
    static func isLikelyOfflinePlayable(_ item: BaseItemDto) -> Bool {
        guard let container = item.mediaSources?.first?.container else { return true }
        let parts = container.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return parts.contains(where: { DownloadItem.avkitFriendlyContainers.contains($0) })
    }

    /// Builds (poster, backdrop) URLs for the artwork prefetch that runs
    /// alongside the media download. Episodes pull the series poster so the
    /// offline library renders a consistent show artwork, but keep their own
    /// (episode-id) image as the backdrop fallback when no series backdrop
    /// has been registered.
    private func artworkURLs(for ep: BaseItemDto) -> (URL?, URL?) {
        guard let id = ep.id else { return (nil, nil) }
        let posterId = ep.seriesID ?? id
        let backdropId = ep.backdropItemID ?? id
        let poster = appState.imageBuilder.imageURL(itemId: posterId, imageType: .primary, maxWidth: 480)
        let backdrop = appState.imageBuilder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: 1280)
        return (poster, backdrop)
    }
}

/// Circular determinate progress indicator used inside `DownloadButton`.
struct ProgressRing: View {
    var progress: Double
    var tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "pause.fill")
                .font(.system(size: CinemaScale.pt(10), weight: .bold))
                .foregroundStyle(tint)
        }
    }
}
#endif
