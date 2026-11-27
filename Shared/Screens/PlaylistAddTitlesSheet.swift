import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "Playlists")

// MARK: - « Ajouter des titres » — filling a playlist from the playlist
//
// A playlist used to be filled one title at a time, from each title's own
// page: open a film, « Ajouter à une playlist », pick the playlist, come back,
// start again. This is the other direction — from the playlist's page, pick
// several titles and send them in one request.
//
// The selection is ORDERED: each poster takes the number of its tap (1, 2, 3…)
// and the titles are added in that order, so the list is arranged while it is
// being chosen instead of afterwards.

/// What the picker's grid shows when nothing is typed in its search field.
enum PlaylistPickerFilter: String, CaseIterable, Identifiable, Sendable {
    case recent
    case movies
    case series
    case favorites

    var id: String { rawValue }

    var localizationKey: String { "playlist.picker.filter.\(rawValue)" }

    /// A playlist holds films and episodes; a series is offered whole (the
    /// server expands it into its episodes when it is added).
    var includeItemTypes: [BaseItemKind] {
        switch self {
        case .recent, .favorites: [.movie, .series]
        case .movies: [.movie]
        case .series: [.series]
        }
    }

    var favoritesOnly: Bool { self == .favorites }
}

@MainActor
@Observable
final class PlaylistAddTitlesModel {
    /// One page. Past it the search field is the way to a title: a picker
    /// that pages through a whole library is a second library screen.
    static let pageSize = 90
    static let searchDebounce: Duration = .milliseconds(350)

    private(set) var query = ""
    private(set) var filter: PlaylistPickerFilter = .recent
    private(set) var items: [BaseItemDto] = []
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private(set) var selection = PlaylistPickerSelection()
    /// True while the add is in flight — a double press must not add twice.
    private(set) var isCommitting = false

    /// Exposed so a test awaits the load itself instead of sleeping.
    private(set) var loadTask: Task<Void, Never>?
    /// Only the newest load may write: a slow answer to « Films » must not
    /// land over the grid of « Séries » asked after it.
    private var generation = 0

    /// Whether the grid is one full page — there may be more behind it.
    var mayHaveMore: Bool { items.count >= Self.pageSize }

    func setFilter(_ newValue: PlaylistPickerFilter, userId: String?, api: any LibraryAPI) {
        guard newValue != filter else { return }
        filter = newValue
        reload(userId: userId, api: api, debounced: false)
    }

    func setQuery(_ newValue: String, userId: String?, api: any LibraryAPI) {
        guard newValue != query else { return }
        query = newValue
        reload(userId: userId, api: api, debounced: true)
    }

    func toggle(_ id: String) {
        selection.toggle(id)
    }

    func reload(userId: String?, api: any LibraryAPI, debounced: Bool = false) {
        loadTask?.cancel()
        generation += 1
        let requested = generation
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = filter
        guard let userId else { return }
        isLoading = true
        loadTask = Task { [self] in
            if debounced {
                try? await Task.sleep(for: Self.searchDebounce)
                if Task.isCancelled { return }
            }
            do {
                let found: [BaseItemDto]
                if term.isEmpty {
                    found = try await api.getItems(
                        userId: userId,
                        includeItemTypes: filter.includeItemTypes,
                        sortBy: [.dateCreated],
                        sortOrder: [.descending],
                        isFavorite: filter.favoritesOnly ? true : nil,
                        limit: Self.pageSize,
                        enableTotalRecordCount: false,
                        fieldSet: .card
                    ).items
                } else {
                    found = try await api.searchItems(
                        userId: userId,
                        searchTerm: term,
                        includeItemTypes: filter.includeItemTypes,
                        limit: Self.pageSize,
                        enableTotalRecordCount: false
                    )
                }
                guard requested == generation else { return }
                // `searchItems` has no favourites filter of its own.
                items = filter.favoritesOnly && !term.isEmpty
                    ? found.filter { $0.userData?.isFavorite == true }
                    : found
                loadFailed = false
            } catch {
                guard requested == generation, !Task.isCancelled else { return }
                logger.error("Playlist picker load failed: \(error.localizedDescription, privacy: .public)")
                items = []
                loadFailed = true
            }
            isLoading = false
        }
    }

