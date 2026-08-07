import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - View

struct SearchScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @FocusState private var searchFieldFocused: Bool
    #endif
    @State private var viewModel = SearchViewModel()
    @AppStorage(SettingsKey.searchSaveHistory) private var saveSearchHistory: Bool = SettingsKey.Default.searchSaveHistory

    // Surprise Me state — two buttons (movie + series) in the empty state.
    @State private var surpriseDestination: SurpriseDestination?
    @State private var isPickingSurpriseMovie = false
    @State private var isPickingSurpriseSeries = false
    /// "Go to series" target raised from a result card's context menu. State
    /// lives here and the destination is hoisted to the screen body: SwiftUI
    /// ignores `navigationDestination(item:)` inside the results `LazyVGrid`,
    /// where the cards that fire it live.
    @State private var seriesDestination: SeriesDestination?

    private struct SurpriseDestination: Identifiable, Hashable {
        let id: String
        let itemType: BaseItemKind
    }

    /// Runs a search term raised by an App Intent, exactly once.
    ///
    /// Writing `searchText` also updates the visible field, so the user can see
    /// and edit what Siri heard rather than facing an unexplained result set.
    /// `search(using:)` cancels any in-flight task, so the write's own
    /// `onChange` and this call collapse into one query.
    private func consumeIntentSearchRequest() {
        guard let query = appState.pendingIntentSearchQuery else { return }
        appState.pendingIntentSearchQuery = nil
        viewModel.searchText = query
        viewModel.search(using: appState)
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        AdaptiveLayout.posterGridColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            #if os(tvOS)
            // tvOS path is wrapped in a ScrollView + ScrollViewReader so we can
            // force the page back to the top whenever it reappears (e.g., user
            // pops back from a result detail). This is what surfaces the tvOS
            // top tab bar — it stays hidden when content overlaps its area.
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("search.top")
                    VStack(spacing: 0) {
                        searchField
                        filterChips
                        resultContent
                    }
                    .frame(maxWidth: .infinity, minHeight: 720, maxHeight: .infinity)
                }
                .scrollClipDisabled()
                .onAppear {
                    proxy.scrollTo("search.top", anchor: .top)
                }
            }
            #else
            // iOS: native `.searchable()` is the iOS 26 HIG-compliant pattern.
            // The search field lives in the navigation bar (auto-presented by
            // `Tab(role: .search)`) and integrates with system dictation,
            // Spotlight, and keyboard. Voice search is exposed as a leading
            // toolbar button. The body renders results / empty / listening states.
            VStack(spacing: 0) {
                filterChips
                resultContent
            }
            #endif
        }
        .navigationDestination(item: $surpriseDestination) { dest in
            MediaDetailScreen(itemId: dest.id, itemType: dest.itemType)
        }
        // "Go to series" from an episode result card's context menu. Hoisted
        // to the screen root, same reason as `surpriseDestination` above.
        .seriesDestinationHost($seriesDestination)
        // An App Intent can raise a term either before this screen exists (the
        // tab is switched to afterwards) or while it's already on screen, so
        // both arrival orders are covered.
        .task { consumeIntentSearchRequest() }
        .onChange(of: appState.pendingIntentSearchQuery) { _, _ in
            consumeIntentSearchRequest()
        }
        #if os(iOS)
        .navigationTitle(loc.localized("search.title"))
        .searchable(
            text: Bindable(viewModel).searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(loc.localized("search.placeholder"))
        )
        .searchFocused($searchFieldFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: viewModel.searchText) {
            viewModel.search(using: appState)
        }
        .toolbar {
            // Voice mic — trailing toolbar item, paired with the native search
            // field's clear button. The mic is a separate `ToolbarItem` so it
            // sits above the search drawer and isn't tied to the field's
            // trailing accessory area.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.toggleListening(using: appState)
                } label: {
                    if viewModel.isListening {
                        // Expand into a labelled pill so the listening state is
                        // self-explanatory. iOS 26 wraps toolbar buttons in Liquid
                        // Glass automatically — no explicit capsule/`.glass` style
                        // (that would nest a second capsule). The pulsing mic doubles
                        // as a "we're capturing sound" cue.
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                                .symbolEffect(.pulse, options: .repeating, isActive: motionEffects)
                            Text(loc.localized("search.listening"))
                                .font(CinemaFont.label(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(themeManager.accent)
                    } else {
                        Image(systemName: "mic")
                            .foregroundStyle(CinemaColor.onSurface)
                    }
                }
                .accessibilityLabel(viewModel.isListening
                    ? loc.localized("accessibility.stopVoiceSearch")
                    : loc.localized("accessibility.voiceSearch"))
            }
        }
        .background {
            // ⌘F focuses the search field. Hidden button → keyboard-only affordance.
            Button("") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .alert(loc.localized("search.permissionRequired"), isPresented: Bindable(viewModel).showPermissionAlert) {
            Button(loc.localized("search.openSettings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized(viewModel.permissionError?.localizationKey ?? "search.voice.unavailable"))
        }
        .onDisappear {
            // Stop any active recognition session when leaving the screen
            if viewModel.isListening {
                viewModel.stopListening()
            }
        }
        #endif
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .font(.system(size: searchIconSize))
                .accessibilityHidden(true)

            TextField(loc.localized("search.placeholder"), text: Bindable(viewModel).searchText)
                #if os(iOS)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                #endif
                .font(.system(size: searchFontSize))
                .foregroundStyle(CinemaColor.onSurface)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: viewModel.searchText) {
                    viewModel.search(using: appState)
                }

            // Microphone button — iOS only
            #if os(iOS)
            VoiceSearchButton(
                isListening: viewModel.isListening,
                iconSize: searchIconSize,
                onTap: { viewModel.toggleListening(using: appState) }
            )
            #endif

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    viewModel.results = []
                    viewModel.hasSearched = false
                    #if os(iOS)
                    if viewModel.isListening {
                        viewModel.stopListening()
                    }
                    #endif
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.localized("accessibility.clearSearch"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CinemaColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        .padding(.horizontal, gridPadding)
        .padding(.vertical, CinemaSpacing.spacing3)
    }

    // MARK: - Filter chips (All / Movies / Series)

    /// Result-type scope chips. Shown once a search is under way so the user can
    /// narrow (or re-widen) results without retyping; changing scope re-runs the
    /// current query via `viewModel.search`.
    @ViewBuilder
    private var filterChips: some View {
        if viewModel.hasSearched || !viewModel.results.isEmpty {
            HStack(spacing: CinemaSpacing.spacing2) {
                ForEach(SearchScope.allCases) { scope in
                    filterChip(scope)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, gridPadding)
            .padding(.bottom, CinemaSpacing.spacing3)
        }
    }

    private func filterChip(_ scope: SearchScope) -> some View {
        let isSelected = viewModel.scope == scope
        return Button {
            guard viewModel.scope != scope else { return }
            viewModel.scope = scope
            viewModel.search(using: appState)
        } label: {
            Text(loc.localized(scope.localizationKey))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurfaceVariant)
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.vertical, CinemaSpacing.spacing2)
                .background(
                    isSelected ? themeManager.accentContainer : CinemaColor.surfaceContainerHigh,
                    in: Capsule()
                )
        }
        #if os(tvOS)
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(loc.localized(scope.localizationKey))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultContent: some View {
        if viewModel.isSearching {
            Spacer()
            LoadingStateView()
            Spacer()
        } else if viewModel.searchFailed && viewModel.hasSearched {
            // Distinct from "no results": the fetch never reached the server, so
            // offer a retry rather than implying the library has no matches.
            Spacer()
            ErrorStateView(
                message: loc.localized("search.error.network"),
                retryTitle: loc.localized("action.retry")
            ) {
                viewModel.search(using: appState)
            }
            Spacer()
        // Person matches alone are a result: typing an actor's name that matches
        // no title is the primary use case for the row, so both collections have
        // to be empty before this reads as "nothing found".
        } else if viewModel.results.isEmpty && viewModel.personResults.isEmpty && viewModel.hasSearched {
            Spacer()
            VStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: CinemaScale.pt(48)))
                    .foregroundStyle(CinemaColor.outlineVariant)
                    .accessibilityHidden(true)
                Text(loc.localized("search.noResults"))
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            Spacer()
        } else if viewModel.results.isEmpty && viewModel.personResults.isEmpty {
            Spacer()
            VStack(spacing: CinemaSpacing.spacing4) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: CinemaScale.pt(48)))
                    .foregroundStyle(CinemaColor.outlineVariant)
                    .accessibilityHidden(true)
                Text(loc.localized("search.searchLibrary"))
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)

                // Past queries as one-tap chips (gated on the Privacy toggle).
                if saveSearchHistory, !viewModel.recentSearches.isEmpty {
                    recentSearchesSection
                }

                // "Not sure what to watch?" → two pills for a random movie or series.
                surpriseMePills
            }
            Spacer()
        } else {
            SearchResultsGrid(
                results: viewModel.results,
                people: viewModel.personResults,
                imageBuilder: appState.imageBuilder,
                columns: columns,
                gridPadding: gridPadding,
                gridSpacing: gridSpacing,
                headerTitle: loc.localized("search.topMatches"),
                peopleTitle: loc.localized("search.people"),
                onGoToSeries: { seriesDestination = SeriesDestination(id: $0) }
            )
            // Without this the `Equatable` conformance is inert — SwiftUI only
            // consults a custom `==` when the view is wrapped in `.equatable()`.
            .equatable()
        }
    }

    // MARK: - Recent Searches

    /// Wrapping chip cloud of past queries + a trailing "clear" chip. A chip
    /// tap re-runs the query by writing `searchText` (the existing `.onChange`
    /// debounce path picks it up — no separate search trigger needed).
    private var recentSearchesSection: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            Text(loc.localized("search.recent"))
                .font(CinemaFont.dynamicLabel(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)

            FlowLayout(spacing: CinemaSpacing.spacing2) {
                ForEach(viewModel.recentSearches, id: \.self) { term in
                    recentSearchChip(term)
                }

                Button {
                    viewModel.clearRecentSearches()
                } label: {
                    HStack(spacing: CinemaSpacing.spacing1) {
                        Image(systemName: "xmark")
                            .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                        Text(loc.localized("search.recent.clear"))
                            .font(CinemaFont.label(.medium))
                    }
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.horizontal, CinemaSpacing.spacing3)
                    .padding(.vertical, CinemaSpacing.spacing2)
                    .background(CinemaColor.surfaceContainer)
                    .clipShape(Capsule())
                }
                #if os(tvOS)
                .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
                .focusEffectDisabled()
                .hoverEffectDisabled()
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityLabel(loc.localized("accessibility.clearRecentSearches"))
            }
            .frame(maxWidth: recentSearchesMaxWidth)
        }
        .padding(.horizontal, gridPadding)
    }

    private func recentSearchChip(_ term: String) -> some View {
        Button {
            viewModel.searchText = term
        } label: {
            HStack(spacing: CinemaSpacing.spacing1) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: CinemaScale.pt(12)))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Text(term)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(1)
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(Capsule())
        }
        #if os(tvOS)
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(String(format: loc.localized("accessibility.searchAgainFor"), term))
    }

    private var recentSearchesMaxWidth: CGFloat {
        #if os(tvOS)
        800
        #else
        420
        #endif
    }

    // MARK: - Surprise Me

    private var surpriseMePills: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            Text(loc.localized("search.surpriseMePrompt"))
                .font(CinemaFont.dynamicLabel(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)

            HStack(spacing: CinemaSpacing.spacing3) {
                surprisePill(
                    label: loc.localized("search.surprise.movie"),
                    icon: "film.fill",
                    isLoading: isPickingSurpriseMovie
                ) {
                    await performSurprise(type: .movie)
                }
                surprisePill(
                    label: loc.localized("search.surprise.series"),
                    icon: "tv.fill",
                    isLoading: isPickingSurpriseSeries
                ) {
                    await performSurprise(type: .series)
                }
            }
        }
        .padding(.top, CinemaSpacing.spacing4)
    }

    @ViewBuilder
    private func surprisePill(label: String, icon: String, isLoading: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: CinemaSpacing.spacing2) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: surpriseIconSize, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: surpriseLabelSize, weight: .semibold))
            }
            .foregroundStyle(themeManager.onAccent)
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .background(themeManager.accentContainer)
            .clipShape(Capsule())
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .accent))
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(isLoading)
        .accessibilityLabel(label)
    }

    private func performSurprise(type: BaseItemKind) async {
        if type == .movie { isPickingSurpriseMovie = true }
        else { isPickingSurpriseSeries = true }
        defer {
            if type == .movie { isPickingSurpriseMovie = false }
            else { isPickingSurpriseSeries = false }
        }

        let item: BaseItemDto?
        switch type {
        case .movie:  item = await viewModel.fetchRandomMovie(using: appState)
        case .series: item = await viewModel.fetchRandomSeries(using: appState)
        default:      item = nil
        }

        guard let item, let id = item.id else {
            toasts.error(
                loc.localized("toast.surprise.failed"),
                message: loc.localized("toast.surprise.emptyLibrary")
            )
            return
        }
        surpriseDestination = SurpriseDestination(id: id, itemType: item.type ?? type)
    }

    private var surpriseIconSize: CGFloat {
        #if os(tvOS)
        24
        #else
        16
        #endif
    }

    private var surpriseLabelSize: CGFloat {
        #if os(tvOS)
        22
        #else
        15
        #endif
    }

    // MARK: - Sizing

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        32
        #else
        16
        #endif
    }

    private var searchFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(24)
        #else
        CinemaScale.pt(17)
        #endif
    }

    private var searchIconSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(22)
        #else
        CinemaScale.pt(17)
        #endif
    }
}

