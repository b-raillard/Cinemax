import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "PlaylistDetail")

/// Where a `.onMove` lands, in Jellyfin's terms.
///
/// SwiftUI hands `to` as an insertion point in the list **as it stands before**
/// the row is lifted out; Jellyfin's `movePlaylistItem` wants the entry's final
/// 0-based index **after** the move. The two agree when dragging upward and
/// differ by one when dragging downward — the off-by-one that silently drops a
/// row one slot short of where the finger left it.
enum PlaylistReorder {
    static func destinationIndex(from source: Int, to destination: Int) -> Int {
        destination > source ? destination - 1 : destination
    }
}

/// One playlist, in playlist order: what is in it, what has been watched, and
/// everything that can be done to it from where it is read — add titles, sort,
/// remove, rename, delete.
///
/// A dedicated screen rather than the scoped `MediaLibraryScreen` the folder
/// browser used to push, for two reasons that are really one: a playlist is an
/// **ordered** collection, and only `getPlaylistItems` returns it in that order
/// — and only it populates `playlistItemID`, the ENTRY id every mutation is
/// addressed by (the same film can sit in a playlist twice, and each occurrence
/// moves independently). A `parentId` query returns neither.
///
/// Layout: one column on a phone; two panes at regular width (the playlist on
/// the left, its contents on the right); on tvOS the header carries the
/// actions, since there is no navigation bar to hold them.
struct PlaylistDetailScreen: View {
    let playlistId: String
    /// Whether the page offers rename / delete — the server's `canDelete`,
    /// carried by the card that opened it. Defaults to `false`, so a call site
    /// that does not know shows no management rather than a refused one.
    let canManage: Bool

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    /// The playlist's OWN name (possibly blank), as the server has it —
    /// what « Renommer » pre-fills. State, not a `let`: a rename made on this
    /// page retitles it. Shown through `displayTitle`.
    @State private var title: String
    @State private var viewModel = PlaylistDetailViewModel()
    @State private var playlistManagement: PlaylistManagementRequest?
    /// Folded series runs the user opened, by `PlaylistSeriesRun.id`.
    @State private var expandedRuns: Set<String> = []
    @State private var isAddingTitles = false
    /// A removal that takes more than one entry asks first — it has no undo.
    @State private var pendingRemoval: PendingRemoval?
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @State private var isSorting = false
    @State private var showsOptions = false
    /// The sort-mode button holding the focus, as « entry id|control ». A
    /// moved row takes its buttons with it, and the focus is written back so
    /// the next press moves the SAME row again.
    @FocusState private var focusedSortControl: String?
    #endif

    /// Several entries removed at once.
    private struct PendingRemoval: Identifiable {
        let id = UUID()
        let entryIds: [String]
        let message: String
    }

    /// `title` is the playlist's raw name (`BaseItemDto.name`), NOT a display
    /// fallback: a blank one reads « Playlist sans nom » on screen, but the
    /// rename field must not pre-fill that placeholder as if it were a name.
    init(playlistId: String, title: String, canManage: Bool = false) {
        self.playlistId = playlistId
        self.canManage = canManage
        _title = State(initialValue: title)
    }

