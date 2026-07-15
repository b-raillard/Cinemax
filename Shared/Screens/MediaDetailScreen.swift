import SwiftUI
import CinemaxKit
import JellyfinAPI

/// The resolved play target a Watch Together group is opened for — the movie,
/// or a series' next-up episode. Drives both the group sheet and the playback
/// push once a group is created/joined. `Hashable` because it also feeds
/// `navigationDestination(item:)` on iOS (same contract as `AdminMenuPushIntent`).
struct WatchTogetherIntent: Identifiable, Hashable {
    let id = UUID()
    let itemId: String
    let title: String
    let startTime: Double?
}

struct MediaDetailScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State var viewModel: MediaDetailViewModel
    @State private var episodeOverview: EpisodeOverviewItem?
    @Environment(NetworkMonitor.self) private var network
    @Environment(ToastCenter.self) private var toast
    /// Watch Together (SyncPlay): the item to present the group sheet for, and
    /// (iOS) the item to push into playback once a group is created/joined.
    @State private var watchTogetherSheet: WatchTogetherIntent?
    /// Watch Together (SyncPlay) is not production-ready yet. This kill-switch
    /// hides both UI entry points (iOS secondary-actions chip + tvOS action-row
    /// button) while keeping the whole implementation compiled and type-checked.
    /// Flip to `true` to bring the feature back. See CLAUDE.md "SyncPlay / Watch
    /// Together". Revisit after 1.0.5 ships.
    private static let watchTogetherEnabled = false
    #if os(iOS)
    @State private var watchTogetherPlay: WatchTogetherIntent?
    #endif
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    /// Lifted from `AdminItemMenu` so SwiftUI honors the destination —
    /// `adminMenuPill` is rendered inside `detailContent`'s `LazyVStack`,
    /// and `navigationDestination` placed inside lazy containers is
    /// silently dropped by the runtime.
    @State private var adminPushIntent: AdminMenuPushIntent?
    #endif
    @AppStorage(SettingsKey.detailShowQualityBadges) private var showQualityBadges: Bool = SettingsKey.Default.detailShowQualityBadges
    #if os(iOS)
    @AppStorage(SettingsKey.detailShowTrailerButton) private var showTrailerButton: Bool = SettingsKey.Default.detailShowTrailerButton
    @Environment(\.openURL) private var openURL
    #endif

    init(itemId: String, itemType: BaseItemKind = .movie) {
        _viewModel = State(initialValue: MediaDetailViewModel(itemId: itemId, itemType: itemType))
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                LoadingStateView()
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if let item = viewModel.item {
                detailContent(item)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Hosted on the body's outer ZStack — eager — so the destination
        // doesn't get swallowed by the `LazyVStack` inside `detailContent`.
        .navigationDestination(item: $adminPushIntent) { intent in
            adminMenuPushDestination(for: intent)
        }
        #endif
        .task {
            await viewModel.load(using: appState, loc: loc)
        }
        #if os(tvOS)
        .onChange(of: coordinator.lastDismissedAt) { _, _ in
            Task { await viewModel.load(using: appState, loc: loc) }
        }
        #endif
        .sheet(item: $episodeOverview) { ep in
            EpisodeOverviewSheet(item: ep)
                .environment(themeManager)
        }
        .modifier(WatchTogetherPresentation(
            sheet: $watchTogetherSheet,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toast,
            network: network,
            onStart: { intent in startWatchTogether(intent) }
        ))
        #if os(iOS)
        .navigationDestination(item: $watchTogetherPlay) { intent in
            VideoPlayerView(itemId: intent.itemId, title: intent.title, startTime: intent.startTime)
        }
        #endif
    }

    /// Kicks off playback once a Watch Together group is created/joined. tvOS
    /// drives the coordinator (its normal play path); iOS pushes `VideoPlayerView`.
    private func startWatchTogether(_ intent: WatchTogetherIntent) {
        #if os(tvOS)
        coordinator.play(itemId: intent.itemId, title: intent.title, startTime: intent.startTime, using: appState)
        #else
        watchTogetherPlay = intent
        #endif
    }

    /// Builds the play target for Watch Together: the resolved next-up episode
    /// for a series, else the item itself.
    private func watchTogetherIntent(for item: BaseItemDto, nextEp: BaseItemDto?) -> WatchTogetherIntent {
        let target = nextEp ?? item
        return WatchTogetherIntent(
            itemId: target.id ?? item.id ?? viewModel.itemId,
            title: target.name ?? item.name ?? "",
            startTime: nil
        )
    }

    // MARK: - Detail Content

    private func detailContent(_ item: BaseItemDto) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Backdrop hero
                backdropSection(item)

                belowHeroContent(item)
            }
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    /// Content below the backdrop hero. iPhone + tvOS stack every section
    /// vertically; iPad (regular width) splits it into a metadata column
    /// (action buttons / quality badges / overview) and an episodes-or-cast
    /// column. The section builders are shared verbatim between both paths —
    /// only the container differs.
    @ViewBuilder
    private func belowHeroContent(_ item: BaseItemDto) -> some View {
        #if os(iOS)
        if useTwoColumnLayout {
            // 40 / 60 split of the full scroll width using the same
            // `containerRelativeFrame(count:span:)` grid technique as the tvOS
            // episode row. The horizontal carousels (cast / similar / episodes)
            // in the right column measure their own scroll viewport, so they
            // resize to the column automatically.
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    primaryColumnSections(item)
                }
                .containerRelativeFrame(.horizontal, count: 5, span: 2, spacing: 0)

                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    secondaryColumnSections(item)
                    Spacer(minLength: 80)
                }
                .containerRelativeFrame(.horizontal, count: 5, span: 3, spacing: 0)
            }
            .padding(.top, CinemaSpacing.spacing4)
        } else {
            stackedBelowHeroContent(item)
        }
        #else
        stackedBelowHeroContent(item)
        #endif
    }

    /// The single-column (iPhone / tvOS) arrangement — primary then secondary
    /// sections in one vertical stack, preserving the original order.
    @ViewBuilder
    private func stackedBelowHeroContent(_ item: BaseItemDto) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
            primaryColumnSections(item)
            secondaryColumnSections(item)
            Spacer(minLength: 80)
        }
        .padding(.top, CinemaSpacing.spacing4)
    }

    /// Metadata sections: action buttons, admin menu (iOS), quality badges,
    /// overview, studio line. The iPad left column.
    @ViewBuilder
    private func primaryColumnSections(_ item: BaseItemDto) -> some View {
        // Action buttons
        actionButtons(item)

        #if os(iOS)
        // Admin-gated 3-dot menu (Identifier / Edit metadata / Refresh /
        // Delete). Server enforces authorization on every endpoint; client
        // gating is UX only.
        if appState.isAdministrator {
            adminMenuPill(for: item)
        }
        #endif

        // Quality badges
        if showQualityBadges {
            MediaQualityBadges(item: item)
                .padding(.horizontal, contentPadding)
        }

        // Overview — Dynamic Type-aware since users read this prose.
        if let overview = item.overview {
            Text(overview)
                .font(CinemaFont.dynamicBody)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .frame(maxWidth: readingMaxWidth, alignment: .leading)
                .padding(.horizontal, contentPadding)
                #if os(tvOS)
                .focusable()
                #endif
        }

        // Studio / Network
        studioLine(item)
            .frame(maxWidth: readingMaxWidth, alignment: .leading)
            .padding(.horizontal, contentPadding)
    }

    /// Rich sections: cast, seasons/episodes, collection, similar. The iPad
    /// right column.
    @ViewBuilder
    private func secondaryColumnSections(_ item: BaseItemDto) -> some View {
        // Cast
        if let people = item.people, !people.isEmpty {
            MediaDetailCastSection(people: people).equatable()
        }

        // Seasons & Episodes (for series)
        if viewModel.resolvedType == .series, !viewModel.seasons.isEmpty {
            seasonsSection(item)
        }

        // Collection ("Part of: …") — movies that share a BoxSet
        if !viewModel.collectionItems.isEmpty {
            MediaDetailSimilarSection(
                items: viewModel.collectionItems,
                cardWidth: similarCardWidth,
                titleOverride: String(
                    format: loc.localized("detail.partOf"),
                    viewModel.collectionName ?? ""
                )
            ).equatable()
        }

        // Similar items
        if !viewModel.similarItems.isEmpty {
            MediaDetailSimilarSection(items: viewModel.similarItems, cardWidth: similarCardWidth).equatable()
        }
    }

    #if os(iOS)
    /// iPad (regular horizontal size class) shows the two-column detail layout.
    /// iPhone (compact) keeps the stacked layout. Follows the codebase-wide
    /// convention of treating regular width as iPad (see `AdaptiveLayout`).
    private var useTwoColumnLayout: Bool {
        sizeClass == .regular
    }
    #endif

    // MARK: - Backdrop

    @ViewBuilder
    private func backdropSection(_ item: BaseItemDto) -> some View {
        ZStack(alignment: .bottomLeading) {
            if item.hasBackdropImage, let backdropId = item.backdropItemID {
                CinemaLazyImage(
                    url: appState.imageBuilder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: ImageURLBuilder.backdropPixelWidth, tag: item.backdropImageTagValue),
                    fallbackIcon: nil,
                    fallbackBackground: CinemaColor.surfaceContainerLow
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            } else {
                BackdropFallbackView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            CinemaGradient.heroOverlay

            VStack(alignment: .leading, spacing: detailHeroSpacing) {
                // Badges
                HStack(spacing: 8) {
                    if let rating = item.officialRating {
                        RatingBadge(rating: rating)
                    }

                    metadataLine(item)
                }
                .foregroundStyle(CinemaColor.onSurfaceVariant)

                // Title
                Text(item.name ?? "")
                    .font(.system(size: detailTitleSize, weight: .black))
                    .tracking(-1.5)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                // Genres
                if let genres = item.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · "))
                        .font(.system(size: genreFontSize, weight: .medium))
                        .foregroundStyle(themeManager.accent)
                }

                // Community + critic ratings (audience on left, critics on right)
                ratingsRow(item)
            }
            .padding(.horizontal, contentPadding)
            .padding(.top, contentPadding)
            .padding(.bottom, contentPadding + CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        #if os(tvOS)
        .frame(height: backdropHeight)
        #else
        // iPad hardening: clamp the backdrop to ~55% of the scroll viewport
        // so action buttons / overview stay reachable in short Stage Manager
        // or Split View windows. Full-screen sizes resolve to `backdropHeight`.
        .containerRelativeFrame(.vertical) { length, _ in
            min(backdropHeight, length * 0.55)
        }
        #endif
        .clipped()
    }

    // MARK: - Ratings Row (backdrop)

    @ViewBuilder
    private func ratingsRow(_ item: BaseItemDto) -> some View {
        let hasCommunity = item.communityRating != nil
        let hasCritic = item.criticRating != nil

        if hasCommunity || hasCritic {
            HStack(spacing: CinemaSpacing.spacing4) {
                if let rating = item.communityRating {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", rating))
                            .fontWeight(.bold)
                    }
                    .font(.system(size: ratingFontSize))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityLabel("\(loc.localized("detail.audienceRating")) \(String(format: "%.1f", rating))")
                }

                if let critic = item.criticRating {
                    let isFresh = critic >= 60
                    HStack(spacing: 4) {
                        // Rotten Tomatoes-style — green when ≥ 60, red otherwise.
                        Image(systemName: isFresh ? "applescript.fill" : "takeoutbag.and.cup.and.straw.fill")
                            .foregroundStyle(isFresh ? .green : .red)
                        Text("\(Int(critic.rounded()))%")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: ratingFontSize))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityLabel("\(loc.localized("detail.criticRating")) \(Int(critic.rounded())) percent")
                }
            }
        }
    }

    // MARK: - Studio / Network

    /// Comma-separated list of up to 2 studios (or network label for series).
    /// Rendered below the overview text. Returns `EmptyView` when no studios are present.
    @ViewBuilder
    private func studioLine(_ item: BaseItemDto) -> some View {
        let names = (item.studios ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        if !names.isEmpty {
            let isSeries = viewModel.resolvedType == .series
            let labelKey = isSeries ? "detail.network" : "detail.studio"
            HStack(alignment: .firstTextBaseline, spacing: CinemaSpacing.spacing2) {
                Text(loc.localized(labelKey))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text(names.prefix(2).joined(separator: ", "))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Metadata

    private func metadataLine(_ item: BaseItemDto) -> some View {
        let parts: [String] = [
            item.productionYear.map(String.init),
            item.runTimeTicks.map { ticks in
                let minutes = ticks.jellyfinMinutes
                return minutes > 60 ? loc.localized("detail.runtime.hours", minutes / 60, minutes % 60) : loc.localized("detail.runtime.minutes", minutes)
            },
            viewModel.resolvedType == .series ? item.childCount.map { loc.localized("detail.seasons", $0) } : nil
        ].compactMap { $0 }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: metadataFontSize, weight: .medium))
    }

    // MARK: - Episode Navigation

    /// Looks up precomputed prev/next episode refs from the ViewModel's navigation maps.
    private func episodeNavigation(for episodeId: String) -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?) {
        if let nav = viewModel.episodeNavigationMap[episodeId] {
            return nav
        }
        if let nav = viewModel.nextUpNavigationMap[episodeId] {
            return nav
        }
        return (nil, nil, nil)
    }

    // MARK: - Action Buttons

    /// Resolves the data `PlayActionButtonsSection` needs. Kept out of the
    /// sub-view so the sub-view's dependencies stay narrow (and its
    /// `Equatable` short-circuit can skip unrelated view-model updates).
    private func actionButtons(_ item: BaseItemDto) -> some View {
        let isSeries = viewModel.resolvedType == .series
        let nextEp: BaseItemDto? = isSeries ? viewModel.nextUpEpisode : nil

        let posTicks: Int = isSeries
            ? (nextEp?.userData?.playbackPositionTicks ?? 0)
            : (item.userData?.playbackPositionTicks ?? 0)
        let totalTicks: Int = isSeries
            ? (nextEp?.runTimeTicks ?? 0)
            : (item.runTimeTicks ?? 0)
        let isPlayed: Bool = isSeries
            ? (nextEp?.userData?.isPlayed ?? false)
            : (item.userData?.isPlayed ?? false)

        let showResume = posTicks > 0 && !isPlayed && totalTicks > 0
        let progress: Double = showResume ? min(1.0, Double(posTicks) / Double(totalTicks)) : 0
        let remainingMinutes = max(0, totalTicks - posTicks).jellyfinMinutes
        let startSeconds: Double? = showResume ? posTicks.jellyfinSeconds : nil

        let playItemId: String = nextEp?.id ?? item.id ?? ""
        let playTitle: String = nextEp?.name ?? item.name ?? ""

        let nextEpisodeLabel: String? = {
            guard let ep = nextEp else { return nil }
            let prefix: String?
            if let season = ep.parentIndexNumber, let num = ep.indexNumber {
                prefix = String(format: "S%02d:E%02d", season, num)
            } else if let num = ep.indexNumber {
                prefix = loc.localized("detail.episode", num)
            } else {
                prefix = nil
            }
            let parts: [String] = [prefix, ep.name].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " - ")
        }()

        let remainingText: String? = showResume ? loc.remainingTime(minutes: remainingMinutes) : nil

        let epNav = nextEp.flatMap { ep -> (previous: EpisodeRef?, next: EpisodeRef?, navigator: EpisodeNavigator?)? in
            guard let id = ep.id else { return nil }
            return episodeNavigation(for: id)
        }

        let playSection = PlayActionButtonsSection(
            playItemId: playItemId,
            playTitle: playTitle,
            nextEpisodeLabel: nextEpisodeLabel,
            startSeconds: startSeconds,
            showResume: showResume,
            progress: progress,
            remainingText: remainingText,
            epPrev: epNav?.previous,
            epNext: epNav?.next,
            epNavigator: epNav?.navigator,
            playLabel: loc.localized("detail.play"),
            playFromBeginningLabel: loc.localized("detail.playFromBeginning"),
            buttonFontSize: buttonFontSize,
            buttonVerticalPadding: buttonVerticalPadding,
            playButtonWidth: playButtonWidth,
            contentPadding: 0
        )
        .equatable()

        #if os(tvOS)
        // tvOS keeps the inline row: only two focusable ghost accessories
        // (favorite, watched) sit beside Play, well within the wide TV safe
        // area. `.playActionRow` centers them on the Lecture button no matter
        // how much resume chrome (episode label, progress bar, remaining text)
        // stacks above it.
        return HStack(alignment: .playActionRow, spacing: CinemaSpacing.spacing3) {
            playSection
            favoriteButton
            watchedButton
            if Self.watchTogetherEnabled && network.isOnline {
                watchTogetherButton(for: item, nextEp: nextEp)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, contentPadding)
        #else
        // iOS: Play stays the primary CTA; the secondary actions drop to a
        // labeled icon row beneath it. The old single line crammed Play plus
        // four icon accessories together and cropped the last one off narrow
        // phones once the watched toggle was added — an evenly-distributed
        // labeled row can't overflow and names each action.
        return VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            playSection
            secondaryActionsRow(for: item, nextEp: nextEp)
        }
        .padding(.horizontal, contentPadding)
        #endif
    }

    #if os(tvOS)
    /// Heart toggle in the tvOS action row — a focusable ghost button beside
    /// Play. Optimistic flip on the view model; accent fill when active.
    private var favoriteButton: some View {
        Button {
            Task { await viewModel.toggleFavorite(using: appState) }
        } label: {
            Image(systemName: viewModel.isFavorite ? "heart.fill" : "heart")
                .font(.system(size: buttonFontSize, weight: .bold))
                .foregroundStyle(viewModel.isFavorite ? themeManager.accent : CinemaColor.onSurface)
                .padding(.vertical, buttonVerticalPadding)
                .padding(.horizontal, CinemaSpacing.spacing4)
        }
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
        .accessibilityLabel(loc.localized(viewModel.isFavorite ? "detail.favorite.remove" : "detail.favorite.add"))
    }

    /// Watched toggle beside the heart on tvOS. Marks the movie / whole series
    /// played; optimistic flip on the view model, accent fill when watched.
    private var watchedButton: some View {
        Button {
            Task { await viewModel.togglePlayed(using: appState) }
        } label: {
            Image(systemName: viewModel.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: buttonFontSize, weight: .bold))
                .foregroundStyle(viewModel.isPlayed ? themeManager.accent : CinemaColor.onSurface)
                .padding(.vertical, buttonVerticalPadding)
                .padding(.horizontal, CinemaSpacing.spacing4)
        }
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
        .accessibilityLabel(loc.localized(viewModel.isPlayed ? "detail.watched.remove" : "detail.watched.add"))
    }

    /// "Watch Together" (SyncPlay) toggle in the tvOS action row — opens the
    /// group sheet. Accent fill while already in a group.
    private func watchTogetherButton(for item: BaseItemDto, nextEp: BaseItemDto?) -> some View {
        Button {
            watchTogetherSheet = watchTogetherIntent(for: item, nextEp: nextEp)
        } label: {
            Image(systemName: "person.2.fill")
                .font(.system(size: buttonFontSize, weight: .bold))
                .foregroundStyle(SyncPlayController.shared.isInGroup ? themeManager.accent : CinemaColor.onSurface)
                .padding(.vertical, buttonVerticalPadding)
                .padding(.horizontal, CinemaSpacing.spacing4)
        }
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
        .accessibilityLabel(loc.localized("syncplay.title"))
    }
    #endif

    // MARK: - Secondary actions row (iOS)

    #if os(iOS)
    /// Icon actions beneath the Play CTA: favorite, watched, trailer
    /// (when available). Each is a circular glass chip (44pt), left-aligned.
    /// The icons are self-explanatory, so there are no captions; the row sits
    /// on its own line beneath the play buttons and can't crop the way the old
    /// inline accessory row did.
    @ViewBuilder
    private func secondaryActionsRow(for item: BaseItemDto, nextEp: BaseItemDto?) -> some View {
        HStack(spacing: CinemaSpacing.spacing4) {
            secondaryActionCell(
                systemImage: viewModel.isFavorite ? "heart.fill" : "heart",
                active: viewModel.isFavorite,
                accessibility: loc.localized(viewModel.isFavorite ? "detail.favorite.remove" : "detail.favorite.add"),
                trigger: viewModel.isFavorite
            ) {
                Task { await viewModel.toggleFavorite(using: appState) }
            }

            secondaryActionCell(
                systemImage: viewModel.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                active: viewModel.isPlayed,
                accessibility: loc.localized(viewModel.isPlayed ? "detail.watched.remove" : "detail.watched.add"),
                trigger: viewModel.isPlayed
            ) {
                Task { await viewModel.togglePlayed(using: appState) }
            }

            if showTrailerButton, let trailerURL = Self.firstTrailerURL(of: item) {
                secondaryActionCell(
                    systemImage: "movieclapper",
                    active: false,
                    accessibility: loc.localized("detail.trailer"),
                    trigger: false
                ) {
                    openURL(trailerURL)
                }
            }

            // Watch Together (SyncPlay) — online only. Accent while in a group.
            if Self.watchTogetherEnabled && network.isOnline {
                secondaryActionCell(
                    systemImage: "person.2.fill",
                    active: SyncPlayController.shared.isInGroup,
                    accessibility: loc.localized("syncplay.title"),
                    trigger: false
                ) {
                    watchTogetherSheet = watchTogetherIntent(for: item, nextEp: nextEp)
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// One secondary action: a tappable 44pt glass icon chip. `active` paints
    /// the icon in the accent (toggled-on state); `trigger` drives the haptic.
    private func secondaryActionCell(
        systemImage: String,
        active: Bool,
        accessibility: String,
        trigger: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 44, height: 44)
                Image(systemName: systemImage)
                    .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                    .foregroundStyle(active ? themeManager.accent : CinemaColor.onSurface)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: trigger)
        .accessibilityLabel(accessibility)
    }
    #endif

    // MARK: - Trailer URL (iOS)

    #if os(iOS)
    /// First http(s) trailer URL of the item. Defensive on scheme — Jellyfin
    /// metadata can carry plugin-specific URIs the system can't open.
    private static func firstTrailerURL(of item: BaseItemDto) -> URL? {
        for trailer in item.remoteTrailers ?? [] {
            guard let raw = trailer.url, let url = URL(string: raw),
                  url.scheme == "https" || url.scheme == "http" else { continue }
            return url
        }
        return nil
    }
    #endif

    // MARK: - Admin menu pill (iOS)

    #if os(iOS)
    /// Admin-only affordance below the play buttons. Renders `AdminItemMenu`
    /// (ellipsis + glass capsule with "Admin" caption) so all admin actions
    /// on the item (Identifier, Edit metadata, Refresh, Delete) are reachable
    /// from one place. Dismiss on delete so the user isn't left looking at a
    /// freshly-deleted item.
    @ViewBuilder
    private func adminMenuPill(for item: BaseItemDto) -> some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            Text(loc.localized("admin.item.menu"))
                .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                .foregroundStyle(themeManager.accent)
            AdminItemMenu(
                item: item,
                onItemDeleted: { dismiss() },
                onSelectDestination: { dest in
                    adminPushIntent = AdminMenuPushIntent(item: item, destination: dest)
                }
            )
        }
        .padding(.leading, CinemaSpacing.spacing3)
        .padding(.trailing, CinemaSpacing.spacing1)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .fill(themeManager.accent.opacity(0.1))
                )
        )
        .padding(.horizontal, contentPadding)
    }
    #endif

    // MARK: - Seasons

    private func seasonsSection(_ item: BaseItemDto) -> some View {
        let seriesId = item.id ?? viewModel.itemId
        let currentSeasonName = viewModel.seasons.first { $0.id == viewModel.selectedSeasonId }?.name
            ?? loc.localized("detail.season")

        let showSeasonPicker = viewModel.seasons.count > 1

        return VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            #if os(tvOS)
            // tvOS: horizontal scroll of season pills (hidden when only one season)
            if showSeasonPicker {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.seasons, id: \.id) { season in
                            let isSelected = season.id == viewModel.selectedSeasonId
                            Button {
                                if let id = season.id {
                                    Task { await viewModel.selectSeason(id, seriesId: seriesId, using: appState) }
                                }
                            } label: {
                                Text(season.name ?? loc.localized("detail.season"))
                                    .font(.system(size: seasonTabFontSize, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? .white : CinemaColor.onSurfaceVariant)
                                    .padding(.horizontal, CinemaSpacing.spacing3)
                                    .padding(.vertical, 8)
                                    .background(
                                        isSelected
                                            ? Capsule().fill(themeManager.accentContainer)
                                            : Capsule().fill(CinemaColor.surfaceContainerHigh)
                                    )
                            }
                            .buttonStyle(SeasonTabButtonStyle(isSelected: isSelected, accent: themeManager.accent))
                            .focusEffectDisabled()
                            .hoverEffectDisabled()
                        }
                    }
                    .padding(.horizontal, contentPadding)
                }
            }
            // tvOS: vertical list of unified episode rows. `LazyVStack` so a
            // 20+ episode season doesn't render every row up-front.
            LazyVStack(spacing: 12) {
                ForEach(viewModel.episodes, id: \.id) { episode in
                    let nav = episodeNavigation(for: episode.id ?? "")
                    MediaDetailEpisodeRow(
                        episode: episode,
                        epPrev: nav.previous,
                        epNext: nav.next,
                        epNavigator: nav.navigator,
                        episodeThumbnailWidth: episodeThumbnailWidth,
                        episodeTitleFontSize: episodeTitleFontSize,
                        onSelectOverview: { episodeOverview = $0 }
                    )
                    .equatable()
                }
            }
            .padding(.horizontal, contentPadding)
            #else
            // iOS: dropdown Menu for season selection (hidden when only one season)
            if showSeasonPicker {
                Menu {
                    ForEach(viewModel.seasons, id: \.id) { season in
                        Button {
                            if let id = season.id {
                                Task { await viewModel.selectSeason(id, seriesId: seriesId, using: appState) }
                            }
                        } label: {
                            Text(season.name ?? loc.localized("detail.season"))
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentSeasonName)
                            .font(.system(size: seasonTabFontSize, weight: .bold))
                            .foregroundStyle(themeManager.accent)
                        Image(systemName: "chevron.down")
                            .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                            .foregroundStyle(themeManager.accent)
                    }
                    .padding(.horizontal, CinemaSpacing.spacing3)
                    .padding(.vertical, 10)
                    .background(CinemaColor.surfaceContainerHigh)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, contentPadding)
            }
            // iOS: horizontal scroll of episode cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(viewModel.episodes, id: \.id) { episode in
                        let nav = episodeNavigation(for: episode.id ?? "")
                        MediaDetailEpisodeCard(
                            episode: episode,
                            epPrev: nav.previous,
                            epNext: nav.next,
                            epNavigator: nav.navigator,
                            episodeTitleFontSize: episodeTitleFontSize,
                            onSelectOverview: { episodeOverview = $0 },
                            onToggleWatched: { ep in
                                Task { await viewModel.toggleEpisodeWatched(ep, using: appState) }
                            }
                        )
                        .equatable()
                        .containerRelativeFrame(.horizontal) { w, _ in w - contentPadding * 2 - 32 }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, contentPadding)
            }
            .scrollTargetBehavior(.viewAligned)
            #endif
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        ErrorStateView(message: message, retryTitle: loc.localized("action.retry")) {
            Task { await viewModel.load(using: appState, loc: loc) }
        }
    }

    // MARK: - Adaptive Sizing

    private var backdropHeight: CGFloat {
        #if os(tvOS)
        760
        #else
        AdaptiveLayout.detailBackdropHeight(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var detailTitleSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(64)
        #else
        CinemaScale.pt(26)
        #endif
    }

    private var detailHeroSpacing: CGFloat {
        #if os(tvOS)
        14
        #else
        8
        #endif
    }

    private var contentPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    /// Max width for prose blocks (overview, studio line) on wide screens so lines stay readable.
    /// Horizontal carousels (cast, similar, episodes) intentionally ignore this and use full width.
    private var readingMaxWidth: CGFloat {
        #if os(tvOS)
        .infinity
        #else
        AdaptiveLayout.readingMaxWidth(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass)) ?? .infinity
        #endif
    }

    private var metadataFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(20)
        #else
        13
        #endif
    }

    private var genreFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(20)
        #else
        13
        #endif
    }

    private var ratingFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(22)
        #else
        15
        #endif
    }

    private var buttonFontSize: CGFloat {
        #if os(tvOS)
        28 // documented Play-label exception — fixed on tvOS
        #else
        CinemaScale.pt(18)
        #endif
    }

    private var buttonVerticalPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing4
        #else
        CinemaSpacing.spacing2
        #endif
    }

    private var actionButtonSpacing: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing5
        #else
        12
        #endif
    }

    private var playButtonWidth: CGFloat {
        #if os(tvOS)
        240
        #else
        160
        #endif
    }

    private var similarCardWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        140
        #endif
    }

    private var episodeThumbnailWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        130
        #endif
    }

    private var episodeTitleFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(22)
        #else
        15
        #endif
    }

    private var seasonTabFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(22)
        #else
        14
        #endif
    }
}