    /// Sends the selection, in the order it was made, in ONE request. Returns
    /// how many titles went. The selection is kept when the server refuses,
    /// so a retry does not start from nothing.
    func commit(playlistId: String, userId: String?, api: any PlaylistAPI) async throws -> Int {
        guard !isCommitting, !selection.isEmpty, let userId else { return 0 }
        isCommitting = true
        defer { isCommitting = false }
        let ids = selection.ids
        try await api.addToPlaylist(playlistId: playlistId, itemIds: ids, userId: userId)
        selection = PlaylistPickerSelection()
        return ids.count
    }
}

struct PlaylistAddTitlesSheet: View {
    let playlistId: String
    let playlistTitle: String
    /// The playlist's entries when the picker opened — what is « déjà dans la
    /// liste ».
    let existing: [BaseItemDto]
    let onAdded: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    @State private var model = PlaylistAddTitlesModel()

    private var existingIds: Set<String> { PlaylistMembership.itemIds(in: existing) }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        NavigationStack {
            iosBody
                .navigationTitle(loc.localized("playlist.addTitles.title", playlistTitle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(loc.localized("action.cancel")) { dismiss() }
                            .tint(themeManager.accent)
                    }
                }
        }
        #endif
    }

    // MARK: - iOS

    #if os(iOS)
    private var iosBody: some View {
        ScrollView {
            // A plain `VStack` around the grid, never a `LazyVStack` (the
            // nested-lazy RULE).
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                searchField
                filterChips
                results
            }
            .padding(.horizontal, gridPadding)
            .padding(.top, CinemaSpacing.spacing3)
            .padding(.bottom, CinemaSpacing.spacing6)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(CinemaColor.surface.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task { reload() }
    }

    private var gridPadding: CGFloat {
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
    }

    /// The count and the one button that sends: always in reach, whatever the
    /// scroll position.
    private var bottomBar: some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectionTitle)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(1)
                Text(loc.localized(model.selection.isEmpty ? "playlist.picker.hint" : "playlist.picker.ordered"))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CinemaButton(title: commitTitle, style: .accent, isLoading: model.isCommitting) {
                commit()
            }
            .frame(width: 168)
            .disabled(model.selection.isEmpty || model.isCommitting)
            .opacity(model.selection.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, gridPadding)
        .padding(.vertical, CinemaSpacing.spacing3)
        // An opaque ground, not glass: posters scroll under this bar, and
        // through material their colours smeared across the count.
        .background(CinemaColor.surfaceContainerHigh.ignoresSafeArea(edges: .bottom))
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                // The one chrome of every tvOS cover: title, then ONE accent
                // button. It sends the selection when there is one and closes
                // otherwise; the Menu button always backs out.
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                        Text(loc.localized("playlist.addTitles.title", playlistTitle))
                            .font(CinemaFont.headline(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                            .lineLimit(1)
                        Text(model.selection.isEmpty ? loc.localized("playlist.picker.hint") : selectionTitle)
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                    Spacer(minLength: CinemaSpacing.spacing6)
                    CinemaButton(
                        title: model.selection.isEmpty ? loc.localized("action.done") : commitTitle,
                        style: .accent,
                        isLoading: model.isCommitting
                    ) {
                        if model.selection.isEmpty { dismiss() } else { commit() }
                    }
                    .frame(width: CinemaTVLayout.ctaWidth + CinemaSpacing.spacing10)
                }
                .padding(.horizontal, CinemaTVLayout.pagePadding)
                .padding(.top, CinemaSpacing.spacing8)
                .padding(.bottom, CinemaSpacing.spacing5)
                .focusSection()

                ScrollView {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                        HStack(alignment: .center, spacing: CinemaSpacing.spacing4) {
                            searchField
                                .frame(width: 520)
                            filterChips
                            Spacer(minLength: 0)
                        }
                        .focusSection()
                        results
                    }
                    .padding(.horizontal, CinemaTVLayout.pagePadding)
                    .padding(.top, CinemaSpacing.spacing3)
                    .padding(.bottom, CinemaSpacing.spacing8)
                }
            }
        }
        .onExitCommand { dismiss() }
        .task { reload() }
    }
    #endif

    // MARK: - Shared pieces

    private var searchField: some View {
        // No label above the field: the placeholder says the same words.
        GlassTextField(
            label: "",
            text: Binding(
                get: { model.query },
                set: { model.setQuery($0, userId: appState.currentUserId, api: appState.apiClient) }
            ),
            placeholder: loc.localized("playlist.picker.search"),
            icon: "magnifyingglass"
        )
        .accessibilityLabel(loc.localized("playlist.picker.search"))
    }

    private var filterChips: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            ForEach(PlaylistPickerFilter.allCases) { filter in
                filterChip(filter)
            }
        }
    }

    private func filterChip(_ filter: PlaylistPickerFilter) -> some View {
        let isSelected = model.filter == filter
        return Button {
            model.setFilter(filter, userId: appState.currentUserId, api: appState.apiClient)
        } label: {
            Text(loc.localized(filter.localizationKey))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(isSelected ? themeManager.onAccentContainer : CinemaColor.onSurfaceVariant)
                .lineLimit(1)
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
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var results: some View {
        if model.isLoading && model.items.isEmpty {
            LoadingStateView()
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if model.loadFailed {
            ErrorStateView(message: loc.localized("error.generic"), retryTitle: loc.localized("action.retry")) {
                reload()
            }
        } else if model.items.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: loc.localized("playlist.picker.empty"),
                subtitle: nil
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(model.items, id: \.id) { item in
                    cell(item)
                }
            }
            if model.mayHaveMore {
                Text(loc.localized("playlist.picker.more"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, CinemaSpacing.spacing3)
            }
        }
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        CinemaTVLayout.posterGridColumns
        #else
        AdaptiveLayout.posterGridColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.gridGutter
        #else
        CinemaSpacing.spacing3
        #endif
    }

    /// One title: its poster, its number once chosen, and — for what the
    /// playlist already holds — a mark instead of a number.
    @ViewBuilder
    private func cell(_ item: BaseItemDto) -> some View {
        if let id = item.id {
            let isSeries = item.type == .series
            let alreadyIn = !isSeries && existingIds.contains(id)
            let number = model.selection.number(of: id)
            let subtitle = cellSubtitle(item, seriesId: isSeries ? id : nil)
            Button {
                model.toggle(id)
            } label: {
                PosterCard(
                    title: item.name ?? "",
                    imageURL: appState.imageBuilder.imageURL(
                        itemId: id, imageType: .primary, maxWidth: 300, tag: item.primaryImageTagValue
                    ),
                    subtitle: subtitle
                )
                .overlay(alignment: .topTrailing) {
                    if !alreadyIn {
                        PlaylistPickerBadge(number: number)
                            .padding(CinemaSpacing.spacing2)
                    }
                }
                .overlay(alignment: .top) {
                    if alreadyIn {
                        Text(loc.localized("playlist.picker.already"))
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurface)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, CinemaSpacing.spacing2)
                            .padding(.vertical, CinemaSpacing.spacing1)
                            .background(CinemaColor.surfaceContainerHighest, in: Capsule())
                            .padding(CinemaSpacing.spacing2)
                    }
                }
                .opacity(alreadyIn ? 0.45 : 1)
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .disabled(alreadyIn)
            .accessibilityLabel([item.name ?? "", subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityValue(cellAccessibilityValue(alreadyIn: alreadyIn, number: number))
            .accessibilityAddTraits(number != nil ? [.isButton, .isSelected] : .isButton)
        }
    }

    private func cellSubtitle(_ item: BaseItemDto, seriesId: String?) -> String {
        if let seriesId {
            let held = PlaylistMembership.episodeCount(ofSeries: seriesId, in: existing)
            return held > 0
                ? loc.counted("playlist.picker.seriesPartial", held)
                : loc.localized("playlist.picker.seriesAdds")
        }
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if let minutes = item.runTimeTicks?.jellyfinMinutes, minutes > 0 {
            parts.append(loc.runtime(minutes: minutes))
        }
        return parts.joined(separator: " · ")
    }

    private func cellAccessibilityValue(alreadyIn: Bool, number: Int?) -> String {
        if alreadyIn { return loc.localized("playlist.picker.already") }
        if let number { return loc.localized("playlist.picker.a11y.number", number) }
        return ""
    }

    private var selectionTitle: String {
        model.selection.isEmpty
            ? loc.localized("playlist.picker.selected.none")
            : loc.counted("playlist.picker.selected", model.selection.count)
    }

    private var commitTitle: String {
        model.selection.isEmpty
            ? loc.localized("playlist.picker.add.none")
            : loc.counted("playlist.picker.add", model.selection.count)
    }

    // MARK: - Actions

    private func reload() {
        model.reload(userId: appState.currentUserId, api: appState.apiClient)
    }

    private func commit() {
        Task {
            do {
                let count = try await model.commit(
                    playlistId: playlistId, userId: appState.currentUserId, api: appState.apiClient
                )
                guard count > 0 else { return }
                onAdded(count)
                dismiss()
            } catch {
                // The picker stays open with its selection: a retry is one press.
                logger.error("Add titles to playlist failed: \(error.localizedDescription, privacy: .public)")
                toast.error(loc.userFacingMessage(for: error))
            }
        }
    }
}

/// The mark in a poster's corner: an empty ring until the title is chosen,
/// then its place in the order it will be added in.
private struct PlaylistPickerBadge: View {
    let number: Int?

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        ZStack {
            Circle()
                .fill(number == nil ? Color.black.opacity(0.45) : themeManager.accentContainer)
            Circle()
                .strokeBorder(number == nil ? Color.white : themeManager.accentContainer, lineWidth: 2)
            if let number {
                Text(String(number))
                    .font(.system(size: CinemaScale.pt(14), weight: .heavy).monospacedDigit())
                    .foregroundStyle(themeManager.onAccentContainer)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
    }

    private static var side: CGFloat { CinemaScale.pt(28) }
}

// MARK: - Presentation

extension View {
    /// Presents « Ajouter des titres » for one playlist — a sheet on iOS, a
    /// full-screen cover on tvOS (`.sheet` renders as a broken narrow modal on
    /// tvOS 26). Apply it to the playlist page's body, outside every lazy
    /// container. `onAdded` receives how many titles were sent.
    func playlistAddTitles(
        isPresented: Binding<Bool>,
        playlistId: String,
        playlistTitle: String,
        existing: [BaseItemDto],
        onAdded: @escaping (Int) -> Void
    ) -> some View {
        modifier(PlaylistAddTitlesPresentation(
            isPresented: isPresented, playlistId: playlistId, playlistTitle: playlistTitle,
            existing: existing, onAdded: onAdded
        ))
    }
}

/// Re-injects the environment by hand, like `AddToPlaylistPresentation`: a
/// modal is its own presentation context, and a missing `@Observable` there
/// traps at runtime.
private struct PlaylistAddTitlesPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let playlistId: String
    let playlistTitle: String
    let existing: [BaseItemDto]
    let onAdded: (Int) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.fullScreenCover(isPresented: $isPresented) { sheet }
        #else
        // `.page`: on an iPad the default form sheet is a phone-wide column,
        // three posters across in the middle of the screen.
        content.sheet(isPresented: $isPresented) { sheet.presentationSizing(.page) }
        #endif
    }

    private var sheet: some View {
        PlaylistAddTitlesSheet(
            playlistId: playlistId, playlistTitle: playlistTitle, existing: existing, onAdded: onAdded
        )
        .environment(appState)
        .environment(themeManager)
        .environment(loc)
        .environment(toast)
    }
}