    var body: some View {
        content
            #if os(iOS)
            // iOS only: on tvOS a navigation title is drawn as a large faint
            // word floating over the page (it sat across the entries once the
            // list scrolled) — the header carries the name there.
            .navigationTitle(displayTitle)
            // Inline: the header below carries the name in large type, under
            // the cover — a large title above it would say it twice.
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar { toolbarContent }
            #endif
            .task(id: playlistId) {
                await viewModel.load(playlistId: playlistId, using: appState)
            }
            .playlistManagement(
                $playlistManagement,
                // Gone from the server: nothing left to show here.
                onDeleted: { _ in dismiss() },
                onRenamed: { _, newName in title = newName }
            )
            .playlistAddTitles(
                isPresented: $isAddingTitles,
                playlistId: playlistId,
                playlistTitle: displayTitle,
                existing: viewModel.items
            ) { count in
                Task {
                    await viewModel.load(playlistId: playlistId, using: appState)
                    NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
                    toast.success(loc.counted("playlist.picker.added", count))
                }
            }
            .confirmationDialog(
                loc.localized("playlist.removeItem"),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { removal in
                Button(loc.localized("playlist.removeItem"), role: .destructive) {
                    Task { await removeEntries(removal.entryIds) }
                }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: { removal in
                Text(removal.message)
            }
            #if os(tvOS)
            .confirmationDialog(
                loc.localized("playlist.manage"),
                isPresented: $showsOptions,
                titleVisibility: .visible
            ) {
                if watchedCount > 0 {
                    Button(loc.localized("playlist.removeWatched")) { askRemoveWatched() }
                }
                if canManage {
                    Button(loc.localized("playlist.rename")) {
                        playlistManagement = .rename(id: playlistId, name: title)
                    }
                    Button(loc.localized("playlist.delete"), role: .destructive) {
                        playlistManagement = .delete(id: playlistId, name: displayTitle)
                    }
                }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            }
            #endif
            // Only ever pushed (Home's playlists rail, or the Playlists tab's
            // folder browser) — see `tvPushedScreen`.
            .tvPushedScreen()
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView()
        case .failed:
            ErrorStateView(
                message: loc.localized("error.generic"),
                retryTitle: loc.localized("action.retry")
            ) {
                Task { await viewModel.load(playlistId: playlistId, using: appState) }
            }
        case .empty:
            // The header alone — its cover says « vide », its line says
            // « Cette playlist est vide » and its button is the way out: an
            // empty playlist used to be a dead end, filled only from each
            // title's own page.
            #if os(tvOS)
            // The SAME view as a filled playlist (it draws no row): going
            // from empty to filled must not swap the header for another one,
            // or « Ajouter des titres » loses the focus to the tab bar the
            // moment its cover closes (seen on the simulator).
            loaded
            #else
            ScrollView {
                header
            }
            .refreshable {
                await viewModel.load(playlistId: playlistId, using: appState)
            }
            #endif
        case .loaded:
            loaded
        }
    }

    // MARK: - iOS

    #if os(iOS)
    private var isRegular: Bool {
        AdaptiveLayout.form(horizontalSizeClass: sizeClass) == .regular
    }

    /// Two panes at regular width: the page of a phone, centred on an iPad,
    /// left most of the screen empty and pushed the entries below the fold.
    @ViewBuilder
    private var loaded: some View {
        if isRegular {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    header
                        .padding(.top, CinemaSpacing.spacing5)
                }
                .frame(width: Self.sidePaneWidth)
                list(includesHeader: false)
            }
            .background(SeasonalBackdrop().ignoresSafeArea())
        } else {
            list(includesHeader: true)
                .background(SeasonalBackdrop().ignoresSafeArea())
        }
    }

    private static let sidePaneWidth: CGFloat = 360

    /// The navigation bar carries « Trier » and « … » on a PHONE only. At
    /// regular width the floating tab bar takes the middle of that bar and the
    /// system folds both items into one overflow « … » — « Trier » was two
    /// taps away on an iPad (seen on the simulator, 2026-11-27). There the
    /// side pane holds them, under « Ajouter des titres ».
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isRegular {
            if !viewModel.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { sortButton }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    optionsMenuItems
                } label: {
                    Label(loc.localized("playlist.manage"), systemImage: "ellipsis")
                }
            }
        }
    }

    /// NOT the system `EditButton`: it takes its title from the DEVICE
    /// language, so it read "Edit" over a French app on an English phone — and
    /// the app's language is a setting of its own here.
    private var sortButton: some View {
        Button {
            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
        } label: {
            Text(loc.localized(editMode.isEditing ? "action.done" : "playlist.reorder"))
        }
    }

    @ViewBuilder
    private var optionsMenuItems: some View {
        Button {
            isAddingTitles = true
        } label: {
            Label(loc.localized("playlist.addTitles"), systemImage: "plus")
        }
        if watchedCount > 0 {
            Button {
                askRemoveWatched()
            } label: {
                Label(loc.localized("playlist.removeWatched"), systemImage: "checkmark.circle")
            }
        }
        if canManage {
            Divider()
            Button {
                playlistManagement = .rename(id: playlistId, name: title)
            } label: {
                Label(loc.localized("playlist.rename"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                playlistManagement = .delete(id: playlistId, name: displayTitle)
            } label: {
                Label(loc.localized("playlist.delete"), systemImage: "trash")
            }
        }
    }

    /// The side pane's second row of actions (regular width): « Trier » and
    /// the options, drawn as the ghost pair under the accent button.
    private var sidePaneActions: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            if !viewModel.items.isEmpty {
                CinemaButton(
                    title: loc.localized(editMode.isEditing ? "action.done" : "playlist.reorder"),
                    style: .ghost
                ) {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
            if canManage || watchedCount > 0 {
                Menu {
                    optionsMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                        .foregroundStyle(CinemaColor.onSurface)
                        .frame(width: 52, height: 52)
                        .glassPanel(cornerRadius: CinemaRadius.large)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(loc.localized("playlist.manage"))
            }
        }
        .frame(maxWidth: 300)
    }

    /// A native `List` — the same deliberate exception `MenuSettingsScreen+iOS`
    /// makes, and for the same reason: `.onMove` with the system's own ≡ handle
    /// exists nowhere else.
    ///
    /// Unlike that screen this one does NOT force edit mode on permanently.
    /// There, every row is a toggle; here every row opens an item, and an
    /// always-editing `List` swallows the taps that would open it. « Trier »
    /// is what keeps both gestures available — the same split Music.app makes.
    private func list(includesHeader: Bool) -> some View {
        List {
            if includesHeader {
                // OUTSIDE the `ForEach` that carries `.onMove` and the swipe
                // actions: the header is neither movable nor removable.
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .deleteDisabled(true)
                    .moveDisabled(true)
            }

            if editMode.isEditing {
                // Flat while sorting: every episode of a folded series is an
                // entry of its own, and it is entries that move.
                ForEach(viewModel.items, id: \.playlistItemID) { item in
                    HStack(spacing: CinemaSpacing.spacing2) {
                        Button {
                            Task { await remove(item) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: CinemaScale.pt(22)))
                                .foregroundStyle(CinemaColor.error)
                        }
                        // `.borderless` keeps the button reachable inside the
                        // List row (see `MenuSettingsScreen+iOS`).
                        .buttonStyle(.borderless)
                        .accessibilityLabel(loc.localized("playlist.removeItem"))
                        PlaylistRow(item: item, imageBuilder: appState.imageBuilder, showsStatus: false)
                    }
                    .listRowBackground(CinemaColor.surfaceContainerLow)
                }
                .onMove { offsets, destination in
                    guard let source = offsets.first else { return }
                    Task { await move(from: source, to: destination) }
                }
            } else {
                ForEach(displayRows) { row in
                    switch row {
                    case .entry(let item):
                        entryLink(item, indented: false)
                    case .run(let run):
                        runButton(run)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    askRemove(run)
                                } label: {
                                    Label(loc.localized("playlist.removeItem"), systemImage: "minus.circle")
                                }
                            }
                        if expandedRuns.contains(run.id) {
                            ForEach(run.entries, id: \.playlistItemID) { item in
                                entryLink(item, indented: true)
                            }
                        }
                    }
                }
                .listRowBackground(CinemaColor.surfaceContainerLow)

                addTitlesRow
                    .listRowBackground(CinemaColor.surfaceContainerLow)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await viewModel.load(playlistId: playlistId, using: appState)
        }
    }

    private func entryLink(_ item: BaseItemDto, indented: Bool) -> some View {
        NavigationLink {
            DeferredView {
                if let id = item.id {
                    MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                }
            }
        } label: {
            PlaylistRow(item: item, imageBuilder: appState.imageBuilder)
                .padding(.leading, indented ? CinemaSpacing.spacing4 : 0)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await remove(item) }
            } label: {
                Label(loc.localized("playlist.removeItem"), systemImage: "minus.circle")
            }
        }
    }

    private var addTitlesRow: some View {
        Button {
            isAddingTitles = true
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                RoundedRectangle(cornerRadius: CinemaRadius.medium)
                    .fill(themeManager.accent.opacity(0.12))
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(width: PlaylistRow.posterWidth)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                            .foregroundStyle(themeManager.accent)
                    }
                Text(loc.localized("playlist.addTitles"))
                    .font(CinemaFont.body.weight(.semibold))
                    .foregroundStyle(themeManager.accent)
                Spacer(minLength: 0)
            }
            .padding(.vertical, CinemaSpacing.spacing1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #else

    // MARK: - tvOS

    /// tvOS has no drag-and-drop. In « Trier », each row shows its own
    /// « Monter » / « Descendre » / « Retirer » buttons; outside it, the same
    /// three sit in the row's long-press menu.
    private var loaded: some View {
        ScrollView {
            header
                .padding(.horizontal, CinemaTVLayout.pagePadding)
                .padding(.top, CinemaSpacing.spacing5)

            if isSorting {
                Text(loc.localized("playlist.sort.hint"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CinemaTVLayout.pagePadding)
                    .padding(.top, CinemaSpacing.spacing3)
            }

            LazyVStack(spacing: CinemaSpacing.spacing3) {
                if isSorting {
                    ForEach(Array(viewModel.items.enumerated()), id: \.element.playlistItemID) { index, item in
                        sortingRow(item, index: index)
                    }
                } else {
                    ForEach(displayRows) { row in
                        switch row {
                        case .entry(let item):
                            tvEntryLink(item)
                        case .run(let run):
                            runButton(run)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        askRemove(run)
                                    } label: {
                                        Label(loc.localized("playlist.removeItem"), systemImage: "minus.circle")
                                    }
                                }
                            if expandedRuns.contains(run.id) {
                                ForEach(run.entries, id: \.playlistItemID) { item in
                                    tvEntryLink(item)
                                        .padding(.leading, CinemaSpacing.spacing8)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, CinemaTVLayout.pagePadding)
            .padding(.top, CinemaSpacing.spacing3)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
        .scrollClipDisabled()
    }

    private func tvRowLabel(_ item: BaseItemDto) -> some View {
        PlaylistRow(item: item, imageBuilder: appState.imageBuilder)
            .padding(CinemaSpacing.spacing3)
            .background(CinemaColor.surfaceContainerLow, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
    }

    private func tvEntryLink(_ item: BaseItemDto) -> some View {
        // A `NavigationLink` rather than the hoisted
        // `navigationDestination(item:)` the folder browser uses: the
        // destination closure is honored inside a lazy container, only the
        // `item:` modifier is not.
        NavigationLink {
            DeferredView {
                if let id = item.id {
                    MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
                }
            }
        } label: {
            tvRowLabel(item)
        }
        // A full-width row, so the accent stroke rather than the card style —
        // scaling a row this wide visibly shifts its own content sideways.
        .buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .contextMenu {
            let index = viewModel.items.firstIndex { $0.playlistItemID == item.playlistItemID }
            if let index, index > 0 {
                Button {
                    Task { await move(from: index, to: index - 1) }
                } label: {
                    Label(loc.localized("playlist.moveUp"), systemImage: "arrow.up")
                }
            }
            Button(role: .destructive) {
                Task { await remove(item) }
            } label: {
                Label(loc.localized("playlist.removeItem"), systemImage: "minus.circle")
            }
            if let index, index < viewModel.items.count - 1 {
                Button {
                    // `+2` because SwiftUI's move destination is an insertion
                    // point in the pre-move list — the same convention
                    // `PlaylistReorder` normalises.
                    Task { await move(from: index, to: index + 2) }
                } label: {
                    Label(loc.localized("playlist.moveDown"), systemImage: "arrow.down")
                }
            }
        }
    }

    /// A row of the sort mode: the entry, not focusable, and its three buttons.
    ///
    /// Buttons rather than « pick the row up and carry it with up / down »:
    /// that was built first and measured on the simulator (2026-11-27) — after
    /// one carry the focus engine stopped handing the row its move commands,
    /// one press in three moved it. A button press is a plain action, whatever
    /// the list did under the focus.
    private func sortingRow(_ item: BaseItemDto, index: Int) -> some View {
        let entryId = item.playlistItemID ?? ""
        let isLast = index >= viewModel.items.count - 1
        return HStack(spacing: CinemaSpacing.spacing3) {
            PlaylistRow(item: item, imageBuilder: appState.imageBuilder, showsStatus: false)
            sortControl("arrow.up", label: "playlist.moveUp", id: entryId + "|up", disabled: index == 0) {
                step(entryId, from: index, to: index - 1, control: index - 1 == 0 ? "down" : "up")
            }
            sortControl("arrow.down", label: "playlist.moveDown", id: entryId + "|down", disabled: isLast) {
                // `+2`: SwiftUI's move destination is an insertion point in
                // the pre-move list — what `PlaylistReorder` normalises.
                step(entryId, from: index, to: index + 2, control: index + 1 >= viewModel.items.count - 1 ? "up" : "down")
            }
            sortControl("minus.circle", label: "playlist.removeItem", id: entryId + "|remove", disabled: false) {
                Task { await remove(item) }
            }
        }
        .padding(CinemaSpacing.spacing3)
        .background(CinemaColor.surfaceContainerLow, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
        // The buttons sit at the trailing edge, out of the beam of the
        // header's buttons above: the full-width row is the focus section
        // a Down press lands in.
        .focusSection()
    }

    private func sortControl(
        _ systemImage: String, label: String, id: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: CinemaScale.pt(18), weight: .semibold))
                .foregroundStyle(CinemaColor.onSurface)
                .frame(width: Self.sortControlSide, height: Self.sortControlSide)
                .background(CinemaColor.surfaceContainerHigh, in: Capsule())
        }
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedSortControl, equals: id)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(loc.localized(label))
    }

    private static let sortControlSide: CGFloat = 72

    /// Moves a row one slot and keeps the focus on ITS button, so pressing
    /// again moves it again. At either end the focus goes to the button that
    /// still does something.
    private func step(_ entryId: String, from source: Int, to destination: Int, control: String) {
        Task {
            await move(from: source, to: destination)
            focusedSortControl = entryId + "|" + control
        }
    }
    #endif

    // MARK: - Shared rows    #endif

    // MARK: - Shared rows

    private var displayRows: [PlaylistDisplayRow] {
        PlaylistGrouping.rows(from: viewModel.items)
    }

    private var watchedCount: Int {
        PlaylistMembership.watchedEntryIds(in: viewModel.items).count
    }

    /// A folded series: one line for a run of its episodes, opened in place.
    private func runButton(_ run: PlaylistSeriesRun) -> some View {
        let expanded = expandedRuns.contains(run.id)
        let label = PlaylistRunRow(
            run: run,
            isExpanded: expanded,
            subtitle: loc.counted("playlist.run.subtitle", run.entries.count),
            imageBuilder: appState.imageBuilder
        )
        return Button {
            if expanded { expandedRuns.remove(run.id) } else { expandedRuns.insert(run.id) }
        } label: {
            #if os(tvOS)
            label
                .padding(CinemaSpacing.spacing3)
                .background(CinemaColor.surfaceContainerLow, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
            #else
            label.contentShape(Rectangle())
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityValue(loc.localized(expanded ? "playlist.run.expanded" : "playlist.run.collapsed"))
    }

    // MARK: - Header

    /// The cover, the name, « N éléments · durée · N vus » and the actions.
    /// Built from the loaded entries: the cover takes their posters (series
    /// poster for an episode, never a repeat), at the very URLs the cards ask
    /// for.
    private var header: some View {
        let cover = PlaylistCoverStack.content(
            preview: PlaylistPreview(
                posters: PlaylistCoverStack.posters(from: viewModel.items),
                totalCount: viewModel.items.count
            ),
            fallbackCount: nil
        )
        #if os(tvOS)
        return HStack(alignment: .center, spacing: CinemaSpacing.spacing8) {
            PlaylistCover(content: cover, imageBuilder: appState.imageBuilder)
                .frame(width: CinemaTVLayout.playlistCoverSide)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                headerText(alignment: .leading)
                // The page's top row of focus stops: an Up press from the
                // entries lands here instead of escaping into the tab bar —
                // what the cover used to be focusable for — and an empty
                // playlist opens on them. A filled one opens on its first
                // entry, the full-width row being nearest the leading edge.
                HStack(spacing: CinemaSpacing.spacing3) {
                    CinemaButton(title: loc.localized("playlist.addTitles"), style: .accent, icon: "plus") {
                        isAddingTitles = true
                    }
                    .frame(width: CinemaTVLayout.ctaWidth + CinemaSpacing.spacing10)
                    if !viewModel.items.isEmpty {
                        CinemaButton(
                            title: loc.localized(isSorting ? "action.done" : "playlist.reorder"),
                            style: .ghost
                        ) {
                            isSorting.toggle()
                        }
                        .frame(width: CinemaTVLayout.ctaWidth)
                    }
                    if canManage || watchedCount > 0 {
                        CinemaButton(title: loc.localized("playlist.options"), style: .ghost) {
                            showsOptions = true
                        }
                        .frame(width: CinemaTVLayout.ctaWidth)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .focusSection()
        #else
        return VStack(spacing: CinemaSpacing.spacing3) {
            PlaylistCover(content: cover, imageBuilder: appState.imageBuilder)
                .frame(width: isRegular ? 260 : 216)
                .accessibilityHidden(true)
            headerText(alignment: .center)
            if !editMode.isEditing {
                CinemaButton(title: loc.localized("playlist.addTitles"), style: .accent, icon: "plus") {
                    isAddingTitles = true
                }
                .frame(maxWidth: 300)
                .padding(.top, CinemaSpacing.spacing1)
            }
            if isRegular { sidePaneActions }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CinemaSpacing.spacing4)
        .padding(.vertical, CinemaSpacing.spacing3)
        #endif
    }

    private var displayTitle: String {
        PlaylistCardButton.displayName(title, untitled: loc.localized("playlist.untitled"))
    }

    private func headerText(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: CinemaSpacing.spacing1) {
            Text(displayTitle)
                .font(CinemaFont.headline(.medium))
                .foregroundStyle(CinemaColor.onSurface)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text(headerMeta)
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceMuted)
                .lineLimit(1)
        }
    }

    /// « 4 éléments · 6 h 12 min · 2 vus ». A SERIES entry adds nothing to the
    /// duration: its runtime is one episode's, not the show's total (a season
    /// likewise carries no total of its own). An empty playlist says so.
    private var headerMeta: String {
        let items = viewModel.items
        if items.isEmpty { return loc.localized("playlist.contents.empty") }
        var parts = [loc.itemCount(items.count)]
        let ticks = items
            .filter { $0.type != .series && $0.type != .season }
            .compactMap(\.runTimeTicks)
            .reduce(0, +)
        if ticks.jellyfinMinutes > 0 { parts.append(loc.runtime(minutes: ticks.jellyfinMinutes)) }
        if watchedCount > 0 { parts.append(loc.counted("playlist.meta.watched", watchedCount)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    /// Removes one entry. On iOS the confirmation message carries « Annuler »,
    /// which puts the title back where it was; tvOS toasts have no button.
    private func remove(_ item: BaseItemDto) async {
        guard let entryId = item.playlistItemID else { return }
        let index = viewModel.items.firstIndex { $0.playlistItemID == entryId }
        switch await viewModel.remove(entryId: entryId, playlistId: playlistId, using: appState) {
        case .removed:
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
            #if os(iOS)
            if let index {
                toast.info(
                    loc.localized("playlist.removeItem.done"),
                    action: ToastAction(title: loc.localized("action.undo")) {
                        Task { await restore(item, at: index) }
                    }
                )
            } else {
                toast.success(loc.localized("playlist.removeItem.done"))
            }
            #else
            toast.success(loc.localized("playlist.removeItem.done"))
            #endif
        case .notFound:
            // The list moved under an open menu. Nothing was sent, so nothing
            // is announced — a toast here would report a removal that never
            // happened.
            break
        case .failed(let error):
            toast.error(loc.userFacingMessage(for: error))
        }
    }

    private func restore(_ item: BaseItemDto, at index: Int) async {
        if let failure = await viewModel.restore(item, at: index, playlistId: playlistId, using: appState) {
            toast.error(loc.userFacingMessage(for: failure))
        } else {
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
        }
    }

    private func askRemove(_ run: PlaylistSeriesRun) {
        pendingRemoval = PendingRemoval(
            entryIds: run.entryIds,
            message: loc.localized(
                loc.pluralKey("playlist.run.remove.message", run.entries.count),
                run.entries.count, run.seriesName
            )
        )
    }

    private func askRemoveWatched() {
        let entryIds = PlaylistMembership.watchedEntryIds(in: viewModel.items)
        guard !entryIds.isEmpty else { return }
        pendingRemoval = PendingRemoval(
            entryIds: entryIds,
            message: loc.counted("playlist.removeWatched.message", entryIds.count)
        )
    }

    private func removeEntries(_ entryIds: [String]) async {
        if let failure = await viewModel.remove(entryIds: entryIds, playlistId: playlistId, using: appState) {
            toast.error(loc.userFacingMessage(for: failure))
        } else {
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
            toast.success(loc.counted("playlist.removed.count", entryIds.count))
        }
    }

    private func move(from source: Int, to destination: Int) async {
        let target = PlaylistReorder.destinationIndex(from: source, to: destination)
        guard let failure = await viewModel.move(from: source, to: target, playlistId: playlistId, using: appState) else {
            NotificationCenter.default.post(name: .cinemaxPlaylistsChanged, object: nil)
            return
        }
        toast.error(loc.userFacingMessage(for: failure))
    }
}

// MARK: - Rows

/// One entry: its poster, its title, what it is and where the user stands with
/// it — watched, or how much is left.
///
/// The watched state and the position were always loaded (`getPlaylistItems`
/// asks for user data); the row used to print the title and the year alone.
private struct PlaylistRow: View {
    let item: BaseItemDto
    let imageBuilder: ImageURLBuilder
    /// Off while sorting: the trailing edge belongs to the ≡ handle (iOS) or
    /// to the row's buttons (tvOS).
    var showsStatus: Bool = true

    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            PlaylistRowPoster(poster: PlaylistCoverStack.poster(for: item), imageBuilder: imageBuilder)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "")
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(2)
                Text(subtitle)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
                if showsStatus, case .inProgress(let fraction) = status {
                    ProgressBarView(progress: fraction, height: 3)
                        .frame(maxWidth: Self.progressWidth)
                        .frame(height: 3)
                        .padding(.top, 3)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: CinemaSpacing.spacing2)
            if showsStatus {
                trailingStatus
            }
        }
        .padding(.vertical, CinemaSpacing.spacing1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.accessibilityValue(localize: { loc.localized($0) }) ?? "")
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch status {
        case .watched:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: CinemaScale.pt(18)))
                .foregroundStyle(themeManager.accent)
                .accessibilityHidden(true)
        case .inProgress(let fraction):
            if let minutes = remainingMinutes(fraction) {
                Text(loc.remainingTime(minutes: minutes))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        case .none:
            EmptyView()
        }
    }

    /// The same derivation as every poster card's badge, so a row cannot say
    /// « vu » where the card of the same title shows a progress bar.
    private var status: MediaCardStatus {
        MediaCardStatus.make(
            positionTicks: item.userData?.playbackPositionTicks,
            runtimeTicks: item.runTimeTicks,
            isPlayed: item.userData?.isPlayed
        )
    }

    private func remainingMinutes(_ fraction: Double) -> Int? {
        guard let ticks = item.runTimeTicks else { return nil }
        let minutes = Int((Double(ticks.jellyfinMinutes) * (1 - fraction)).rounded())
        return minutes > 0 ? minutes : nil
    }

    /// « S01:E02 · Quai 9 · 45 min » for an episode, « 2023 · 1 h 52 min » for
    /// a film. The episode's code leads: on a phone the line is cut at the
    /// end, and a long series name used to push « S01:E02 » out of it (seen
    /// on the simulator: « Chrono Serie (2026) · S01:… »). A series or a
    /// season carries no duration of its own.
    private var subtitle: String {
        var parts: [String] = []
        if item.type == .episode {
            if let code = item.playlistEpisodeCode { parts.append(code) }
            if let series = item.seriesName { parts.append(series) }
        } else if let year = item.productionYear {
            parts.append(String(year))
        }
        if item.type != .series, item.type != .season,
           let minutes = item.runTimeTicks?.jellyfinMinutes, minutes > 0 {
            parts.append(loc.runtime(minutes: minutes))
        }
        return parts.joined(separator: " · ")
    }

    static var posterWidth: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(76)
        #else
        CinemaScale.pt(46)
        #endif
    }

    private static var progressWidth: CGFloat {
        #if os(tvOS)
        320
        #else
        160
        #endif
    }
}

/// A folded run of one series' episodes: the series' poster, its name, how
/// many episodes, and a chevron that says the line opens.
private struct PlaylistRunRow: View {
    let run: PlaylistSeriesRun
    let isExpanded: Bool
    let subtitle: String
    let imageBuilder: ImageURLBuilder

    var body: some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            PlaylistRowPoster(
                poster: PlaylistCoverPoster(itemId: run.seriesId, tag: run.posterTag),
                imageBuilder: imageBuilder
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(run.seriesName)
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(2)
                Text(subtitle)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: CinemaSpacing.spacing2)
            Image(systemName: "chevron.down")
                .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                .foregroundStyle(CinemaColor.onSurfaceMuted)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .padding(.vertical, CinemaSpacing.spacing1)
        .accessibilityElement(children: .combine)
    }
}

/// A row's 2:3 poster. An episode shows its SERIES' poster: its own primary is
/// a 16:9 still, cropped to a sliver in a 2:3 slot.
private struct PlaylistRowPoster: View {
    let poster: PlaylistCoverPoster?
    let imageBuilder: ImageURLBuilder

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(width: PlaylistRow.posterWidth)
            .overlay {
                CinemaLazyImage(
                    url: poster.map {
                        imageBuilder.imageURL(
                            itemId: $0.itemId, imageType: .primary,
                            maxWidth: 200, tag: $0.tag
                        )
                    },
                    fallbackIcon: "film"
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
            // Scaled to FILL, so an image that overflows its slot stays
            // hit-testable past the clip without this.
            .contentShape(Rectangle())
    }
}

@MainActor
@Observable
final class PlaylistDetailViewModel {
    enum State {
        case loading
        case loaded
        case empty
        case failed
    }

    private(set) var state: State = .loading
    private(set) var items: [BaseItemDto] = []

    func load(playlistId: String, using appState: AppState) async {
        guard let userId = appState.currentUserId else {
            state = .failed
            return
        }
        // A reload keeps what is on screen (the page reloads after an add);
        // only a first load, or a retry after a failure, shows the spinner.
        switch state {
        case .loaded, .empty: break
        case .loading, .failed: state = .loading
        }
        do {
            items = try await appState.apiClient.getPlaylistItems(playlistId: playlistId, userId: userId)
            state = items.isEmpty ? .empty : .loaded
        } catch {
            logger.error("Playlist load failed: \(error.localizedDescription, privacy: .public)")
            state = .failed
        }
    }

    /// What a removal actually did. `nil` used to mean both "removed" and
    /// "found nothing", so a stale index still toasted a removal and posted a
    /// change notification.
    enum RemoveOutcome {
        case removed
        /// No entry with that id — the list moved under a menu that was already
        /// open. Nothing was sent and nothing is claimed.
        case notFound
        case failed(any Error)
    }

    /// Removes an entry and tells the server. On refusal the row is already
    /// back — the screen must not claim a removal the playlist did not record.
    ///
    /// Takes the ENTRY id, not an index: the same film can sit in a playlist
    /// twice, only `getPlaylistItems` populates `playlistItemID`, and a menu
    /// closure built before a reload would carry an index that now points at a
    /// different row. Resolving the position here makes the guarantee
    /// unconditional rather than dependent on the list not having moved.
    func remove(entryId: String, playlistId: String, using appState: AppState) async -> RemoveOutcome {
        guard let index = items.firstIndex(where: { $0.playlistItemID == entryId }) else {
            return .notFound
        }
        let snapshot = items
        items.remove(at: index)
        if items.isEmpty { state = .empty }
        do {
            try await appState.apiClient.removeFromPlaylist(playlistId: playlistId, entryIds: [entryId])
            return .removed
        } catch {
            logger.error("Playlist remove failed: \(error.localizedDescription, privacy: .public)")
            items = snapshot
            state = .loaded
            return .failed(error)
        }
    }

    /// Removes several entries in ONE request — a folded series, or every
    /// watched title. Optimistic, rolled back when the server refuses; returns
    /// the error then. Ids no longer in the list are simply not sent.
    func remove(entryIds: [String], playlistId: String, using appState: AppState) async -> (any Error)? {
        let wanted = Set(entryIds)
        let present = items.compactMap(\.playlistItemID).filter(wanted.contains)
        guard !present.isEmpty else { return nil }
        let snapshot = items
        let gone = Set(present)
        items.removeAll { $0.playlistItemID.map(gone.contains) ?? false }
        if items.isEmpty { state = .empty }
        do {
            try await appState.apiClient.removeFromPlaylist(playlistId: playlistId, entryIds: present)
            return nil
        } catch {
            logger.error("Playlist bulk remove failed: \(error.localizedDescription, privacy: .public)")
            items = snapshot
            state = .loaded
            return error
        }
    }

    /// Undoes a removal: adds the title again, then moves the new entry back
    /// to `index`. Jellyfin only appends, and the new entry's id is not in the
    /// add's response — so the list is read again and the LAST entry of that
    /// title is the one just added.
    func restore(_ item: BaseItemDto, at index: Int, playlistId: String, using appState: AppState) async -> (any Error)? {
        guard let itemId = item.id, let userId = appState.currentUserId else { return JellyfinError.malformedRecord }
        do {
            try await appState.apiClient.addToPlaylist(playlistId: playlistId, itemIds: [itemId], userId: userId)
            var fresh = try await appState.apiClient.getPlaylistItems(playlistId: playlistId, userId: userId)
            if let position = fresh.lastIndex(where: { $0.id == itemId }),
               let entryId = fresh[position].playlistItemID,
               index < position {
                try await appState.apiClient.movePlaylistItem(
                    playlistId: playlistId, entryId: entryId, newIndex: index
                )
                let entry = fresh.remove(at: position)
                fresh.insert(entry, at: index)
            }
            items = fresh
            state = fresh.isEmpty ? .empty : .loaded
            return nil
        } catch {
            logger.error("Playlist restore failed: \(error.localizedDescription, privacy: .public)")
            // Whatever half of it went through, show what the server holds.
            await load(playlistId: playlistId, using: appState)
            return error
        }
    }

    /// Moves an entry and tells the server. Returns the error when the server
    /// refused, having already put the list back — the row must not stay where
    /// the finger dropped it if the playlist did not actually change.
    ///
    /// Optimistic on purpose: a drag that waits for a round-trip before the row
    /// settles reads as a dropped gesture.
    func move(from source: Int, to target: Int, playlistId: String, using appState: AppState) async -> (any Error)? {
        guard items.indices.contains(source), target >= 0, target < items.count else { return nil }
        let snapshot = items
        let entry = items.remove(at: source)
        items.insert(entry, at: target)
        guard let entryId = entry.playlistItemID else {
            // No entry id means the list did not come from `getPlaylistItems`,
            // which is the only thing that populates it — refuse rather than
            // address the wrong occurrence.
            items = snapshot
            // NOT `.notConnected`, which `userFacingMessage` renders as a
            // network problem: the server is fine, this entry simply has no id
            // to address it by.
            return JellyfinError.malformedRecord
        }
        do {
            try await appState.apiClient.movePlaylistItem(
                playlistId: playlistId, entryId: entryId, newIndex: target
            )
            return nil
        } catch {
            logger.error("Playlist move failed: \(error.localizedDescription, privacy: .public)")
            items = snapshot
            return error
        }
    }
}