// MARK: - Play Action Buttons

/// Progress bar + "Play" / "Play from beginning" buttons for the detail screen.
/// Extracted as an Equatable sub-view so `SeasonId`/`episodes` changes on the
/// parent view model don't re-evaluate the play-button tree (the only inputs
/// that actually change what this renders are the resume state and the next
/// episode identity).
private struct PlayActionButtonsSection: View, Equatable {
    let playItemId: String
    let playTitle: String
    let nextEpisodeLabel: String?
    let startSeconds: Double?
    let showResume: Bool
    let progress: Double
    let remainingText: String?
    let epPrev: EpisodeRef?
    let epNext: EpisodeRef?
    let epNavigator: EpisodeNavigator?

    let playLabel: String
    let playFromBeginningLabel: String

    let buttonFontSize: CGFloat
    let buttonVerticalPadding: CGFloat
    let playButtonWidth: CGFloat
    let contentPadding: CGFloat

    @Environment(ThemeManager.self) private var themeManager

    // Equatable ignores the navigator closure — fresh closures that carry the
    // same prev/next identity are treated as equal so the sub-view doesn't
    // thrash when the parent rebuilds a functionally-identical navigator.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.playItemId == rhs.playItemId
            && lhs.playTitle == rhs.playTitle
            && lhs.nextEpisodeLabel == rhs.nextEpisodeLabel
            && lhs.startSeconds == rhs.startSeconds
            && lhs.showResume == rhs.showResume
            && lhs.progress == rhs.progress
            && lhs.remainingText == rhs.remainingText
            && lhs.epPrev?.id == rhs.epPrev?.id
            && lhs.epNext?.id == rhs.epNext?.id
            && lhs.playLabel == rhs.playLabel
            && lhs.playFromBeginningLabel == rhs.playFromBeginningLabel
            && lhs.buttonFontSize == rhs.buttonFontSize
            && lhs.buttonVerticalPadding == rhs.buttonVerticalPadding
            && lhs.playButtonWidth == rhs.playButtonWidth
            && lhs.contentPadding == rhs.contentPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            if let label = nextEpisodeLabel {
                Text(label)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
            }

