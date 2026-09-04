import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - Unified Media Library Screen

struct MediaLibraryScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var viewModel: MediaLibraryViewModel
    @State private var prefetcher = PosterPrefetcher()
    @State private var showSortFilter = false
    #if os(iOS)
    /// Lifted from `AdminItemMenu` so `navigationDestination(item:)` can
    /// live outside the lazy grid/row hosting the poster cards. The menu
    /// fires `onSelectDestination(_:)` and the card forwards it via
    /// `onAdminAction:` — we bind the resulting `AdminMenuPushIntent`
    /// here and host the destination on the body's outer ZStack.
    @State private var adminPushIntent: AdminMenuPushIntent?
    #endif
    /// In-flight A–Z re-anchor. Both platforms: on iOS a finger sliding down
    /// the bar must cancel the previous letter's fetch instead of racing it
    /// (the drag fires on every letter it crosses), and on tvOS a user walking
    /// the chip strip does the same thing one click at a time.
    @State private var jumpTask: Task<Void, Never>?
    /// Browse ("By genre") vs flat grid ("Show all") landing layout. Honored on
    /// both platforms; the toggle lives in Settings → Appearance.
    @AppStorage(SettingsKey.libraryBrowseLayout) private var libraryBrowseLayout: String = SettingsKey.Default.libraryBrowseLayout

    /// Tracks whether this tab is on-screen so refresh notifications can be
    /// deferred while it sits alive-but-hidden inside `TabView` — the biggest
    /// win here, since every visited library tab otherwise re-runs its genre
    /// fan-out on any catalogue notification. Degrades safely: if `onDisappear`
    /// doesn't fire, `isVisible` stays true and behavior is today's immediate
    /// reload.
    @State private var isVisible = false
    /// A refresh notification (tier-1 or tier-2) arrived while hidden — run one
    /// reload on next appear. Several while hidden collapse into one.
    @State private var pendingReload = false
    /// Tier-2 counterpart of `pendingReload`. A pending full reload subsumes
    /// this one, and repeated tier-2 events while hidden coalesce into one.
    @State private var pendingUserDataRefresh = false

    /// `nil` for library tabs of Other / Mixed kind — disables the
    /// `includeItemTypes` filter at query time so every item in the parent
    /// folder surfaces. The screen still needs a concrete kind for layout
    /// decisions in sub-components; those default to `.movie` via the
    /// `displayKind` helper.
    let itemType: BaseItemKind?
    /// When non-nil, all queries scope to a specific Jellyfin library
    /// (a.k.a. user view) — used by the custom-menu library mode so each
    /// library tab fetches only its own contents. The override title
    /// surfaces the library name in place of the generic "Movies" / "TV Shows".
    let parentId: String?
    let overrideTitle: String?

    init(
        itemType: BaseItemKind?,
        parentId: String? = nil,
        overrideTitle: String? = nil
    ) {
        self.itemType = itemType
        self.parentId = parentId
        self.overrideTitle = overrideTitle
        _viewModel = State(initialValue: MediaLibraryViewModel(itemType: itemType, parentId: parentId))
    }

    /// Concrete kind used for layout fall-back (hero aspect ratios, poster
    /// styles, sub-component APIs that require a `BaseItemKind`). Defaults
    /// to `.movie` for mixed / Other libraries — same poster ratio as
    /// series, so the visual cost of being wrong is small.
    private var displayKind: BaseItemKind { itemType ?? .movie }

    private var screenTitle: String {
        if let overrideTitle { return overrideTitle }
        return itemType == .series ? loc.localized("tvShows.title") : loc.localized("movies.title")
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else {
                mainContent
            }
        }
        #if os(iOS)
        // Lifted out of `AdminItemMenu` so SwiftUI honors it — the menu's
        // host (`LibraryPosterCard`) lives inside `LazyVGrid`/`LazyHStack`,
        // and SwiftUI silently ignores `navigationDestination` placed
        // inside lazy containers. The outer ZStack here is eager.
        .navigationDestination(item: $adminPushIntent) { intent in
            adminMenuPushDestination(for: intent)
        }
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                filterButton
            }
        }
        .sheet(isPresented: $showSortFilter) {
            makeSortFilterSheet()
        }
        #else
        // tvOS: use `.fullScreenCover`. `.sheet` renders as a narrow centered
        // modal with a broken NavigationStack toolbar — see the bug we fixed
        // by giving the sheet its own tvOS body in `LibrarySortFilterSheet`.
        .fullScreenCover(isPresented: $showSortFilter) {
            makeSortFilterSheet()
                .environment(themeManager)
                .environment(loc)
        }
        #endif
        .task {
            await viewModel.loadInitial(using: appState, loc: loc)
            prefetchBrowsePosters()
        }
        // Each filtered page that lands gets its posters warmed; the count is
        // a cheap Equatable proxy for "a page was appended".
        .onChange(of: viewModel.filteredLoader.items.count) {
            prefetchPosters(for: viewModel.filteredLoader.items)
        }
        // The two tiers refresh DIFFERENTLY, and both defer while hidden.
        // Tier-1 is an explicit "the catalogue changed" — a full reload is what
        // the user asked for. Tier-2 is one item's userData, raised by this
        // grid's OWN context menu, so it must refresh in place: a full reload
        // resets the paginated loader to page 0 and yanks a deeply-scrolled
        // grid back to the top under the user's finger.
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxShouldRefreshCatalogue)) { _ in
            reloadOrDefer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cinemaxItemUserDataChanged)) { _ in
            refreshUserDataOrDefer()
        }
        .onAppear {
            isVisible = true
            if pendingReload {
                pendingReload = false
                pendingUserDataRefresh = false // subsumed by the full reload
                performReload() // re-derives `heroPlay` on its own
            } else if pendingUserDataRefresh {
                pendingUserDataRefresh = false
                performUserDataRefresh()
            }
        }
        .onDisappear { isVisible = false }
    }

    /// Reloads immediately if the tab is visible, otherwise records the intent
    /// to reload on next appear.
    private func reloadOrDefer() {
        if isVisible { performReload() } else { pendingReload = true }
    }

    /// Tier-2 sibling of `reloadOrDefer`. Neither branch may flip `isLoading`:
    /// that swaps the body for `loadingView`, which tears the `ScrollView` down
    /// and rebuilds it — the user loses their scroll position under their own
    /// finger, since the notification is raised by this screen's OWN card menu.
    ///
    /// The browse layout (hero + genre rows) has exactly one userData-dependent
    /// piece, the hero's play target: `LibraryPosterCard` draws neither a watched
    /// badge nor a progress bar, so the full reload this used to do refetched the
    /// hero and fanned out up to 8 genre rows to change zero pixels. The filtered
    /// grid takes the in-place span refresh.
    private func refreshUserDataOrDefer() {
        guard isVisible else {
            pendingUserDataRefresh = true
            return
        }
        performUserDataRefresh()
    }

    /// Re-derives the hero's play target. Cheap, silent and idempotent — a no-op
    /// unless the hero is a series, and its probes are 10 s-cached. See
    /// `MediaLibraryViewModel.refreshHeroNavigation`.
    private func refreshHeroNavigation() {
        Task { await viewModel.refreshHeroNavigation(using: appState) }
    }

    /// The tier-2 refresh itself, and the SOLE owner of the browse-vs-grid split.
    ///
    /// Both entry points funnel here — the immediate one and the deferred one
    /// consumed by `.onAppear` — precisely so they cannot diverge. They did: the
    /// deferred path used to run the span refresh unconditionally, which is a
    /// silent no-op in browse layout (empty paginated span), so a tier-2 event
    /// that arrived while the tab was hidden left the hero stale.
    ///
    /// Neither branch may flip `isLoading`: that swaps the body for
    /// `loadingView`, tearing the `ScrollView` down and dropping the user's
    /// scroll position.
    ///
    /// **RULE — the split asks `shouldShowFilteredView`, the authoritative
    /// predicate of the layout, NEVER `filteredLoader.items.isEmpty`.** The
    /// loader is not a proxy for what is on screen and diverges from it in both
    /// directions: `LibrarySortFilterSheet` calls `onApply` from all four of its
    /// exits — "Réinitialiser" included — and `applyFilter` resets then reloads
    /// 40 *unfiltered* items without ever consulting `isFiltered`, so merely
    /// validating the sheet populates a grid nothing displays, permanently for
    /// the life of the view model; conversely that same `reset()` empties the
    /// loader while a grid IS displayed. Measured on device 2026-08-19: two
    /// gestures (open the sheet, press Appliquer, nothing changed) left the
    /// hero's play target frozen, so its Play button reopened an episode the
    /// user had just finished — defect A, reopened. `refreshHeroNavigation()`
    /// is this branch's only production caller since #114 removed the
    /// unconditional `.onAppear` hook that used to mask it.
    private func performUserDataRefresh() {
        if !shouldShowFilteredView {
            // Browse layout: the only userData-dependent piece is the hero's
            // play target — `LibraryPosterCard` draws neither a watched badge
            // nor a progress bar.
            refreshHeroNavigation()
        } else {
            // Filtered grid: refresh the loaded span in place. No prefetch reset
            // — item identity is preserved, so warmed posters stay valid.
            Task { await viewModel.refreshUserData(using: appState) }
        }
    }

    /// Full library reload + poster re-prefetch. Shared by the refresh observers
    /// and the deferred-on-appear path.
    private func performReload() {
        Task {
            prefetcher.reset()
            await viewModel.reload(using: appState, loc: loc)
            prefetchBrowsePosters()
        }
    }

    // MARK: - Image prefetch

    /// Warms every genre row's posters once the browse data is in. URLs match
    /// `LibraryPosterCard`'s request exactly (primary, maxWidth 300, tag).
    private func prefetchBrowsePosters() {
        prefetchPosters(for: viewModel.itemsByGenre.values.flatMap { $0 })
    }

    private func prefetchPosters(for items: [BaseItemDto]) {
        let builder = appState.imageBuilder
        prefetcher.prefetch(items.map { item in
            item.id.map { builder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue) }
        })
    }

    // MARK: Main Content Switch

    @ViewBuilder
    private var mainContent: some View {
        if shouldShowFilteredView {
            filteredView
        } else {
            browseView
        }
    }

    /// Filtered grid is shown when:
    /// - tvOS: any active *filter*, OR the user opted into the flat grid layout
    ///   ("Show all") in Settings → Appearance. Sort changes alone don't switch
    ///   out of browse.
    /// - iOS: any non-default state (sort or filter), OR the user opted into the
    ///   flat grid layout ("Show all"). The sort sheet flipping to grid is the
    ///   existing iOS behavior; the layout toggle additionally forces grid even
    ///   in the pristine default state.
    private var shouldShowFilteredView: Bool {
        #if os(tvOS)
        if viewModel.sortFilter.isFiltered { return true }
        #else
        if viewModel.sortFilter.isNonDefault { return true }
        #endif
        return LibraryBrowseLayout(rawValue: libraryBrowseLayout) == .grid
    }

    // MARK: Browse View (hero + genre rows + browse-genres grid)

    /// Shared between iOS and tvOS. tvOS additionally wraps the content in a
    /// `ScrollViewReader` so we can scroll back to the `library.top` anchor
    /// when the screen reappears (reveals the top tab bar after deep nav).
    private var browseView: some View {
        #if os(tvOS)
        ScrollViewReader { proxy in
            ScrollView {
                browseStack
            }
            .scrollClipDisabled()
            // No `.refreshable` — a remote has no pull gesture, so the
            // modifier only reads as if a refresh were on offer. Settings →
            // "Refresh catalogue" is the single trigger on tvOS.
            .task(id: viewModel.sortFilter) {
                if !viewModel.genres.isEmpty {
                    await viewModel.reloadGenreItems(using: appState)
                }
            }
            .onAppear { proxy.scrollTo("library.top", anchor: .top) }
        }
        #else
        ScrollView {
            browseStack
        }
        .refreshable { await viewModel.reload(using: appState, loc: loc) }
        #endif
    }

    /// Vertical stack shared by iOS and tvOS browse views. tvOS prepends the
    /// compact top bar (sort menu + filters button + count) so it sits above
    /// the hero; iOS uses the navigation toolbar instead.
    @ViewBuilder
    private var browseStack: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            #if os(tvOS)
            Color.clear.frame(height: 0).id("library.top")
            tvTopBar
                .padding(.bottom, CinemaSpacing.spacing4)
            #endif

            if let hero = viewModel.heroItem {
                LibraryHeroSection(item: hero, itemType: displayKind, heroPlay: viewModel.heroPlay)
                    .padding(.bottom, CinemaSpacing.spacing6)
            }

            ForEach(viewModel.genres.prefix(viewModel.genreLoadLimit), id: \.self) { genre in
                if let items = viewModel.itemsByGenre[genre], !items.isEmpty {
                    #if os(iOS)
                    LibraryGenreRow(
                        genre: genre,
                        items: items,
                        itemType: displayKind,
                        onViewAll: {
                            viewModel.sortFilter.selectedGenres = [genre]
                        },
                        onAdminAction: { item, dest in
                            adminPushIntent = AdminMenuPushIntent(item: item, destination: dest)
                        }
                    )
                    .padding(.bottom, CinemaSpacing.spacing6)
                    #else
                    LibraryGenreRow(genre: genre, items: items, itemType: displayKind) {
                        viewModel.sortFilter.selectedGenres = [genre]
                    }
                    .padding(.bottom, CinemaSpacing.spacing6)
                    #endif
                }
            }

            if !viewModel.genres.isEmpty {
                browseGenresSection
                    .padding(.bottom, CinemaSpacing.spacing6)
            }

            Spacer(minLength: 80)
        }
    }

    // MARK: Filtered View (iOS)

    private var filteredColumns: [GridItem] {
        #if os(tvOS)
        CinemaTVLayout.posterGridColumns
        #else
        AdaptiveLayout.posterGridColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var filteredView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // **RULE — plain `VStack`, NEVER `LazyVStack`.** This stack has
                // at most four children (the count header, one of the three
                // content branches, and a trailing `Spacer`); the hundreds of
                // cards live in the `LazyVGrid` below, which is already lazy.
                // Nesting the grid inside a *lazy* stack made the whole screen
                // render nothing at all after a tab round-trip once ~3 pages
                // were paged in — measured on device 2026-08-20: Films →
                // "Non vus uniquement" → ~9 flicks → Accueil → Films left a
                // black screen with no count header, no cards, no empty state,
                // no skeleton and no error, and **no way back**: a second tab
                // round-trip, scrolling up, pull-to-refresh and re-applying the
                // filter all failed, so only relaunching restored the tab. The
                // data was never the problem (the sheet still read the filter
                // correctly and a refresh still issued its requests) — the
                // screen's SwiftUI subgraph stopped rebuilding, which is why
                // even the unconditional header vanished. Reproduced 3/3 above
                // the threshold, never at 0 or 5 flicks. Nesting two lazy
                // containers with hundreds of children is what the tab switch's
                // `UIHostingController` re-hosting cannot survive.
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    #if os(tvOS)
                    Color.clear.frame(height: 0).id("library.top")
                    tvTopBar
                    if shouldShowJumpBar {
                        tvLetterStrip(proxy: proxy)
                    }
                    #else
                    Text(filteredCountLabel)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.horizontal, gridPadding)
                    #endif

                    if viewModel.filteredLoader.items.isEmpty && viewModel.filteredLoader.isLoadingMore {
                        filteredLoadingState
                    } else if viewModel.filteredLoader.items.isEmpty {
                        filteredEmptyState
                    } else {
                        LazyVGrid(columns: filteredColumns, spacing: gridSpacing) {
                            ForEach(viewModel.filteredLoader.items, id: \.id) { item in
                                #if os(iOS)
                                LibraryPosterCard(
                                    item: item,
                                    itemType: displayKind,
                                    onAdminAction: { item, dest in
                                        adminPushIntent = AdminMenuPushIntent(item: item, destination: dest)
                                    }
                                )
                                .id(item.id)
                                .onAppear { maybeLoadMore(triggerId: item.id) }
                                #else
                                LibraryPosterCard(item: item, itemType: displayKind)
                                    .id(item.id)
                                    .onAppear { maybeLoadMore(triggerId: item.id) }
                                #endif
                            }
                        }
                        .padding(.horizontal, gridPadding)

                        if viewModel.filteredLoader.isLoadingMore {
                            filteredPaginationFooter
                        }
                    }

                    Spacer(minLength: 80)
                }
                .padding(.top, CinemaSpacing.spacing3)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #else
            .refreshable {
                await viewModel.reload(using: appState, loc: loc)
            }
            #endif
            .task(id: viewModel.sortFilter) {
                await viewModel.applyFilter(using: appState)
            }
            #if os(tvOS)
            .onAppear { proxy.scrollTo("library.top", anchor: .top) }
            #endif
            #if os(iOS)
            .overlay(alignment: .trailing) {
                if shouldShowJumpBar {
                    AlphabeticalJumpBar(
                        accent: themeManager.accent,
                        onSelect: { letter in jump(to: letter, proxy: proxy) }
                    )
                    .padding(.trailing, CinemaSpacing.spacing2)
                }
            }
            #endif
        }
    }

    // MARK: - tvOS Compact Top Bar

    #if os(tvOS)
    /// The A–Z jump, as a remote can aim it.
    ///
    /// iOS overlays a thin vertical strip of letters sized for a thumb tracking
    /// down the screen's edge — a gesture that does not exist here. The same
    /// machinery (`jump`, and the server-side re-anchor behind it) drives a
    /// horizontal row of focusable chips instead: one click per letter, and the
    /// row reads like a keyboard row rather than a target to hit.
    ///
    /// Its own focus section, so a Down press from it lands in the grid rather
    /// than travelling along the letters.
    private func tvLetterStrip(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: CinemaSpacing.spacing2) {
                ForEach(AlphabeticalJump.letters, id: \.self) { letter in
                    Button {
                        _ = jump(to: letter, proxy: proxy)
                    } label: {
                        Text(letter)
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                            .frame(minWidth: 52)
                            .padding(.vertical, CinemaSpacing.spacing2)
                            .background(CinemaColor.surfaceContainerHigh, in: Capsule())
                    }
                    .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
                    .focusEffectDisabled()
                    .hoverEffectDisabled()
                    .accessibilityLabel(letter)
                }
            }
            .padding(.horizontal, CinemaTVLayout.pagePadding)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    /// Compact top bar that replaces the previous full-screen filter wall:
    /// title + count on the left, sort menu and filters button on the right.
    /// Filter detail (chips for watch status / decade / genre) lives inside
    /// the shared `LibrarySortFilterSheet` — one focusable button reaches
    /// all of it, freeing the entire viewport for posters and the hero.
    private var tvTopBar: some View {
        HStack(alignment: .center, spacing: CinemaSpacing.spacing4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(screenTitle)
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .accessibilityAddTraits(.isHeader)

                Text(loc.localized("movies.titles", viewModel.sortFilter.isFiltered ? viewModel.filteredLoader.totalCount : viewModel.totalCount))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }

            Spacer()

            tvSortButton
            tvFilterSheetButton
        }
        .padding(.vertical, CinemaSpacing.spacing3)
        .padding(.horizontal, CinemaSpacing.spacing5)
        // A surface of its own: the bar floats directly over the hero backdrop,
        // so its title and count read against whatever image happens to be
        // behind them. Glass rather than an opaque fill, which would cut a
        // hard band across the top of the hero.
        .glassPanel(cornerRadius: CinemaRadius.large)
        .padding(.horizontal, CinemaTVLayout.pagePadding)
        // Group sort/filter as a discrete focus section so up-presses from the
        // hero's Play/More Info row reliably bridge the ~700pt of empty hero
        // backdrop and land on the top bar (and ultimately escape upward to
        // the tab bar) instead of getting absorbed by the hero's own bounds.
        .focusSection()
    }

    /// Shows the current sort and opens the sort-and-filter sheet.
    ///
    /// It used to raise a `confirmationDialog` of its own, so sorting and
    /// filtering — one job — had two different idioms, and the sheet titled
    /// "Trier et filtrer" could not in fact sort. The button survives because
    /// it is the only place the CURRENT sort is legible without opening
    /// anything; only its destination changed.
    private var tvSortButton: some View {
        Button {
            showSortFilter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                Text(currentSortLabel)
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(CinemaColor.onSurface)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(Capsule())
        }
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
    }

    /// Opens `LibrarySortFilterSheet` (full-screen overlay on tvOS). Active
    /// state mirrors iOS: filled icon + accent background + numeric badge
    /// when filters are applied.
    private var tvFilterSheetButton: some View {
        let isActive = viewModel.sortFilter.isFiltered
        return Button {
            showSortFilter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle\(isActive ? ".fill" : "")")
                    .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                Text(loc.localized("library.filter.button"))
                    .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                if isActive {
                    Text("\(activeFilterCount)")
                        .font(.system(size: CinemaScale.pt(14), weight: .bold))
                        .foregroundStyle(themeManager.onAccent)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Circle().fill(CinemaColor.onSurface.opacity(0.25)))
                }
            }
            .foregroundStyle(isActive ? themeManager.onAccent : CinemaColor.onSurface)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(isActive ? themeManager.accentContainer : CinemaColor.surfaceContainerHigh)
            .clipShape(Capsule())
        }
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
    }

    /// Label shown on the sort button — current field + direction arrow.
    private var currentSortLabel: String {
        let fieldLabel: String
        switch viewModel.sortFilter.sortBy {
        case .dateCreated:     fieldLabel = loc.localized("sort.dateAdded")
        case .sortName:        fieldLabel = loc.localized("sort.name")
        case .productionYear:  fieldLabel = loc.localized("sort.releaseYear")
        case .communityRating: fieldLabel = loc.localized("sort.rating")
        default:               fieldLabel = loc.localized("sort.dateAdded")
        }
        return "\(fieldLabel) \(viewModel.sortFilter.sortAscending ? "↑" : "↓")"
    }

    /// Count of active filters shown as a numeric badge on the filters button.
    private var activeFilterCount: Int {
        viewModel.sortFilter.selectedGenres.count
            + viewModel.sortFilter.selectedDecades.count
            + (viewModel.sortFilter.showUnwatchedOnly ? 1 : 0)
    }
    #endif

    // MARK: - Browse Genres Section

    private var browseGenresSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Text(loc.localized("tvShows.browseGenres"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.horizontal, browseGenresPadding)
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: browseGenresColumns, spacing: CinemaSpacing.spacing3) {
                ForEach(viewModel.genres, id: \.self) { genre in
                    genreCard(genre)
                }
            }
            .padding(.horizontal, browseGenresPadding)
        }
    }

    @ViewBuilder
    private func genreCard(_ genre: String) -> some View {
        Button {
            viewModel.sortFilter.selectedGenres = [genre]
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                    .fill(CinemaColor.surfaceContainerHigh)

                Text(genre)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .multilineTextAlignment(.center)
                    .padding(CinemaSpacing.spacing4)
            }
            .frame(height: genreCardHeight)
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }

    // MARK: - Pagination Trigger

    /// Guards pagination against SwiftUI calling `.onAppear` multiple times for the
    /// same card (view recycling, off-screen-and-back, parent re-renders). Previously
    /// each call spawned a Task that queued behind `PaginatedLoader`'s actor guard —
    /// correct but wasteful. Now we check `isLoadingMore` / `hasLoadedAll`
    /// synchronously before spawning, so redundant onAppears are free.
    private func maybeLoadMore(triggerId: String?) {
        let loader = viewModel.filteredLoader
        guard !loader.isLoadingMore,
              !loader.hasLoadedAll,
              let triggerId,
              triggerId == loader.items.last?.id else { return }
        Task { await viewModel.loadMoreFiltered(using: appState) }
    }

    // MARK: - Filter Button (iOS toolbar)

    #if os(iOS)
    /// iOS 26 navigation-bar toolbar items are rendered with Liquid Glass
    /// automatically — adding `.buttonStyle(.glass)` here would nest a glass
    /// capsule inside the toolbar's own glass container. Active-state signal
    /// is the `.fill` icon variant + accent tint on the label.
    @ViewBuilder
    private var filterButton: some View {
        let button = Button {
            showSortFilter = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle\(viewModel.sortFilter.isNonDefault ? ".fill" : "")")
                    .font(.system(size: filterIconSize, weight: .semibold))
                Text(loc.localized("movies.sortFilter"))
                    .font(.system(size: filterLabelSize, weight: .semibold))
                if viewModel.sortFilter.isFiltered {
                    let filterCount =
                        viewModel.sortFilter.selectedGenres.count
                        + viewModel.sortFilter.selectedDecades.count
                        + (viewModel.sortFilter.showUnwatchedOnly ? 1 : 0)
                    ZStack {
                        Circle()
                            .fill(CinemaColor.onSurface.opacity(0.25))
                        Text("\(filterCount)")
                            .font(.system(size: CinemaScale.pt(11), weight: .bold))
                    }
                    .frame(width: 20, height: 20)
                }
            }
        }

        if viewModel.sortFilter.isNonDefault {
            button.tint(themeManager.accent)
        } else {
            button
        }
    }
    #endif

    // MARK: - Loading & Error

    /// Layout-shaped placeholder for the initial load — mirrors the browse
    /// view's hero + poster rows instead of a context-free spinner.
    private var loadingView: some View {
        MediaPageSkeleton(
            heroHeight: skeletonHeroHeight,
            rows: [.poster, .poster],
            posterCardWidth: skeletonPosterWidth,
            wideCardWidth: skeletonPosterWidth * 2,
            horizontalPadding: browseGenresPadding
        )
    }

    private var skeletonHeroHeight: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.heroHeight
        #else
        AdaptiveLayout.heroHeight(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var skeletonPosterWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.posterCardWidth
        #else
        AdaptiveLayout.posterCardWidth(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private func errorView(_ message: String) -> some View {
        ErrorStateView(message: message, retryTitle: loc.localized("action.retry")) {
            // `reload` (not `loadInitial`) — `loadInitial` latches `hasLoaded`
            // on success and is a no-op once attempted, so Retry must go through
            // the reload path that always re-fetches.
            Task { await viewModel.reload(using: appState, loc: loc) }
        }
    }

    // MARK: - Empty States

    // MARK: - Alphabetical Jump Bar (iOS)

    /// Only shown when the filtered view is actually alphabetically meaningful:
    /// the user has sorted by name ascending. Other sorts (date added, year, rating)
    /// wouldn't produce a coherent A→Z scroll.
    private var shouldShowJumpBar: Bool {
        viewModel.sortFilter.sortBy == .sortName
            && viewModel.sortFilter.sortAscending
            // The SET's size, not how much of it is paged in: anchoring near Z
            // can leave a handful of loaded items, and keying on that made the
            // bar vanish exactly where the user needs it to get back.
            && viewModel.displayedTotalCount > 20
    }

    /// "503 films" — plus "from M" whenever the grid is anchored, so a list
    /// that starts in the middle reads as a deliberate jump rather than as
    /// missing titles.
    private var filteredCountLabel: String {
        // A Mixed / Other library has no `itemType`, and calling its contents
        // "films" would simply be wrong — those tabs get the neutral wording.
        let total = viewModel.displayedTotalCount
        let count: String
        switch itemType {
        case .series: count = loc.localized("tvShows.count", total)
        case .movie:  count = loc.localized("movies.count", total)
        default:      count = loc.itemCount(total)
        }
        guard let anchor = viewModel.letterAnchor else { return count }
        return count + " · " + loc.localized("library.anchoredAt", anchor)
    }

    /// Handles one A–Z tap. Returns whether it led somewhere — the bar's haptic
    /// keys on the answer.
    ///
    /// Two paths, cheapest first: a letter already among the loaded pages is a
    /// pure scroll with no request; anything else re-anchors the grid on the
    /// server (see `MediaLibraryViewModel.anchorGrid`). Before this, the second
    /// path did not exist and the tap was simply swallowed.
    private func jump(to letter: String, proxy: ScrollViewProxy) -> Bool {
        if let target = firstItemID(for: letter) {
            withAnimation { proxy.scrollTo(target, anchor: .top) }
            return true
        }
        jumpTask?.cancel()
        jumpTask = Task {
            let moved = await viewModel.anchorGrid(atLetter: letter, using: appState)
            guard moved, !Task.isCancelled else { return }
            guard let first = viewModel.filteredLoader.items.first?.id else { return }
            withAnimation { proxy.scrollTo(first, anchor: .top) }
        }
        return true
    }

    /// Returns the id of the first loaded item whose name begins with the given letter.
    /// "#" targets the first item starting with a digit or non-letter character.
    private func firstItemID(for letter: String) -> String? {
        let target = letter.uppercased()
        for item in viewModel.filteredLoader.items {
            guard let name = item.name else { continue }
            let first = String(name.prefix(1)).uppercased()
            if target == "#" {
                if first.first.map({ !$0.isLetter }) ?? false { return item.id }
            } else if first == target {
                return item.id
            }
        }
        return nil
    }

    /// Shown in the filtered grid (iOS or tvOS) when the current sort/filter combination
    /// yields no results. Offers a "Clear filters" action that resets sort + filter state.
    private var filteredEmptyState: some View {
        EmptyStateView(
            systemImage: "line.3.horizontal.decrease.circle",
            title: loc.localized("empty.library.filtered.title"),
            subtitle: loc.localized("empty.library.filtered.subtitle"),
            actionTitle: loc.localized("empty.library.filtered.action")
        ) {
            viewModel.sortFilter = LibrarySortFilterState()
        }
    }

    /// Shown in place of the filtered grid on the *initial* load (items still empty,
    /// `isLoadingMore` is true). Pairs the spinner with an explanatory label so the
    /// UI doesn't look like a hung fetch.
    private var filteredLoadingState: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            ProgressView()
                .tint(CinemaColor.onSurfaceVariant)
                .scaleEffect(1.3)
            Text(loc.localized(itemType == .series ? "library.loading.series" : "library.loading.movies"))
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CinemaSpacing.spacing10)
    }

    /// Footer row under the filtered grid when paginating additional pages. Keeps the
    /// visual continuity of the grid instead of centering a mid-screen spinner.
    private var filteredPaginationFooter: some View {
        ProgressView()
            .tint(CinemaColor.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, CinemaSpacing.spacing6)
    }

    // MARK: - Sort & Filter Sheet

    private func makeSortFilterSheet() -> LibrarySortFilterSheet {
        LibrarySortFilterSheet(
            sortFilter: Binding(
                get: { viewModel.sortFilter },
                set: { viewModel.sortFilter = $0 }
            ),
            onApply: { Task { await viewModel.applyFilter(using: appState) } },
            availableGenres: viewModel.genres
        )
    }

    // MARK: - Adaptive Sizing

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pagePadding
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.gridGutter
        #else
        16
        #endif
    }

    #if os(iOS)
    private var filterIconSize: CGFloat { CinemaScale.pt(16) }
    private var filterLabelSize: CGFloat { CinemaScale.pt(14) }
    #endif

    private var genreCardHeight: CGFloat {
        #if os(tvOS)
        100
        #else
        72
        #endif
    }

    private var browseGenresPadding: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pagePadding
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var browseGenresColumns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing3), count: 4)
        #else
        AdaptiveLayout.browseGenreColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }
}