// MARK: - Voice Search Button (iOS only)

#if os(iOS)
/// Microphone pill with a pulsing accent ring while listening. Owns its own
/// pulsing state so the parent doesn't need to track animation flags.
private struct VoiceSearchButton: View {
    let isListening: Bool
    let iconSize: CGFloat
    let onTap: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @State private var isPulsing = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isListening {
                    Circle()
                        .fill(themeManager.accent.opacity(0.25))
                        .frame(width: isPulsing ? 36 : 28, height: isPulsing ? 36 : 28)
                        .animation(
                            motionEffects
                                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                : nil,
                            value: isPulsing
                        )
                }

                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(isListening ? themeManager.accent : CinemaColor.onSurfaceVariant)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening
            ? loc.localized("accessibility.stopVoiceSearch")
            : loc.localized("accessibility.voiceSearch"))
        .onChange(of: isListening) { _, newValue in
            isPulsing = newValue
        }
    }
}
#endif

// MARK: - Results Grid

/// LazyVGrid of search results. Kept as a standalone `View` so SwiftUI's
/// diff can skip re-rendering the grid when parent state (surprise-me flags,
/// pulsing, etc.) changes but the results array itself hasn't.
/// Equatable so a keystroke that leaves the result set unchanged doesn't rebuild
/// every visible card.
///
/// Without this, the `onGoToSeries` closure below made both this view and
/// `SearchResultCard` permanently un-skippable: SwiftUI treats a function-typed
/// stored property as unconditionally unequal, so "same value ⇒ skip `body`"
/// could never fire again. `SearchScreen.body` re-evaluates on every keystroke
/// (it reads `searchText`), which meant every visible card re-ran its body — a
/// poster URL build plus, before the menu was split into its own views, an
/// entire context-menu tree. The `==` ignores the closure, exactly as
/// `MediaDetailSimilarSection` and `PlayActionButtonsSection` do.
private struct SearchResultsGrid: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // SwiftUI diffs on the main actor — `assumeIsolated` lets us read the
        // non-Sendable `BaseItemDto` payload here (escape hatch #4).
        MainActor.assumeIsolated {
            guard lhs.columns.count == rhs.columns.count,
                  lhs.gridPadding == rhs.gridPadding,
                  lhs.gridSpacing == rhs.gridSpacing,
                  lhs.headerTitle == rhs.headerTitle,
                  lhs.peopleTitle == rhs.peopleTitle,
                  lhs.results.count == rhs.results.count,
                  lhs.people.count == rhs.people.count else { return false }
            for (a, b) in zip(lhs.results, rhs.results) {
                if a.id != b.id || a.name != b.name || a.primaryImageTagValue != b.primaryImageTagValue { return false }
            }
            for (a, b) in zip(lhs.people, rhs.people) {
                if a.id != b.id || a.name != b.name { return false }
            }
            return true
        }
    }

    let results: [BaseItemDto]
    /// Person matches. Empty ⇒ no row at all: an orphan "People" heading over
    /// nothing is a visual bug, and most searches target a title.
    let people: [BaseItemDto]
    let imageBuilder: ImageURLBuilder
    let columns: [GridItem]
    let gridPadding: CGFloat
    let gridSpacing: CGFloat
    let headerTitle: String
    let peopleTitle: String
    /// Passed down to `SearchResultCard`, which invokes it to bubble the
    /// event up to `SearchScreen`'s screen-level destination — see the
    /// "Go to series" state above.
    let onGoToSeries: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                // Inside the grid's own ScrollView, so the row scrolls away with
                // the results instead of staying pinned above them.
                if !people.isEmpty {
                    SearchPersonRow(
                        people: people,
                        imageBuilder: imageBuilder,
                        title: peopleTitle,
                        horizontalPadding: gridPadding
                    )
                }

                // Symmetrical to the person row: a person-only match must not
                // leave a "Top matches" heading standing over an empty grid.
                if !results.isEmpty {
                    Text(headerTitle)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.horizontal, gridPadding)
                        .accessibilityAddTraits(.isHeader)

                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        ForEach(results, id: \.id) { item in
                            SearchResultCard(item: item, imageBuilder: imageBuilder, onGoToSeries: onGoToSeries)
                                .equatable()
                        }
                    }
                    .padding(.horizontal, gridPadding)
                }

                Spacer(minLength: 80)
            }
        }
    }
}

