import SwiftUI
import CinemaxKit
import JellyfinAPI

struct HomeScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    #if os(iOS)
    @Environment(\.motionEffectsEnabled) private var motionEffects
    /// Index of the hero currently shown in the rotating carousel (iOS only —
    /// tvOS keeps a single static hero; the focus engine + `.focusSection` rules
    /// make auto-advancing focusable chrome hazardous there).
    @State private var heroIndex = 0
    #endif
    @State private var viewModel = HomeViewModel()
    @State private var prefetcher = PosterPrefetcher()

    @AppStorage(SettingsKey.homeShowContinueWatching) private var showContinueWatching: Bool = SettingsKey.Default.homeShowContinueWatching
    @AppStorage(SettingsKey.homeShowNextUp) private var showNextUp: Bool = SettingsKey.Default.homeShowNextUp
    @AppStorage(SettingsKey.homeShowRecentlyAdded) private var showRecentlyAdded: Bool = SettingsKey.Default.homeShowRecentlyAdded
    @AppStorage(SettingsKey.homeShowFavorites) private var showFavorites: Bool = SettingsKey.Default.homeShowFavorites
    @AppStorage(SettingsKey.homeShowPlaylists) private var showPlaylists: Bool = SettingsKey.Default.homeShowPlaylists
    @AppStorage(SettingsKey.homeShowUpcoming) private var showUpcoming: Bool = SettingsKey.Default.homeShowUpcoming
    @AppStorage(SettingsKey.homeShowCollections) private var showCollections: Bool = SettingsKey.Default.homeShowCollections
    @State private var deepLinkTarget: DeepLinkTarget?
    /// Drives the "View All" push from the Favorites row to `FavoritesScreen`.
    /// A token (not a Bool) so it threads through `navigationDestination(item:)`,
    /// hoisted to the screen root per the lazy-container navigation RULE.
    @State private var favoritesDestination: FavoritesDestination?
    @State private var playlistsDestination: PlaylistsDestination?
    /// One playlist, opened from a card on the rail.
    @State private var playlistDestination: PlaylistDestination?
    /// "Go to series" target raised from a card's context menu. State lives
    /// here and the destination is hoisted to the screen body: SwiftUI
    /// ignores `navigationDestination(item:)` inside a `LazyHStack`, where the
    /// cards that fire it live.
    @State private var seriesDestination: SeriesDestination?
    @AppStorage(SettingsKey.homeShowGenreRows) private var showGenreRows: Bool = SettingsKey.Default.homeShowGenreRows
    @AppStorage(SettingsKey.homeShowWatchingNow) private var showWatchingNow: Bool = SettingsKey.Default.homeShowWatchingNow
    /// Raw JSON of the user's picked genres. Held here only to observe changes
    /// made in Settings → Interface → Home page and refresh the rows live.
    @AppStorage(SettingsKey.homeSelectedGenres) private var selectedGenresJSON: String = ""

    /// Tracks whether this screen is currently on-screen so refresh
    /// notifications can be deferred while Home sits idle behind another tab
    /// (visited tabs stay alive inside `TabView`). Degrades safely: if
    /// `onDisappear` doesn't fire in some container, `isVisible` stays true and
    /// behavior falls back to today's immediate reload.
    @State private var isVisible = false
    /// Non-nil while a join round-trip is in flight, so a second press on the
    /// same card can't open two sessions.
    @State private var joiningGroupId: String?
    /// A `.cinemaxShouldRefreshCatalogue` arrived while hidden — run the full
    /// reload on next appear. Subsumes any pending userData refresh.
    @State private var pendingFullReload = false
    /// A `.cinemaxItemUserDataChanged` arrived while hidden — run the targeted
    /// rail refresh on next appear. Coalesces naturally: several while hidden
    /// collapse into one refresh on appear.
    @State private var pendingUserDataRefresh = false

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading || (isHomeEmpty && !viewModel.isFullyLoaded) {
                // Skeleton during phase-1, and kept up while a phase-1-empty
                // result is still filling later phases — the all-empty state
                // must only appear once the *entire* load finishes, never as a
                // mid-load flash (genre rows populate after the hero/rails).
                loadingSkeleton
            } else if isHomeEmpty {
                homeEmptyState
            } else {
                content
            }
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
            // Tier-1: full reload while visible, otherwise defer to next appear.
            if isVisible { performFullReload() } else { pendingFullReload = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxItemUserDataChanged)) { _ in
            // Tier-2: targeted rail refresh while visible, otherwise defer. This
            // also handles Home's own Continue Watching mutations (posted by
            // `mutateResumeItem`), so the resume rail is fetched exactly once.
            if isVisible {
                Task { await viewModel.refreshUserDataRails(using: appState) }
            } else {
                pendingUserDataRefresh = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxFavoritesChanged)) { _ in
            Task { await viewModel.refreshFavorites(using: appState) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxPlaylistsChanged)) { _ in
            Task { await viewModel.refreshPlaylists(using: appState) }
        }
        // Genre selection changed in Settings → refresh just the genre rows.
        .onChange(of: selectedGenresJSON) {
            Task { await viewModel.reloadGenreRows(using: appState) }
        }
        // Widget / Top Shelf deep link: push the item's detail. Attached at
        // the screen root (NOT inside the lazy scroll content — see the
        // lazy-container navigation RULE).
        .navigationDestination(item: $deepLinkTarget) { target in
            MediaDetailScreen(itemId: target.id, itemType: .movie)
        }
        // "View All" on the Favorites row → full favorites grid. Hoisted to the
        // screen root (NOT inside the lazy scroll content — lazy-container RULE).
        .navigationDestination(item: $favoritesDestination) { _ in
            FavoritesScreen()
        }
        // "View All" on the Playlists row → every playlist, read straight from
        // `getPlaylists` so the screen doesn't depend on the server exposing a
        // Playlists view. Same hoisting rule as above.
        .navigationDestination(item: $playlistsDestination) { _ in
            LibraryFolderBrowseScreen(
                source: .playlists,
                title: loc.localized("home.playlists"),
                isPlaylist: true
            )
            // Marked HERE, not inside the screen: the same view doubles as the
            // root of a Collections / Playlists tab, where it must not register
            // itself as its own "back" target.
            .tvPushedScreen()
        }
        // One playlist's contents, in playlist order and reorderable — its card
        // drills INTO it rather than opening an item detail.
        .navigationDestination(item: $playlistDestination) { target in
            PlaylistDetailScreen(playlistId: target.id, title: target.name)
        }
        // "Go to series" from an episode card's context menu. Hoisted to the
        // screen root for the same reason as `favoritesDestination` above.
        .seriesDestinationHost($seriesDestination)
        .onChange(of: appState.pendingDeepLinkItemId) { _, newValue in
            consumeDeepLink(newValue)
        }
        .onAppear {
            isVisible = true
            consumeDeepLink(appState.pendingDeepLinkItemId)
            // Consume any refresh deferred while hidden. A pending full reload
            // subsumes a pending targeted refresh — run only the heavier one.
            if pendingFullReload {
                pendingFullReload = false
                pendingUserDataRefresh = false
                performFullReload()
            } else if pendingUserDataRefresh {
                pendingUserDataRefresh = false
                Task { await viewModel.refreshUserDataRails(using: appState) }
            }
        }
        .onDisappear { isVisible = false }
    }

    /// Full Home reload + poster re-prefetch. Shared by the tier-1 observer and
    /// the deferred-on-appear path.
    private func performFullReload() {
        Task {
            prefetcher.reset()
            await viewModel.reload(using: appState)
            prefetchCardImages()
        }
    }

    /// Moves the pending deep link into the local push binding. `itemType`
    /// is nominal — `MediaDetailViewModel` resolves the real kind from the
    /// fetched item.
    private func consumeDeepLink(_ itemId: String?) {
        guard let itemId else { return }
        // An inbound playback request belongs to `MainTabView`'s modal route —
        // pushing it here silently fails whenever this stack already has a
        // detail on top. Same predicate on both sides, so exactly one of the
        // two observers acts. See the note on `MainTabView`'s deep-link
        // `onChange`.
        guard !appState.isPendingIntentPlayback(itemId) else { return }
        appState.pendingDeepLinkItemId = nil
        deepLinkTarget = DeepLinkTarget(id: itemId)
    }

    private struct DeepLinkTarget: Identifiable, Hashable {
        let id: String
    }

    /// Identity token for the Favorites "View All" push. A fresh instance each
    /// tap re-triggers `navigationDestination(item:)` (nil → non-nil).
    private struct PlaylistsDestination: Identifiable, Hashable {
        let id = "playlists"
    }

    private struct PlaylistDestination: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private struct FavoritesDestination: Identifiable, Hashable {
        let id = "favorites"
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

        // 16:9 backdrops — continue watching + next up (cards request maxWidth 600).
        prefetcher.prefetch((viewModel.resumeItems + viewModel.nextUpItems).map { item in
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
        CinemaTVLayout.pagePadding
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
        #if os(iOS)
        // Inert on tvOS — a remote has no pull gesture. Refresh lives in the
        // empty state's own action there.
        .refreshable { await viewModel.reload(using: appState) }
        #endif
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
                    #if os(iOS)
                    // iOS: rotating hero carousel (crossfade + swipe + dots)
                    // when there are ≥2 candidates; a single candidate renders
                    // as a plain static hero. The carousel carries the
                    // scroll-anchor `id` so the tab-bar pill heuristic is
                    // unchanged (still no leading gap above the first row).
                    //
                    // Evaluate `heroCandidates` ONCE per render and thread the
                    // result down: the property loops over resume+latest and
                    // builds a Set, and was previously recomputed here (the
                    // emptiness check), inside the carousel body, and via the
                    // index clamp.
                    let heroCandidateList = heroCandidates
                    if !heroCandidateList.isEmpty {
                        heroCarousel(heroCandidateList)
                            .id(scrollTopID)
                            .padding(.bottom, CinemaSpacing.spacing6)
                    } else {
                        Color.clear.frame(height: 0).id(scrollTopID)
                    }
                    #else
                    if let hero = viewModel.heroItem {
                        heroSection(hero)
                            .id(scrollTopID)
                            .padding(.bottom, CinemaSpacing.spacing6)
                    } else {
                        // Keep a sentinel when there is no hero so the
                        // scroll proxy still has something to target.
                        Color.clear.frame(height: 0).id(scrollTopID)
                    }
                    #endif

                    // "En direct" — Watch Together sessions AND whoever is
                    // watching alone, merged (see `LiveSessionsRow`). No longer
                    // admin-gated as a row: the SOLO half still is, inside the
                    // view model, because `/Sessions` is elevated data
                    // (jellyfin#5210); the group half is governed by the
                    // server's own per-user SyncPlay policy, so a regular
                    // account sees the sessions it may join.
                    if showWatchingNow, !viewModel.liveEntries.isEmpty {
                        watchingNowRow
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }

                    // Continue Watching
                    if showContinueWatching, !viewModel.resumeItems.isEmpty {
                        continueWatchingRow
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }

                    // Next Up (next unwatched episode per in-progress series)
                    if showNextUp, !viewModel.nextUpItems.isEmpty {
                        nextUpRow
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

                    // Playlists — next to Favorites on purpose: both are sets
                    // the user assembled themselves, and this rail is the only
                    // route to a playlist on the default menu.
                    if showPlaylists, !viewModel.playlists.isEmpty {
                        playlistsRow
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }

                    if showCollections, !viewModel.collections.isEmpty {
                        collectionsRow
                            .padding(.bottom, CinemaSpacing.spacing6)
                    }

                    if showUpcoming, !viewModel.upcomingItems.isEmpty {
                        upcomingRow
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
            #if os(iOS)
            .refreshable {
                await viewModel.reload(using: appState)
            }
            #endif
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

    // MARK: - Rotating Hero (iOS)

    #if os(iOS)
    /// Auto-advance interval for the hero carousel.
    private var heroRotationInterval: Double { 8 }

    /// Up to 5 distinct hero candidates drawn from resume + recently-added.
    /// The first entry mirrors `viewModel.heroItem` (so a single-hero server is
    /// unchanged); additional entries require a backdrop so the crossfade never
    /// flashes the plain `BackdropFallbackView`. Recomputed per render but stable
    /// by `id`, so `heroIndex` survives re-renders.
    private var heroCandidates: [BaseItemDto] {
        var seen = Set<String>()
        var out: [BaseItemDto] = []
        for item in viewModel.resumeItems + viewModel.latestItems {
            guard let id = item.id, !seen.contains(id) else { continue }
            guard out.isEmpty || item.hasBackdropImage else { continue }
            seen.insert(id)
            out.append(item)
            if out.count == 5 { break }
        }
        return out
    }

    /// Clamped so a shrinking candidate set (e.g. after a refresh) can't index
    /// out of range before `heroIndex` is reset by the rotation task.
    private var currentHeroIndex: Int {
        let count = heroCandidates.count
        guard count > 0 else { return 0 }
        return min(heroIndex, count - 1)
    }

    @ViewBuilder
    private func heroCarousel(_ candidates: [BaseItemDto]) -> some View {
        // `candidates` is the single per-render evaluation threaded from
        // `content`; clamp the index against it here instead of re-reading
        // `heroCandidates` through `currentHeroIndex` (same value — the caller
        // only renders this when `candidates` is non-empty).
        let active = candidates.isEmpty ? 0 : min(heroIndex, candidates.count - 1)
        ZStack {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { idx, item in
                if idx == active {
                    heroSection(item)
                        .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if candidates.count > 1 {
                heroPageDots(count: candidates.count, active: active)
            }
        }
        // Simultaneous (not exclusive) so button taps inside the hero still
        // land; the direction guard keeps vertical scrolls from switching heroes.
        .simultaneousGesture(heroSwipeGesture(count: candidates.count))
        // VoiceOver three-finger swipe pages the carousel (the drag gesture above
        // is invisible to assistive tech).
        .accessibilityScrollAction { edge in
            guard candidates.count > 1 else { return }
            advanceHero(forward: edge == .trailing || edge == .bottom, count: candidates.count)
        }
        // Task lifecycle is tied to the view — auto-cancels on disappear (pauses
        // rotation) and never strongly retains the screen. Restarts when the
        // candidate count or the motion-effects gate changes.
        .task(id: "\(candidates.count)-\(motionEffects)") {
            await runHeroRotation()
        }
    }

    private func heroPageDots(count: Int, active: Int) -> some View {
        HStack(spacing: CinemaSpacing.spacing1) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == active ? themeManager.accent : CinemaColor.onSurfaceVariant.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, heroPadding)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func heroSwipeGesture(count: Int) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard count > 1,
                      abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) > 50 else { return }
                advanceHero(forward: value.translation.width < 0, count: count)
            }
    }

    /// Pages the hero carousel one step, wrapping at the ends. Shared by the
    /// touch swipe gesture and the VoiceOver scroll action.
    private func advanceHero(forward: Bool, count: Int) {
        guard count > 1 else { return }
        let next = forward
            ? (currentHeroIndex + 1) % count
            : (currentHeroIndex - 1 + count) % count
        if motionEffects {
            withAnimation(.easeInOut(duration: 0.5)) { heroIndex = next }
        } else {
            heroIndex = next
        }
    }

    /// Advances the hero every `heroRotationInterval` seconds with a crossfade.
    /// No-op when Motion Effects is off (static first hero) or there's <2 heroes.
    private func runHeroRotation() async {
        guard motionEffects, heroCandidates.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(heroRotationInterval))
            guard !Task.isCancelled else { break }
            let count = heroCandidates.count
            guard count > 1 else { break }
            withAnimation(.easeInOut(duration: 0.6)) {
                heroIndex = (currentHeroIndex + 1) % count
            }
        }
    }
    #endif

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
                    #if os(tvOS)
                    .heroKenBurns()
                    #endif
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
                            // Through the resolver, not a local expression: it is
                            // the SSOT of "a residual position on a played item
                            // isn't a resume", and this card's context menu reads
                            // the same rule for its Resume / Play label.
                            let heroStart = CardPlayTargetResolver.resumeSeconds(
                                positionTicks: item.userData?.playbackPositionTicks ?? 0,
                                isPlayed: item.userData?.isPlayed ?? false
                            )
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
            // Feed the entries themselves — NEVER a snapshot of their indices.
            // `reload()` empties the underlying arrays before refetching, and
            // Observation invalidates the already-instantiated LazyHStack
            // children directly: they re-run their body against the emptied
            // array while still holding the old index snapshot, trapping with
            // "Index out of range".
            data: viewModel.liveEntries,
            id: \.id
        ) { entry in
            liveCard(entry)
                .frame(width: wideCardWidth)
        }
    }

    @ViewBuilder
    private func liveCard(_ entry: LiveSessionsRow.Entry) -> some View {
        switch entry.kind {
        case .together(let groupId):
            togetherCard(entry, groupId: groupId)
        case .solo:
            soloCard(entry)
        }
    }

    /// A Watch Together session. One card for however many people are in it —
    /// the whole reason the two sources were merged.
    ///
    /// The title can legitimately be absent: `GroupInfoDto` carries no item, so
    /// a non-admin cannot know what a group is watching until they join. The
    /// card says who, and joining is what reveals what.
    private func togetherCard(_ entry: LiveSessionsRow.Entry, groupId: String) -> some View {
        Button {
            joinLiveSession(groupId: groupId)
        } label: {
            WideCard(
                title: entry.title ?? loc.localized("syncplay.session.unknownTitle"),
                imageURL: entry.backdropItemId.map {
                    appState.imageBuilder.imageURL(
                        itemId: $0, imageType: .backdrop,
                        maxWidth: 600, tag: entry.backdropTag
                    )
                },
                progress: entry.progress ?? 0,
                subtitle: loc.localized("syncplay.session.with", participantSummary(entry.participants))
            )
            .overlay(alignment: .topLeading) { livePill(isTogether: true) }
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        // Deliberately NOT `.disabled(joiningGroupId != nil)`: a disabled control
        // is unfocusable on tvOS, so pressing a card would drop it out of the
        // focus chain for the length of the join round-trip — and on a
        // non-admin's Home, where every card in this row is a session, focus
        // would escape the row entirely and not come back. `joinLiveSession`
        // already refuses re-entry. Same lesson as `ServersScreen`, where the
        // active card stays focusable but inert.
        .accessibilityLabel(loc.localized(
            "syncplay.session.a11y",
            entry.title ?? loc.localized("syncplay.session.unknownTitle"),
            participantSummary(entry.participants)
        ))
    }

    /// Somebody watching alone. Unchanged behaviour: it opens their title.
    ///
    /// It deliberately carries no "watch with them" action yet — Jellyfin has no
    /// invitation primitive, so asking someone mid-film would have to ride
    /// `DisplayMessage`, which every other client renders as a bare toast. That
    /// belongs with the invitation lot, not here.
    @ViewBuilder
    private func soloCard(_ entry: LiveSessionsRow.Entry) -> some View {
        if let id = entry.itemId {
            NavigationLink {
                MediaDetailScreen(itemId: id, itemType: entry.itemType ?? .movie)
            } label: {
                WideCard(
                    title: entry.title ?? "",
                    imageURL: entry.backdropItemId.map {
                        appState.imageBuilder.imageURL(
                            itemId: $0, imageType: .backdrop,
                            maxWidth: 600, tag: entry.backdropTag
                        )
                    },
                    progress: entry.progress ?? 0,
                    subtitle: String(
                        format: loc.localized("home.watchingNow.playing"),
                        entry.participants.first ?? ""
                    )
                )
                .overlay(alignment: .topLeading) { livePill(isTogether: false) }
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel("\(entry.title ?? ""), \(entry.participants.first ?? "")")
        }
    }

    /// Signals that a card is a live session rather than a recommendation.
    /// Accent for a joinable session, red for someone watching alone — the
    /// colour is the difference between "come in" and "just so you know".
    private func livePill(isTogether: Bool) -> some View {
        HStack(spacing: CinemaSpacing.spacing1) {
            if isTogether {
                Image(systemName: "person.2.fill")
                    .font(.system(size: CinemaScale.pt(9), weight: .bold))
            } else {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            }
            Text(loc.localized(isTogether ? "syncplay.session.badge" : "home.liveSession"))
                .font(.system(size: CinemaScale.pt(10), weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(isTogether ? themeManager.accent : CinemaColor.onSurface)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(8)
    }

    /// "Marie", "Marie et Paul", "Marie, Paul et 2 autres" — a list of names is
    /// what makes the card an invitation rather than a statistic.
    private func participantSummary(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return loc.localized("syncplay.session.two", names[0], names[1])
        default: return loc.localized("syncplay.session.more", names[0], names[1], names.count - 2)
        }
    }

    /// Joins the group, then lets the server tell us what to open.
    ///
    /// It has to be that order: `GET /SyncPlay/List` returns no item, so the
    /// only thing that names the title is the `PlayQueue` update that arrives
    /// over the socket **after** joining. `SyncPlayController.onQueueChanged`
    /// (wired at the app root) is what turns that into a screen.
    private func joinLiveSession(groupId: String) {
        guard joiningGroupId == nil,
              let group = viewModel.syncPlayGroups.first(where: { $0.id == groupId }) else { return }
        guard SyncPlayController.isEngineSupported else {
            toast.error(loc.localized("syncplay.title"), message: loc.localized("syncplay.needsVLC"))
            return
        }
        joiningGroupId = groupId
        Task {
            let ok = await SyncPlayController.shared.joinGroup(
                group,
                api: appState.apiClient,
                loc: loc,
                toast: toast,
                currentUserName: appState.currentUser?.name
            )
            joiningGroupId = nil
            if ok { Haptics.success() }
        }
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
            // Same SSOT as the hero above and as this card's own context menu.
            let startSeconds = CardPlayTargetResolver.resumeSeconds(
                positionTicks: item.userData?.playbackPositionTicks ?? 0,
                isPlayed: item.userData?.isPlayed ?? false
            )
            let resumePercent: Int? = {
                guard let position = item.userData?.playbackPositionTicks,
                      let total = item.runTimeTicks, total > 0, position > 0 else { return nil }
                return Int((Double(position) / Double(total) * 100).rounded())
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
            // Shared menu (`MediaCardContextMenu`): play, « Play on… »,
            // watched, favorite, playlist — plus "Remove from Resume", specific
            // to this row and supplied via the callback below. Attached to the
            // PlayLink, not its label, so tvOS focus behavior is untouched.
            .mediaCardContextMenu(
                item: item,
                // This rail draws a `WideCard`, so its own artwork is the
                // backdrop — lifting a portrait poster would show a different
                // image than the card the finger is on.
                artwork: .backdrop,
                navigation: CardPlaybackNavigation(nav),
                onRemoveFromResume: {
                    Task { await viewModel.removeResumeItem(item, using: appState, toast: toast, loc: loc) }
                },
                onGoToSeries: { seriesDestination = SeriesDestination(id: $0) }
            )
            .accessibilityLabel(item.name ?? "")
            .accessibilityValue(resumePercent.map { String(format: loc.localized("accessibility.resumeProgress"), $0) } ?? "")
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

    // MARK: - Next Up

    /// Next unwatched episode for each in-progress series. Tapping a card plays
    /// the episode from the start (these are unwatched, so no resume offset).
    private var nextUpRow: some View {
        ContentRow(
            title: loc.localized("home.nextUp"),
            data: viewModel.nextUpItems,
            id: \.id
        ) { item in
            nextUpPlayLink(item)
        }
    }

    @ViewBuilder
    private func nextUpPlayLink(_ item: BaseItemDto) -> some View {
        if let id = item.id {
            let nav = viewModel.nextUpNavigation[id]
            PlayLink(
                itemId: id, title: item.name ?? "",
                previousEpisode: nav?.previous, nextEpisode: nav?.next,
                episodeNavigator: nav?.navigator
            ) {
                nextUpCard(item)
                    .frame(width: wideCardWidth)
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(item.seriesName ?? item.name ?? "")
            // On the PlayLink (the focusable button), never its label, so
            // tvOS focus is untouched.
            .mediaCardContextMenu(
                item: item,
                // `WideCard` rail — same reason as Continue Watching above.
                artwork: .backdrop,
                navigation: CardPlaybackNavigation(nav),
                onGoToSeries: { seriesDestination = SeriesDestination(id: $0) }
            )
        }
    }

    @ViewBuilder
    private func nextUpCard(_ item: BaseItemDto) -> some View {
        let cardTitle = item.seriesName ?? item.name ?? ""
        let cardSubtitle: String? = {
            var label = ""
            if let season = item.parentIndexNumber, let ep = item.indexNumber {
                label = String(format: "S%02d:E%02d", season, ep)
            }
            if let name = item.name, !name.isEmpty {
                label = label.isEmpty ? name : "\(label) - \(name)"
            }
            return label.isEmpty ? nil : label
        }()

        WideCard(
            title: cardTitle,
            imageURL: item.backdropItemID.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .backdrop, maxWidth: 600, tag: item.backdropImageTagValue) },
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
            showViewAll: true,
            onViewAll: { favoritesDestination = FavoritesDestination() },
            data: viewModel.favoriteItems,
            id: \.id
        ) { item in
            recentlyAddedCard(item)
                .frame(width: posterCardWidth)
        }
    }

    // MARK: - Playlists

    /// The user's own playlists. Cards drill into the playlist's contents, so
    /// they deliberately carry no `mediaCardContextMenu`: a playlist is a
    /// folder, and none of that menu's entries (play, watched, favorite, add to
    /// a playlist) mean anything on one — the same reason
    /// `LibraryFolderBrowseScreen` has none either.
    private var playlistsRow: some View {
        ContentRow(
            title: loc.localized("home.playlists"),
            showViewAll: true,
            onViewAll: { playlistsDestination = PlaylistsDestination() },
            data: viewModel.playlists,
            id: \.id
        ) { playlist in
            playlistCard(playlist)
                .frame(width: posterCardWidth)
        }
    }

    @ViewBuilder
    private func playlistCard(_ playlist: BaseItemDto) -> some View {
        Button {
            if let id = playlist.id {
                playlistDestination = PlaylistDestination(id: id, name: playlist.name ?? "")
            }
        } label: {
            PosterCard(
                title: playlist.name ?? loc.localized("playlist.untitled"),
                imageURL: playlist.id.map {
                    appState.imageBuilder.imageURL(
                        itemId: $0, imageType: .primary,
                        maxWidth: 300, tag: playlist.primaryImageTagValue
                    )
                },
                subtitle: playlist.childCount.map { loc.itemCount($0) }
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }

    /// The user's collections. A collection opens its own fiche — the one with
    /// the members list and "Play all" — not a scoped grid.
    private var collectionsRow: some View {
        ContentRow(
            title: loc.localized("home.collections"),
            data: viewModel.collections,
            id: \.id
        ) { collection in
            collectionCard(collection)
                .frame(width: posterCardWidth)
        }
    }

    @ViewBuilder
    private func collectionCard(_ collection: BaseItemDto) -> some View {
        NavigationLink {
            if let id = collection.id {
                MediaDetailScreen(itemId: id, itemType: .boxSet)
            }
        } label: {
            PosterCard(
                title: collection.name ?? "",
                imageURL: collection.id.map {
                    appState.imageBuilder.imageURL(
                        itemId: $0, imageType: .primary,
                        maxWidth: 300, tag: collection.primaryImageTagValue
                    )
                },
                subtitle: collection.childCount.map { loc.collectionCount($0) }
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        // No `mediaCardContextMenu`: a collection is a folder, and none of that
        // menu's entries — play, watched, favourite, add to a playlist — mean
        // anything on one. Same reason the playlists rail carries none.
    }

    /// Episodes the server expects to air soon.
    ///
    /// A calendar, not a queue: none of this exists yet, so the cards carry no
    /// Play, no progress and no context menu — only the series, the episode and
    /// the date. They still open the series fiche, which is the one useful
    /// thing to do with a title you are waiting for.
    private var upcomingRow: some View {
        ContentRow(
            title: loc.localized("home.upcoming"),
            data: viewModel.upcomingItems,
            id: \.id
        ) { episode in
            upcomingCard(episode)
                .frame(width: wideCardWidth)
        }
    }

    @ViewBuilder
    private func upcomingCard(_ episode: BaseItemDto) -> some View {
        let subtitle: String = {
            guard let date = episode.premiereDate else { return episode.name ?? "" }
            return String(
                format: loc.localized("home.upcoming.airs"),
                date.formatted(date: .abbreviated, time: .omitted)
            )
        }()

        NavigationLink {
            // The SERIES, not the episode: an unaired episode has no fiche
            // worth opening, and the series is what the user is following.
            if let id = episode.seriesID ?? episode.id {
                MediaDetailScreen(itemId: id, itemType: .series)
            }
        } label: {
            WideCard(
                title: episode.seriesName ?? episode.name ?? "",
                imageURL: episode.backdropItemID.map {
                    appState.imageBuilder.imageURL(
                        itemId: $0, imageType: .backdrop,
                        maxWidth: 600, tag: episode.backdropImageTagValue
                    )
                },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
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
                subtitle: subtitle,
                status: .make(
                    positionTicks: item.userData?.playbackPositionTicks,
                    runtimeTicks: item.runTimeTicks,
                    isPlayed: item.userData?.isPlayed
                )
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))
        // On the NavigationLink (the focusable button), never its label, so
        // tvOS focus is untouched.
        .mediaCardContextMenu(item: item, artwork: .poster)
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
        CinemaTVLayout.heroHeight
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
        CinemaTVLayout.pagePadding
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
        CinemaTVLayout.ctaLabelFontSize
        #else
        CinemaScale.pt(18)
        #endif
    }

    private var maxOverviewWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.heroOverviewMaxWidth
        #else
        300
        #endif
    }

    private var playButtonWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.heroPlayButtonWidth
        #else
        160
        #endif
    }

    private var wideCardWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.wideCardWidth
        #else
        AdaptiveLayout.wideCardWidth(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var posterCardWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.posterCardWidth
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
