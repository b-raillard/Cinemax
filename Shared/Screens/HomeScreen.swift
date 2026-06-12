import SwiftUI
import CinemaxKit
import JellyfinAPI

struct HomeScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(NetworkMonitor.self) private var network
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var viewModel = HomeViewModel()
    @State private var prefetcher = PosterPrefetcher()

    @AppStorage(SettingsKey.homeShowContinueWatching) private var showContinueWatching: Bool = SettingsKey.Default.homeShowContinueWatching
    @AppStorage(SettingsKey.homeShowRecentlyAdded) private var showRecentlyAdded: Bool = SettingsKey.Default.homeShowRecentlyAdded
    @AppStorage(SettingsKey.homeShowFavorites) private var showFavorites: Bool = SettingsKey.Default.homeShowFavorites
    @State private var deepLinkTarget: DeepLinkTarget?
    @AppStorage(SettingsKey.homeShowGenreRows) private var showGenreRows: Bool = SettingsKey.Default.homeShowGenreRows
    @AppStorage(SettingsKey.homeShowWatchingNow) private var showWatchingNow: Bool = SettingsKey.Default.homeShowWatchingNow

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            #if os(iOS)
            if !network.isOnline {
                OfflineLibraryView(scope: .all)
            } else if viewModel.isLoading {
                loadingSkeleton
            } else if isHomeEmpty {
                homeEmptyState
            } else {
                content
            }
            #else
            if viewModel.isLoading {
                loadingSkeleton
            } else if isHomeEmpty {
                homeEmptyState
            } else {
                content
            }
            #endif
        }
        #if os(iOS)
        .navigationTitle(loc.localized("tab.home"))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await viewModel.loadInitial(using: appState)
            prefetchCardImages()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            Task {
                prefetcher.reset()
                await viewModel.reload(using: appState)
                prefetchCardImages()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxFavoritesChanged)) { _ in
            Task { await viewModel.refreshFavorites(using: appState) }
        }
        // Widget / Top Shelf deep link: push the item's detail. Attached at
        // the screen root (NOT inside the lazy scroll content — see the
        // lazy-container navigation RULE).
        .navigationDestination(item: $deepLinkTarget) { target in
            MediaDetailScreen(itemId: target.id, itemType: .movie)
        }
        .onChange(of: appState.pendingDeepLinkItemId) { _, newValue in
            consumeDeepLink(newValue)
        }
        .onAppear {
            consumeDeepLink(appState.pendingDeepLinkItemId)
        }
    }

    /// Moves the pending deep link into the local push binding. `itemType`
    /// is nominal — `MediaDetailViewModel` resolves the real kind from the
    /// fetched item.
    private func consumeDeepLink(_ itemId: String?) {
        guard let itemId else { return }
        appState.pendingDeepLinkItemId = nil
        deepLinkTarget = DeepLinkTarget(id: itemId)
    }

    private struct DeepLinkTarget: Identifiable, Hashable {
        let id: String
    }

    /// Warms Nuke's cache for every card the loaded rows will render. URLs
    /// mirror the cards' own requests exactly (same `maxWidth` + `tag`) —
    /// a parameter mismatch would warm a different cache entry (see
    /// `PosterPrefetcher`). Cheap to call repeatedly: already-seen URLs are
    /// deduped inside the prefetcher.
    private func prefetchCardImages() {
        let builder = appState.imageBuilder

        // 2:3 posters — recently added, favorites, genre rows (cards request maxWidth 300).
        var posterItems = viewModel.latestItems + viewModel.favoriteItems
        for row in viewModel.genreRows {
            if case .items(let items) = row.state { posterItems += items }
        }
        prefetcher.prefetch(posterItems.map { item in
            item.id.map { builder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) }
        })

        // 16:9 backdrops — continue watching (cards request maxWidth 600).
        prefetcher.prefetch(viewModel.resumeItems.map { item in
            item.backdropItemID.map { builder.imageURL(itemId: $0, imageType: .backdrop, maxWidth: 600, tag: item.backdropImageTagValue) }
        })
    }

    /// True when there's no hero, no resume items, no recently added items, and no genre rows.
    /// Happens on a fresh Jellyfin install or a server with no media.
    private var isHomeEmpty: Bool {
        viewModel.heroItem == nil
            && viewModel.resumeItems.isEmpty
            && viewModel.latestItems.isEmpty
            && viewModel.genreRows.isEmpty
    }

    /// Layout-shaped placeholder shown during the initial load — sketches the
    /// hero + continue-watching + poster rows the real content will occupy.
    private var loadingSkeleton: some View {
        MediaPageSkeleton(
            heroHeight: heroHeight,
            rows: [.wide, .poster],
            posterCardWidth: posterCardWidth,
            wideCardWidth: wideCardWidth,
            horizontalPadding: skeletonPadding
        )
    }

    private var skeletonPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        CinemaSpacing.spacing6
        #endif
    }

    private var homeEmptyState: some View {
        ScrollView {
            EmptyStateView(
                systemImage: "tv.slash",
                title: loc.localized("empty.home.title"),
                subtitle: loc.localized("empty.home.subtitle"),
                actionTitle: loc.localized("action.refresh")
            ) {
                Task { await viewModel.reload(using: appState) }
            }
            .padding(.top, CinemaSpacing.spacing20)
        }
        .refreshable { await viewModel.reload(using: appState) }
    }

    private var content: some View {
        // Wrap in `ScrollViewReader` so that on tvOS we can scroll back to the
        // top sentinel whenever the screen reappears (after a deep-nav pop or
        // tab switch). Without this the tvOS top tab bar can be hidden behind
        // scrolled content and the user can't reach it with the remote.
        ScrollViewReader { proxy in
            ScrollView {
                // `spacing: 0` so the first row (hero) touches the scroll
                // view's top edge (= the safe-area top under the tvOS tab
                // bar). tvOS 26's Liquid Glass tab bar uses the gap above
                // the first row as a heuristic to switch between its
                // "expanded" (pill bottom-aligned) and "compact" (pill
                // top-aligned) modes — a non-zero leading gap pulls the
                // pill upward, making the menu appear higher than on
                // Films/Recherche/Réglages whose first row sits flush
                // against the safe-area top. Inter-row spacing is restored
                // via `.padding(.bottom)` on each row below.
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Hero — also carries the scroll-anchor `id` so
                    // `proxy.scrollTo(scrollTopID)` aligns the hero's top
                    // with the safe-area top (no separate 0-height
                    // sentinel, which would add an unwanted spacing-gap
                    // above the hero — see tab bar heuristic above).
                    if let hero = viewModel.heroItem {
                        heroSection(hero)
                            .id(scrollTopID)
                            .padding(.bottom, CinemaSpacing.spacing6)
                    } else {
                        // Keep a sentinel when there is no hero so the
                        // scroll proxy still has something to target.
                        Color.clear.frame(height: 0).id(scrollTopID)
                    }

                    // Watching Now (other users on the server) — admin-only:
                    // surfaces who else is streaming, which is elevated data
                    // (see HomeViewModel.loadActiveSessions / jellyfin#5210).
                    if appState.isAdministrator, showWatchingNow, !viewModel.activeSessions.isEmpty {
                        watchingNowRow
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }

                    // Continue Watching
                    if showContinueWatching, !viewModel.resumeItems.isEmpty {
                        continueWatchingRow
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }

                    // Recently Added
                    if showRecentlyAdded, !viewModel.latestItems.isEmpty {
                        recentlyAddedRow
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }

                    // Favorites
                    if showFavorites, !viewModel.favoriteItems.isEmpty {
                        favoritesRow
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }

                    // Genre rows
                    if showGenreRows {
                        ForEach(viewModel.genreRows) { row in
                            switch row.state {
                            case .items(let items):
                                genreRow(genre: row.genre, items: items)
                                    .padding(.bottom, CinemaSpacing.spacing6)
                            case .failed:
                                genreRowFailed(genre: row.genre)
                                    .padding(.bottom, CinemaSpacing.spacing6)
                            }
                        }
                    }

                    Spacer(minLength: 80)
                }
            }
            .refreshable {
                await viewModel.reload(using: appState)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            .onAppear {
                // Returning from a deep navigation (e.g., MediaDetail → Menu) —
                // reveal the top tab bar by scrolling to the sentinel.
                proxy.scrollTo(scrollTopID, anchor: .top)
            }
            #endif
        }
    }

    private var scrollTopID: String { "home.top" }

    // MARK: - Genre Rows

    @ViewBuilder
    private func genreRow(genre: String, items: [BaseItemDto]) -> some View {
        ContentRow(title: genre, data: items, id: \.id) { item in
            recentlyAddedCard(item)
                .frame(width: posterCardWidth)
        }
    }

    /// Failure-state pill shown in place of an unloadable genre row. Tap to
    /// re-fetch only that row. Keeps the row's title so the user knows which
    /// genre is retrying.
    @ViewBuilder
    private func genreRowFailed(genre: String) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Text(genre)
                .font(CinemaFont.headline(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.horizontal, CinemaSpacing.spacing6)

            Button {
                Task { await viewModel.retryGenre(genre, using: appState) }
            } label: {
                HStack(spacing: CinemaSpacing.spacing2) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    Text(loc.localized("home.genreRow.failed"))
                        .font(CinemaFont.label(.medium))
                    Text("·")
                        .foregroundStyle(CinemaColor.outlineVariant)
                    Text(loc.localized("action.retry"))
                        .font(CinemaFont.label(.medium))
                        .fontWeight(.semibold)
                }
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.vertical, CinemaSpacing.spacing2)
                .background(CinemaColor.surfaceContainer)
                .clipShape(Capsule())
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
            #else
            .buttonStyle(.plain)
            #endif
            .padding(.horizontal, CinemaSpacing.spacing6)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(_ item: BaseItemDto) -> some View {
        // `Color.clear` sizing driver pinned to `heroHeight`, with backdrop, gradient,
        // and content layered as overlays. Overlays can't grow the parent frame — so
        // the hero is guaranteed to be exactly `heroHeight` regardless of what the
        // backdrop or content try to do. Prevents the iPad-landscape regression where
        // ZStack sized from the CinemaLazyImage's natural dimensions and pushed the
        // action buttons off-screen.
        Color.clear
            .frame(maxWidth: .infinity)
            #if os(tvOS)
            .frame(height: heroHeight)
            #else
            // iPad hardening: in a short window (Stage Manager, Split View
            // landscape) a fixed 500pt hero can swallow the whole viewport.
            // Clamp to ~60% of the scroll viewport's height; full-screen
            // iPhone/iPad resolve to the regular `heroHeight` (the min wins).
            .containerRelativeFrame(.vertical) { length, _ in
                min(heroHeight, length * 0.62)
            }
            #endif
            .overlay {
                if item.hasBackdropImage, let backdropId = item.backdropItemID {
                    CinemaLazyImage(
                        url: appState.imageBuilder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: ImageURLBuilder.backdropPixelWidth, tag: item.backdropImageTagValue),
                        fallbackIcon: nil,
                        fallbackBackground: CinemaColor.surfaceContainerLow
                    )
                    .accessibilityHidden(true)
                } else {
                    BackdropFallbackView()
                }
            }
            .overlay { CinemaGradient.heroOverlay.allowsHitTesting(false) }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: heroPadding > 60 ? 16 : 10) {
                    HStack(spacing: 8) {
                        if let rating = item.officialRating {
                            RatingBadge(rating: rating)
                        }

                        metadataText(for: item)
                    }
                    .foregroundStyle(CinemaColor.onSurfaceVariant)

                    Text(item.name ?? "")
                        .font(.system(size: heroTitleSize, weight: .black))
                        .tracking(-1.5)
                        .foregroundStyle(.white)
                        .textCase(.uppercase)
                        .lineLimit(2)

                    #if os(tvOS)
                    if let overview = item.overview {
                        Text(overview)
                            .font(.system(size: overviewFontSize))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(3)
                            .frame(maxWidth: maxOverviewWidth, alignment: .leading)
                    }
                    #endif

                    HStack(spacing: 12) {
                        if let id = item.id {
                            let heroNav = viewModel.resumeNavigation[id]
                            let heroStart: Double? = {
                                guard let ticks = item.userData?.playbackPositionTicks, ticks > 0 else { return nil }
                                return Double(ticks) / 10_000_000
                            }()
                            PlayLink(
                                itemId: id, title: item.name ?? "",
                                startTime: heroStart,
                                previousEpisode: heroNav?.previous, nextEpisode: heroNav?.next,
                                episodeNavigator: heroNav?.navigator
                            ) {
                                HStack(spacing: CinemaSpacing.spacing2) {
                                    Text(loc.localized("action.play"))
                                        .font(.system(size: heroButtonFontSize, weight: .bold))
                                    Image(systemName: "play.fill")
                                        .font(.system(size: heroButtonFontSize - 2, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, heroPadding > 60 ? CinemaSpacing.spacing4 : CinemaSpacing.spacing2)
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
                            .frame(width: playButtonWidth)
                            .accessibilityLabel(String(format: loc.localized("accessibility.playItem"), item.name ?? ""))

                            NavigationLink {
                                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                            } label: {
                                HStack(spacing: CinemaSpacing.spacing2) {
                                    Text(loc.localized("action.moreInfo"))
                                        .font(.system(size: heroButtonFontSize, weight: .bold))
                                        .lineLimit(1)
                                    Image(systemName: "info.circle")
                                        .font(.system(size: heroButtonFontSize - 2, weight: .bold))
                                }
                                .foregroundStyle(CinemaColor.onSurface)
                                .padding(.vertical, heroPadding > 60 ? CinemaSpacing.spacing4 : CinemaSpacing.spacing2)
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
                            .fixedSize()
                            .accessibilityLabel(String(format: loc.localized("accessibility.moreInfoAbout"), item.name ?? ""))
                        }
                    }
                    #if os(tvOS)
                    // Discrete focus section so up-presses from Play / More Info
                    // can escape the bottom-aligned overlay and reach the tab
                    // bar instead of getting trapped inside the hero bounds.
                    .focusSection()
                    #endif
                }
                .padding(.horizontal, heroPadding)
                .padding(.bottom, heroPadding + CinemaSpacing.spacing6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipped()
    }

    // MARK: - Continue Watching

    // MARK: - Watching Now (other users)

    /// Small row showing other server users' active playback sessions. Each card shows
    /// the item artwork + "Name is watching" label, and navigates to the item's detail
    /// screen on tap. Hidden entirely when the server has no other active sessions.
    private var watchingNowRow: some View {
        ContentRow(
            title: loc.localized("home.watchingNow"),
            data: Array(viewModel.activeSessions.indices),
            id: \.self
        ) { idx in
            watchingNowCard(viewModel.activeSessions[idx])
                .frame(width: wideCardWidth)
        }
    }

    @ViewBuilder
    private func watchingNowCard(_ session: SessionInfoDto) -> some View {
        if let item = session.nowPlayingItem, let id = item.id {
            // Episodes → use parent series for backdrop; fall back to the episode itself.
            let backdropId = item.backdropItemID ?? id
            let title = (item.seriesName ?? item.name) ?? ""
            let subtitle = String(format: loc.localized("home.watchingNow.playing"), session.userName ?? "")

            NavigationLink {
                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
            } label: {
                WideCard(
                    title: title,
                    imageURL: appState.imageBuilder.imageURL(itemId: backdropId, imageType: .backdrop, maxWidth: 600, tag: item.backdropImageTagValue),
                    progress: sessionProgress(session),
                    subtitle: subtitle
                )
                .overlay(alignment: .topLeading) {
                    // Small red "LIVE" pill to signal this is a session, not a recommendation.
                    HStack(spacing: CinemaSpacing.spacing1) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text(loc.localized("home.liveSession"))
                            .font(.system(size: CinemaScale.pt(10), weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                }
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel("\(title), \(subtitle)")
        }
    }

    private func sessionProgress(_ session: SessionInfoDto) -> Double {
        guard let position = session.playState?.positionTicks,
              let total = session.nowPlayingItem?.runTimeTicks,
              total > 0 else { return 0 }
        return min(1.0, Double(position) / Double(total))
    }

    private var continueWatchingRow: some View {
        ContentRow(
            title: loc.localized("home.continueWatching"),
            data: viewModel.resumeItems,
            id: \.id
        ) { item in
            continueWatchingPlayLink(item)
        }
    }

    @ViewBuilder
    private func continueWatchingPlayLink(_ item: BaseItemDto) -> some View {
        if let id = item.id {
            let nav = viewModel.resumeNavigation[id]
            let startSeconds: Double? = {
                guard let ticks = item.userData?.playbackPositionTicks, ticks > 0 else { return nil }
                return Double(ticks) / 10_000_000
            }()
            PlayLink(
                itemId: id, title: item.name ?? "",
                startTime: startSeconds,
                previousEpisode: nav?.previous, nextEpisode: nav?.next,
                episodeNavigator: nav?.navigator
            ) {
                continueWatchingCard(item)
                    .frame(width: wideCardWidth)
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(item.name ?? "")
        }
    }

    @ViewBuilder
    private func continueWatchingCard(_ item: BaseItemDto) -> some View {
        let progress: Double = {
            guard let position = item.userData?.playbackPositionTicks,
                  let total = item.runTimeTicks,
                  total > 0 else { return 0 }
            return Double(position) / Double(total)
        }()

        let isEpisode = item.type == .episode

        let cardTitle: String = isEpisode
            ? (item.seriesName ?? item.name ?? "")
            : (item.name ?? "")

        let cardSubtitle: String? = {
            if isEpisode {
                var label = ""
                if let season = item.parentIndexNumber, let ep = item.indexNumber {
                    label = String(format: "S%02d:E%02d", season, ep)
                }
                if let name = item.name, !name.isEmpty {
                    label = label.isEmpty ? name : "\(label) - \(name)"
                }
                return label.isEmpty ? nil : label
            } else {
                guard let position = item.userData?.playbackPositionTicks,
                      let total = item.runTimeTicks else { return nil }
                let remainingTicks = total - position
                return loc.remainingTime(minutes: remainingTicks.jellyfinMinutes)
            }
        }()

        WideCard(
            title: cardTitle,
            imageURL: item.backdropItemID.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .backdrop, maxWidth: 600, tag: item.backdropImageTagValue) },
            progress: progress,
            subtitle: cardSubtitle
        )
    }

    // MARK: - Recently Added

    private var recentlyAddedRow: some View {
        ContentRow(
            title: loc.localized("home.recentlyAdded"),
            data: viewModel.latestItems,
            id: \.id
        ) { item in
            recentlyAddedCard(item)
                .frame(width: posterCardWidth)
        }
    }

    // MARK: - Favorites

    /// Hearted movies/series — same card chrome as Recently Added.
    private var favoritesRow: some View {
        ContentRow(
            title: loc.localized("home.favorites"),
            data: viewModel.favoriteItems,
            id: \.id
        ) { item in
            recentlyAddedCard(item)
                .frame(width: posterCardWidth)
        }
    }

    @ViewBuilder
    private func recentlyAddedCard(_ item: BaseItemDto) -> some View {
        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if let type = item.type { parts.append(type.rawValue) }
            return parts.joined(separator: " · ")
        }()

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: - Helpers

    private func metadataText(for item: BaseItemDto) -> some View {
        let parts: [String] = [
            item.productionYear.map(String.init),
            item.formattedRuntime,
            item.genres?.first
        ].compactMap { $0 }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: metadataFontSize, weight: .medium))
    }

    // MARK: - Adaptive Sizing

    private var heroHeight: CGFloat {
        #if os(tvOS)
        820
        #else
        AdaptiveLayout.heroHeight(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var heroTitleSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(72)
        #else
        CinemaScale.pt(20)
        #endif
    }

    private var overviewFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(18)
        #else
        CinemaScale.pt(14)
        #endif
    }

    private var heroPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        // Under 60 intentionally — the hero's "big-button" branch triggers above 60 (tvOS only).
        AdaptiveLayout.form(horizontalSizeClass: sizeClass) == .regular
            ? CinemaSpacing.spacing6
            : CinemaSpacing.spacing4
        #endif
    }

    /// Mirrors `LibraryHeroSection.heroButtonFontSize` / `MediaDetailScreen.buttonFontSize`.
    /// tvOS 28 is the documented Play-label exception (bare literal inside a computed var).
    private var heroButtonFontSize: CGFloat {
        #if os(tvOS)
        28
        #else
        CinemaScale.pt(18)
        #endif
    }

    private var maxOverviewWidth: CGFloat {
        #if os(tvOS)
        600
        #else
        300
        #endif
    }

    private var playButtonWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        160
        #endif
    }

    private var wideCardWidth: CGFloat {
        #if os(tvOS)
        400
        #else
        AdaptiveLayout.wideCardWidth(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var posterCardWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        AdaptiveLayout.posterCardWidth(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var metadataFontSize: CGFloat {
        #if os(tvOS)
        16
        #else
        13
        #endif
    }
}