            if showResume {
                #if os(iOS)
                ProgressBarView(progress: progress)
                    .frame(maxWidth: .infinity)
                #else
                ProgressBarView(progress: progress)
                    .frame(width: playButtonWidth)
                #endif

                if let remainingText {
                    Text(remainingText)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }

            if !playItemId.isEmpty {
                #if os(iOS)
                // iOS: Play and "from beginning" share one line and split the
                // width evenly, so the resume case is a single row and the
                // secondary label gets more room than a fixed 160pt pill.
                // Without resume there's only Play — keep it pill-sized.
                if showResume {
                    HStack(spacing: CinemaSpacing.spacing3) {
                        lectureButton.frame(maxWidth: .infinity)
                        playFromBeginningButton.frame(maxWidth: .infinity)
                    }
                } else {
                    lectureButton.frame(width: playButtonWidth)
                }
                #else
                // tvOS keeps the buttons stacked (natural up/down focus order).
                lectureButton
                    .frame(width: playButtonWidth)
                    // Exposes this row's center to the parent HStack so the
                    // heart / watched accessories center on the Play button
                    // (custom alignment IDs propagate through nested stacks).
                    .alignmentGuide(.playActionRow) { $0[VerticalAlignment.center] }

                if showResume {
                    playFromBeginningButton.frame(width: playButtonWidth)
                }
                #endif
            }
        }
        .padding(.horizontal, contentPadding)
    }

    /// Primary "Lecture" CTA — resumes from `startSeconds` when present.
    private var lectureButton: some View {
        PlayLink(
            itemId: playItemId, title: playTitle, startTime: startSeconds,
            previousEpisode: epPrev, nextEpisode: epNext,
            episodeNavigator: epNavigator
        ) {
            HStack(spacing: CinemaSpacing.spacing2) {
                Text(playLabel)
                    .font(.system(size: buttonFontSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "play.fill")
                    .font(.system(size: buttonFontSize - 2, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, buttonVerticalPadding)
            .padding(.horizontal, CinemaSpacing.spacing4)
            #if os(iOS)
            .background(themeManager.accentContainer)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .accent))
        #else
        .buttonStyle(.plain)
        #endif
    }

    /// Secondary "Lire depuis le début" button — shown only in the resume case.
    private var playFromBeginningButton: some View {
        PlayLink(
            itemId: playItemId, title: playTitle, startTime: nil,
            previousEpisode: epPrev, nextEpisode: epNext,
            episodeNavigator: epNavigator
        ) {
            HStack(spacing: CinemaSpacing.spacing2) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: buttonFontSize - 2, weight: .bold))
                Text(playFromBeginningLabel)
                    .font(.system(size: buttonFontSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(CinemaColor.onSurface)
            .frame(maxWidth: .infinity)
            .padding(.vertical, buttonVerticalPadding)
            .padding(.horizontal, CinemaSpacing.spacing4)
            #if os(iOS)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
        #else
        .buttonStyle(.plain)
        #endif
    }
}


/// Vertical alignment carried by the Play ("Lecture") button's center, so
/// the heart / watched accessories in the action row line up with it no
/// matter how much resume chrome (episode label, progress bar, remaining
/// text) sits above it. Children that don't set an explicit guide fall back
/// to their own center — exactly the accessory behavior wanted.
extension VerticalAlignment {
    private enum PlayActionRow: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }
    static let playActionRow = VerticalAlignment(PlayActionRow.self)
}

// MARK: - Watch Together presentation

/// Presents the SyncPlay group sheet — a bottom sheet on iOS, a full-screen
/// cover on tvOS (`.sheet` renders as a broken narrow modal on tvOS 26). The
/// key environment objects are re-injected so the sheet's own `@Environment`
/// reads resolve regardless of automatic propagation.
private struct WatchTogetherPresentation: ViewModifier {
    @Binding var sheet: WatchTogetherIntent?
    let appState: AppState
    let themeManager: ThemeManager
    let loc: LocalizationManager
    let toast: ToastCenter
    let network: NetworkMonitor
    let onStart: (WatchTogetherIntent) -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.fullScreenCover(item: $sheet) { intent in sheetView(intent) }
        #else
        content.sheet(item: $sheet) { intent in sheetView(intent) }
        #endif
    }

    private func sheetView(_ intent: WatchTogetherIntent) -> some View {
        WatchTogetherSheet(
            itemId: intent.itemId,
            itemTitle: intent.title,
            onStart: { onStart(intent) }
        )
        .environment(appState)
        .environment(themeManager)
        .environment(loc)
        .environment(toast)
        .environment(network)
    }
}