/// Horizontal row of person matches, above the poster grid.
///
/// Hand-rolled rather than reusing `ContentRow`: that component hardcodes
/// `spacing6` horizontal padding, while this screen's grid uses `gridPadding`
/// (`spacing20` on tvOS) — the row would sit visibly out of line with the
/// posters underneath it.
private struct SearchPersonRow: View {
    let people: [BaseItemDto]
    let imageBuilder: ImageURLBuilder
    let title: String
    let horizontalPadding: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            // Matches the grid's own "Top matches" heading, not ContentRow's
            // larger one — the two sit in the same visual context.
            Text(title)
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .padding(.horizontal, horizontalPadding)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                    ForEach(people, id: \.id) { person in
                        personLink(person)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                #if os(tvOS)
                .padding(.vertical, CinemaSpacing.spacing2)
                #endif
            }
            // The focused portrait scales to 1.06 on tvOS — without this the
            // edge card is clipped by the scroll view's bounds.
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    @ViewBuilder
    private func personLink(_ person: BaseItemDto) -> some View {
        if let id = person.id {
            // Plain `NavigationLink` (not `navigationDestination(item:)`) — a
            // lazy stack silently ignores the modifier form.
            NavigationLink {
                PersonDetailScreen(personId: id, personName: person.name ?? "")
            } label: {
                CastCircle(
                    name: person.name ?? "",
                    imageURL: imageBuilder.imageURL(
                        itemId: id, imageType: .primary, maxWidth: 200,
                        tag: person.primaryImageTagValue
                    )
                )
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(person.name ?? "")
        }
    }
}

/// Equatable for the same reason as `SearchResultsGrid` — see the note there.
private struct SearchResultCard: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.item.id == rhs.item.id
                && lhs.item.name == rhs.item.name
                && lhs.item.type == rhs.item.type
                && lhs.item.productionYear == rhs.item.productionYear
                && lhs.item.primaryImageTagValue == rhs.item.primaryImageTagValue
                && lhs.item.userData?.isPlayed == rhs.item.userData?.isPlayed
                && lhs.item.userData?.isFavorite == rhs.item.userData?.isFavorite
        }
    }

    let item: BaseItemDto
    let imageBuilder: ImageURLBuilder
    /// Passed down from `SearchResultsGrid`; invoked here to bubble the
    /// event up to `SearchScreen` — see `mediaCardContextMenu`'s
    /// "Go to series" contract.
    let onGoToSeries: (String) -> Void

    var body: some View {
        let subtitle = Self.subtitle(for: item)

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map {
                    imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue)
                },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(
            [item.name, subtitle.isEmpty ? nil : subtitle]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        // Long-press / long-press-select watched + favorite actions, on the
        // NavigationLink (the focusable button) not its label — see
        // `mediaCardContextMenu`.
        .mediaCardContextMenu(
            item: item,
            artwork: .poster,
            onGoToSeries: onGoToSeries
        )
    }

    private static func subtitle(for item: BaseItemDto) -> String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if item.type == .episode, let seriesName = item.seriesName {
            parts.append(seriesName)
        } else if let type = item.type {
            parts.append(type.rawValue)
        }
        return parts.joined(separator: " · ")
    }
}
