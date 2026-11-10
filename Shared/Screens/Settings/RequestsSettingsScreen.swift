import SwiftUI
import CinemaxKit

/// Réglages → Demandes (Seerr, spec 2026-11-06), iOS AND tvOS.
///
/// A Jellyfin ADMIN gets a summary (layout A, owner 2026-11-09): a card for
/// the connection and its one useful action (`SeerrSummaryCard`), then rows
/// that each open a page — **À valider**, **Mes demandes**, and under
/// « Administration » **Qui peut demander** and **Serveur Seerr** (Connexion,
/// address + « Tester la connexion », Sur cet appareil). iOS pushes the page
/// (`RequestsSubpageHost`); tvOS draws it in place
/// (`SettingsNavCoordinator.requestsPage`). Anyone else keeps one page:
/// **À valider** (a Seerr user who may manage requests — Seerr's permission,
/// never Jellyfin's admin flag), **Mes demandes**, **Connexion**.
///
/// The pages are this view's own sections: the state stays here, the loaders
/// sit on the outer container (`lifecycle`) so a page drawn in place on tvOS
/// never cancels them.
///
/// A standalone view with its own environment: iOS pushes it inside the
/// Settings detail wrapper, where an extension method returning `some View`
/// would never redraw on an `@Observable` change (root RULE). On tvOS it is
/// rendered inside `tvDetailView`, with its own focus lane (`tvActionRow` and
/// `tvGlassToggle` read `SettingsScreen`'s — the `MenuSettingsScreen`
/// precedent), every row ONE focusable unit — but an « À valider » row, whose
/// two buttons are each one.
///
/// Nothing here reads `isPro`: the category row is the Pro gate
/// (`SettingsCategory.proFeature`), and `SeerrSession` makes no call without it.
struct RequestsSettingsScreen: View, SeerrSettingsChrome {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(SeerrSession.self) private var seerr
    @Environment(SeerrRequestPresenter.self) private var seerrRequests: SeerrRequestPresenter?
    @Environment(\.motionEffectsEnabled) private var motionEffects
    /// Never read: declaring it makes the screen redraw when the text size
    /// changes. Its fonts (`CinemaFont.dynamic*`) are point sizes computed
    /// while the body runs, so without this the rows kept the old size until
    /// the page was left and opened again (recette R2, 2026-11-08).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Replaced on an account change: another account's users are never shown.
    @State private var activation = SeerrActivationModel()
    @State private var addressText = ""
    @State private var keyText = ""
    /// The last report worth showing — an empty one (R19) never replaces it.
    @State private var report: SeerrTestReport?
    /// The address `report` describes: an edit naming another one clears it.
    @State private var reportAddress: URL?
    /// Replaced on an account change, like `activation`.
    @State private var myRequests = SeerrMyRequestsModel()
    /// What « Mes demandes » was last LOADED for (the tvOS `.task` re-fire
    /// guard, as `loadedTrigger`) — never a failed load, which the next
    /// re-presentation tries again (recette R30).
    @State private var myRequestsLoadedFor: RequestListTrigger?
    /// Replaced on an account change, like `activation`.
    @State private var pending = SeerrPendingModel()
    @State private var pendingLoadedFor: RequestListTrigger?
    /// « Actualiser » is under way (the iOS pull or bar button, the tvOS row):
    /// the bar button turns into a spinner, the tvOS row says so.
    @State private var isRefreshing = false
    /// The summary card's « Réessayer » (Seerr not answering) is on its way.
    @State private var isRetryingSummary = false
    /// iOS: the page pushed over the summary (tvOS:
    /// `SettingsNavCoordinator.requestsPage`).
    @State private var openedPage: RequestsPage?
    /// A « Réessayer » press is on its way: the failed panel stays, its row
    /// turning, rather than giving way to the spinner (on tvOS the pressed row
    /// would vanish under focus).
    @State private var isRetryingMyRequests = false
    @State private var isRetryingPending = false
    @State private var isTesting = false
    @State private var isSigningIn = false
    @State private var isBulkUpdating = false
    @State private var isLoadingLines = false
    /// The account page open on top of the list (proposal B, 2026-11-08).
    /// iOS pushes it; tvOS draws it in place of the page, its user id held by
    /// `SettingsNavCoordinator.requestsUserId` (the back row reads it).
    @State private var openedUser: OpenedSeerrUser?
    #if os(tvOS)
    @Environment(SettingsNavCoordinator.self) private var settingsNav
    #endif
    /// The address this device's key was entered for (`nil` = no key). Read
    /// from the Keychain on appear and after each change, never per render.
    @State private var storedKeyOrigin: URL?
    @State private var showsDisableAllConfirm = false
    /// The pending request « Refuser » was pressed on, waiting for the
    /// confirmation (recette Q1): a refusal cannot be taken back here.
    @State private var declineCandidate: SeerrRequestRow?
    /// My pending request « Annuler la demande » was pressed on, waiting for
    /// the confirmation.
    @State private var cancelCandidate: SeerrRequestRow?
    /// What the user lines were last loaded for. The tvOS `.task` re-fires on
    /// every re-presentation of Settings (Settings RULE): an unchanged trigger
    /// loads nothing.
    @State private var loadedTrigger: LoadTrigger?

    #if os(tvOS)
    @FocusState private var focusedItem: SettingsFocus?
    #endif

    /// The inputs the per-user lines depend on: who is asking, with which
    /// Seerr identity, toward which address.
    private struct LoadTrigger: Equatable {
        let account: String?
        let isAdmin: Bool
        let connection: SeerrSession.Connection
        let usesDeviceKey: Bool
        let url: URL?
    }

    private var trigger: LoadTrigger {
        LoadTrigger(account: appState.activeAccountKey, isAdmin: appState.isAdministrator,
                    connection: seerr.connection, usesDeviceKey: seerr.usesDeviceKey, url: seerr.config?.url)
    }

    /// Who a request list is read for, toward which Seerr.
    private struct RequestListTrigger: Equatable {
        let account: String?
        let user: SeerrUserID
        let url: URL?
    }

    /// `nil` = the section is not shown: an account Seerr is not enabled for
    /// (an admin setting it up), or not signed in — the Connexion section
    /// already invites to sign in.
    private var myRequestsTrigger: RequestListTrigger? {
        guard seerr.config?.isEnabled == true, case .connected(let user) = seerr.connection else { return nil }
        return RequestListTrigger(account: appState.activeAccountKey, user: user.id, url: seerr.config?.url)
    }

    /// `nil` = « À valider » is not shown: not signed in to Seerr, or a Seerr
    /// user who may not manage requests. Unlike Mes demandes it does not ask
    /// for the account's own switch: an admin who manages the household's
    /// requests without requesting anything still validates them.
    private var pendingTrigger: RequestListTrigger? {
        guard SeerrPendingModel.isShown(for: seerr.connection), case .connected(let user) = seerr.connection else {
            return nil
        }
        return RequestListTrigger(account: appState.activeAccountKey, user: user.id, url: seerr.config?.url)
    }

    /// Re-read at render: an account switch to a capped (or not enabled)
    /// profile while the page is open shows nothing of Seerr.
    private var isVisible: Bool {
        SeerrAccess.showsSettingsCategory(ageCapped: seerr.isAgeCapped, isAdmin: appState.isAdministrator,
                                          config: seerr.config)
    }

    private var typedAddress: URL? { SeerrAddress.normalize(addressText) }
    private var typedKey: String { keyText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasStoredKey: Bool { storedKeyOrigin != nil }
    /// The test runs in key mode: a key typed in the field, or the stored one
    /// when it was entered for the typed address.
    private var testUsesKey: Bool {
        !typedKey.isEmpty || (storedKeyOrigin != nil && SeerrAddress.sameOrigin(storedKeyOrigin, typedAddress))
    }
    /// A stored key entered for another address than the saved one: unused.
    private var storedKeyIsForAnotherAddress: Bool {
        storedKeyOrigin != nil && !SeerrAddress.sameOrigin(storedKeyOrigin, seerr.config?.url)
    }

    var body: some View {
        #if os(iOS)
        // The page owns its scroll view (like Administration): `.refreshable`
        // only reaches the scroll view it is set on, and the bar button lives
        // here with the state it shows.
        lifecycle(
            ScrollView(showsIndicators: false) {
                page
                    .padding(.horizontal, CinemaSpacing.spacing3)
                    .padding(.bottom, CinemaSpacing.spacing8)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(SettingsCategory.requests.localizedName(loc))
            .navigationBarTitleDisplayMode(.large)
            // Not awaited: while the pull's own spinner runs, the bar does not
            // redraw (measured: the button kept its arrow over the skeleton). The
            // pull lets go at once; the bar button and the skeleton show the rest.
            .refreshable { Task { await refresh() } }
            // A member's page has no summary: the account page opens from here
            // only for an admin, through « Qui peut demander ».
            .navigationDestination(item: $openedPage) { target in
                RequestsSubpageHost(screen: self, page: target)
            }
            .toolbar {
                if showsRefresh {
                    ToolbarItem(placement: .topBarTrailing) { refreshBarButton }
                }
            }
            // Under a pushed page the summary is covered: the page itself
            // presents the confirmations.
            .modifier(RequestAlerts(screen: self, isActive: openedPage == nil))
        )
        #else
        lifecycle(
            Group {
                if let id = settingsNav.requestsUserId {
                    SeerrAccountPage(activation: activation, userId: id)
                        .tvBackAction { settingsNav.requestsUserId = nil }
                } else if let target = settingsNav.requestsPage {
                    subpageContent(target)
                        .tvBackAction { settingsNav.requestsPage = nil }
                } else {
                    page
                }
            }
            // Back from the account page (Menu or the « ‹ Demandes » row): focus
            // returns to that user's row once the list is drawn again.
            .onChange(of: settingsNav.requestsUserId) { closed, now in
                guard now == nil, let closed else { return }
                Task { @MainActor in focusedItem = .toggle("seerr.user.\(closed)") }
            }
            // Back from a page: focus returns to its row of the summary.
            .onChange(of: settingsNav.requestsPage) { closed, now in
                guard now == nil, let closed else { return }
                Task { @MainActor in focusedItem = .toggle(hubRowId(closed)) }
            }
            .modifier(RequestAlerts(screen: self, isActive: true))
        )
        #endif
    }

    /// The loaders and the account-change reset, on the OUTER container: a
    /// page drawn in place (tvOS) replaces the summary, and a `.task` on the
    /// summary would be cancelled — `loadPendingIfNeeded` then records
    /// nothing, and the page would stay empty.
    private func lifecycle<Content: View>(_ content: Content) -> some View {
        content
            .task(id: trigger) { await loadLinesIfNeeded() }
            .task(id: myRequestsTrigger) { await loadMyRequestsIfNeeded() }
            .task(id: pendingTrigger) { await loadPendingIfNeeded() }
            .onAppear {
                seedAddress()
                refreshStoredKey()
            }
            .onChange(of: seerr.config?.url) { _, _ in seedAddress() }
            // A report says what one address answered: editing the field to name
            // another takes it away (recette R27).
            .onChange(of: addressText) { _, typed in
                if report != nil, !SeerrTestReport.stillApplies(typed: typed, testedAddress: reportAddress) {
                    report = nil
                    reportAddress = nil
                }
            }
            .onChange(of: appState.activeAccountKey) { _, _ in resetForAccountChange() }
    }

    /// Something to re-read: one of the two lists is on the page.
    private var showsRefresh: Bool {
        isVisible && (myRequestsTrigger != nil || pendingTrigger != nil)
    }

    #if os(iOS)
    /// Liquid Glass draws the bar item itself (no `.glass` style — root RULE).
    /// While a refresh runs — pulled or pressed — the arrow gives way to a
    /// spinner, as the tvOS row's « Actualisation… ».
    fileprivate var refreshBarButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            if isRefreshing {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isRefreshing)
        .tint(themeManager.accent)
        .accessibilityLabel(loc.localized(isRefreshing ? "seerr.settings.refreshing" : "seerr.settings.refresh"))
    }
    #endif

    #if os(tvOS)
    /// No pull on a remote: the row, first under the back button. Never
    /// disabled while it runs (tvOS busy RULE): it keeps the focus while both
    /// lists turn to their skeleton.
    @ViewBuilder
    private var tvRefreshRow: some View {
        if showsRefresh {
            panel {
                actionRow(id: "seerr.refresh", icon: "arrow.clockwise",
                          label: loc.localized(isRefreshing ? "seerr.settings.refreshing" : "seerr.settings.refresh"),
                          isBusy: isRefreshing) {
                    Task { await refresh() }
                }
            }
        }
    }
    #endif

    private var page: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            if !isVisible {
                noteText(loc.localized("seerr.settings.unavailable"))
            } else if appState.isAdministrator {
                summary
            } else {
                memberPage
            }
        }
    }

    /// Not an admin: one page, as before the summary.
    @ViewBuilder
    private var memberPage: some View {
        #if os(tvOS)
        tvRefreshRow
        #endif
        if pendingTrigger != nil {
            pendingSection
        }
        if myRequestsTrigger != nil {
            myRequestsSection
        }
        connectionSection
    }

    // MARK: - Summary (admin)

    private var summaryCard: SeerrSummaryCard {
        SeerrSummaryCard.of(url: seerr.config?.url, connection: seerr.connection, usesDeviceKey: seerr.usesDeviceKey)
    }

    @ViewBuilder
    private var summary: some View {
        let card = summaryCard
        #if os(tvOS)
        tvRefreshRow
        #endif
        summaryCardView(card)
        if card.showsRequestRows {
            requestRows(lockedBy: card.lockedReasonKey.map { loc.localized($0) })
        }
        if card.showsAdministration {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                sectionHeader(loc.localized("seerr.hub.admin"))
                panel {
                    hubRow(.users, detail: usersDetail)
                    divider
                    hubRow(.server, detail: loc.localized("seerr.hub.server.detail"))
                }
            }
        }
    }

    @ViewBuilder
    private func summaryCardView(_ card: SeerrSummaryCard) -> some View {
        switch card {
        case .setup:
            panel {
                contentRow {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                        Text(loc.localized("seerr.hub.welcome.title"))
                            .font(rowLabelFont.weight(.semibold))
                            .foregroundStyle(CinemaColor.onSurface)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(loc.localized("seerr.hub.welcome.text"))
                            .font(rowDetailFont)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                divider
                actionRow(id: hubRowId(.server), icon: "gearshape", label: loc.localized("seerr.hub.welcome.action")) {
                    openPage(.server)
                }
            }
            noteText(loc.localized("seerr.hub.welcome.note"))
        case .signIn:
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                panel {
                    infoRow(icon: "person.crop.circle", text: loc.localized("seerr.hub.signedOut"),
                            tint: CinemaColor.onSurfaceVariant)
                    divider
                    actionRow(id: "seerr.signIn", icon: "person.crop.circle.badge.checkmark",
                              label: loc.localized("seerr.settings.signIn"), isBusy: isSigningIn) {
                        Task { await signIn() }
                    }
                    .disabled(busy(isSigningIn))
                }
                noteText(loc.localized("seerr.hub.signIn.note"))
            }
        case .unavailable:
            panel {
                infoRow(icon: "exclamationmark.triangle", text: loc.localized("seerr.settings.connection.unavailable"),
                        tint: CinemaColor.error)
                divider
                actionRow(id: "seerr.summary.retry", icon: "arrow.clockwise", label: loc.localized("action.retry"),
                          isBusy: isRetryingSummary) {
                    Task { await retrySummary() }
                }
                .disabled(busy(isRetryingSummary))
            }
        case .failure(let failure):
            panel { failureRow(failure) }
        case .connected(let user, let usesDeviceKey):
            let name = user.displayName ?? appState.currentUser?.name ?? ""
            panel {
                if usesDeviceKey {
                    infoRow(icon: "key.fill", text: loc.localized("seerr.settings.deviceKeyProfile", name))
                } else {
                    infoRow(icon: "checkmark.circle.fill", text: loc.localized("seerr.settings.connectedAs", name),
                            tint: CinemaColor.success)
                }
            }
        }
    }

    /// « À valider » and « Mes demandes ». Connected: each one only when it
    /// applies (a Seerr manager; Seerr enabled for this account). Otherwise
    /// both greyed with `lockedBy` — who manages requests is Seerr's to say.
    @ViewBuilder
    private func requestRows(lockedBy: String?) -> some View {
        let isLocked = lockedBy != nil
        let showsPending = isLocked || pendingTrigger != nil
        let showsMine = isLocked ? seerr.config?.isEnabled == true : myRequestsTrigger != nil
        if showsPending || showsMine {
            panel {
                if showsPending {
                    hubRow(.pending, detail: lockedBy ?? pendingDetail, badge: isLocked ? nil : pendingBadge,
                           isLocked: isLocked)
                }
                if showsPending, showsMine { divider }
                if showsMine {
                    hubRow(.mine, detail: lockedBy ?? myRequestsDetail, isLocked: isLocked)
                }
            }
        }
    }

    private var pendingDetail: String {
        switch pending.phase {
        case .idle, .loading: loc.localized("seerr.hub.loading")
        case .failed: loc.localized("seerr.settings.connection.unavailable")
        case .loaded: Self.countDetail(pending.count, none: "seerr.hub.pending.none", some: "seerr.hub.pending.count", loc: loc)
        }
    }

    /// The listing's own total, once it said it (nothing at 0).
    private var pendingBadge: Int? {
        pending.phase == .loaded ? pending.count : nil
    }

    private var myRequestsDetail: String {
        switch myRequests.phase {
        case .idle, .loading: loc.localized("seerr.hub.loading")
        case .failed: loc.localized("seerr.settings.connection.unavailable")
        case .loaded: Self.countDetail(myRequests.count, none: "seerr.hub.mine.none", some: "seerr.hub.mine.count", loc: loc)
        }
    }

    /// « Rien en attente » at 0, else the counted line.
    private static func countDetail(_ total: Int, none: String, some: String, loc: LocalizationManager) -> String {
        if total < 1 { return loc.localized(none) }
        return loc.counted(some, total)
    }

    private var usersDetail: String {
        let lines = activation.lines
        if lines.isEmpty { return loc.localized("seerr.hub.loading") }
        return loc.localized("seerr.hub.users.detail", activation.enabledCount, lines.count)
    }

    private func hubRowId(_ target: RequestsPage) -> String { "seerr.hub.\(target.rawValue)" }

    private func openPage(_ target: RequestsPage) {
        #if os(tvOS)
        settingsNav.requestsPage = target
        #else
        openedPage = target
        #endif
    }

    /// One summary row: icon, title, what it holds, a count bubble, a
    /// chevron. ONE focusable unit on tvOS; greyed and inert while Seerr
    /// cannot be read (a data condition, so disabling is allowed there).
    private func hubRow(_ target: RequestsPage, detail: String, badge: Int? = nil, isLocked: Bool = false) -> some View {
        let id = hubRowId(target)
        let title = loc.localized(target.titleKey)
        return Button {
            openPage(target)
        } label: {
            rowChrome(id: id) {
                HStack(spacing: CinemaSpacing.spacing3) {
                    rowIcon(target.icon, tint: themeManager.accent)
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                        Text(title)
                            .font(rowLabelFont)
                            .foregroundStyle(CinemaColor.onSurface)
                        Text(detail)
                            .font(rowDetailFont)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    #if os(tvOS)
                    .padding(.vertical, CinemaSpacing.spacing2)
                    #endif
                    Spacer(minLength: CinemaSpacing.spacing3)
                    // Never inverted: a focused row here is outlined, not
                    // filled with the accent as the Réglages entry is.
                    if let badge, let label = SeerrPendingModel.badgeLabel(badge) {
                        SettingsCountBadge(label: label)
                    }
                    Image(systemName: "chevron.right")
                        .font(rowDetailFont.weight(.semibold))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.5 : 1)
        .modifier(RowFocus(id: id, focus: focusBinding))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Pages (admin)

    /// One page of the summary. iOS wraps it (`subpage`); tvOS draws it in
    /// place, its title first since the category's back row only says
    /// « ‹ Demandes ».
    fileprivate func subpageContent(_ target: RequestsPage) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            #if os(tvOS)
            Text(loc.localized(target.titleKey))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)
                .accessibilityAddTraits(.isHeader)
            if target == .pending || target == .mine {
                tvRefreshRow
            }
            #endif
            switch target {
            case .pending:
                if pendingTrigger != nil {
                    pendingContent
                } else {
                    noteText(loc.localized(summaryCard.lockedReasonKey ?? "seerr.hub.locked.signIn"))
                }
            case .mine:
                if myRequestsTrigger != nil {
                    myRequestsContent
                } else {
                    noteText(loc.localized(summaryCard.lockedReasonKey ?? "seerr.hub.locked.signIn"))
                }
            case .users:
                if seerr.config?.url != nil {
                    usersBlock
                } else {
                    noteText(loc.localized("seerr.settings.connection.noAddress"))
                }
            case .server:
                connectionSection
                configurationSection
                deviceSection
            }
        }
    }

    #if os(iOS)
    /// The pushed page: its own scroll view, title, pull and bar button (the
    /// two lists only), the account page's destination (« Qui peut
    /// demander »), and the confirmations — the summary under it is covered.
    fileprivate func subpage(_ target: RequestsPage) -> some View {
        let isList = target == .pending || target == .mine
        return ScrollView(showsIndicators: false) {
            subpageContent(target)
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.bottom, CinemaSpacing.spacing8)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized(target.titleKey))
        .navigationBarTitleDisplayMode(.large)
        .modifier(PullToRefresh(action: isList ? { Task { await refresh() } } : nil))
        .navigationDestination(item: $openedUser) { opened in
            SeerrAccountPage(activation: activation, userId: opened.id)
        }
        .toolbar {
            if isList, showsRefresh {
                ToolbarItem(placement: .topBarTrailing) { refreshBarButton }
            }
        }
        .modifier(RequestAlerts(screen: self, isActive: true))
    }
    #endif

    // MARK: - Confirmations

    /// « Tout désactiver », « Refuser », « Annuler la demande ». `isActive`
    /// false leaves them to the page on top (iOS: the summary under a pushed
    /// page presents nothing).
    fileprivate struct RequestAlerts: ViewModifier {
        let screen: RequestsSettingsScreen
        let isActive: Bool

        func body(content: Content) -> some View {
            screen.withAlerts(content, isActive: isActive)
        }
    }

    fileprivate func withAlerts<Content: View>(_ content: Content, isActive: Bool) -> some View {
        content
            .alert(loc.localized("seerr.settings.disableAll"),
                   isPresented: Binding(get: { isActive && showsDisableAllConfirm },
                                        set: { if !$0 { showsDisableAllConfirm = false } })) {
                Button(loc.localized("seerr.settings.disableAll"), role: .destructive) {
                    Task { await disableAll() }
                }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: {
                Text(loc.localized("seerr.settings.disableAll.confirm"))
            }
            .alert(declineCandidate.map { loc.localized("seerr.pending.decline.confirm", requestTitle($0)) } ?? "",
                   isPresented: Binding(get: { isActive && declineCandidate != nil },
                                        set: { if !$0 { declineCandidate = nil } }),
                   presenting: declineCandidate) { row in
                Button(loc.localized("seerr.pending.decline"), role: .destructive) { settle(row, .decline) }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            }
            .alert(cancelCandidate.map { loc.localized("seerr.myRequests.cancel.confirm", requestTitle($0)) } ?? "",
                   isPresented: Binding(get: { isActive && cancelCandidate != nil },
                                        set: { if !$0 { cancelCandidate = nil } }),
                   presenting: cancelCandidate) { row in
                Button(loc.localized("seerr.myRequests.cancel"), role: .destructive) { withdraw(row) }
                Button(loc.localized("seerr.myRequests.cancel.keep"), role: .cancel) {}
            }
    }

    // MARK: - Mes demandes

    private var myRequestsSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader(loc.localized("seerr.settings.section.myRequests"))
            myRequestsContent
        }
    }

    @ViewBuilder
    private var myRequestsContent: some View {
        switch myRequests.phase {
        case .idle, .loading:
            if isRetryingMyRequests {
                failedPanel(retryId: "seerr.requests.retry", isRetrying: true) {}
            } else {
                skeletonPanel(rows: 3)
            }
        case .failed:
            failedPanel(retryId: "seerr.requests.retry", isRetrying: false) {
                Task { await retryMyRequests() }
            }
        case .loaded:
            let rows = myRequests.rows
            panel {
                if rows.isEmpty {
                    infoRow(icon: "tray", text: loc.localized("seerr.myRequests.empty"))
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    requestRow(row)
                    if index < rows.count - 1 || myRequests.canLoadMore { divider }
                }
                if myRequests.canLoadMore {
                    // Never `.disabled` while it loads: on tvOS that would
                    // throw focus off the row being pressed; the model ignores
                    // a second press itself.
                    actionRow(id: "seerr.requests.more", icon: "ellipsis.circle",
                              label: loc.localized("seerr.myRequests.more"), isBusy: myRequests.isLoadingMore) {
                        Task { await myRequests.loadNextPage(session: seerr) }
                    }
                }
            }
        }
    }

    /// What pressing a row of Mes demandes does: open an arrived title,
    /// withdraw a pending one (after a confirmation), or nothing.
    private enum RequestRowAction { case watch, cancel, none }

    private func requestRowAction(_ row: SeerrRequestRow) -> RequestRowAction {
        if SeerrMyRequestsModel.watchTarget(row.request) != nil { return .watch }
        if SeerrMyRequestsModel.canCancel(row.request) { return .cancel }
        return .none
    }

    private func press(_ row: SeerrRequestRow, _ action: RequestRowAction) {
        switch action {
        case .watch: SeerrMyRequestsModel.watch(row.request, appState: appState)
        case .cancel: if myRequests.cancelling == nil { cancelCandidate = row }
        case .none: break
        }
    }

    /// Sends the withdrawal. tvOS: focus then goes to the row taking its place.
    private func withdraw(_ row: SeerrRequestRow) {
        #if os(tvOS)
        let formerIndex = myRequests.rows.firstIndex { $0.id == row.id }
        #endif
        Task {
            await myRequests.cancel(row.id, session: seerr, toasts: toasts, loc: loc)
            // Withdrawn: a manager's own request leaves « À valider » too.
            if !myRequests.rows.contains(where: { $0.id == row.id }) {
                pending.forget(row.id, session: seerr)
                // Its card may be asked for again.
                seerrRequests?.forget(row.request)
            }
            #if os(tvOS)
            // Confirmed in an alert opened from this row: focus is the
            // alert's until it closes, so it never reads as « still here ».
            focusAfterWithdrawing(row.id, formerIndex: formerIndex)
            #endif
        }
    }

    /// One request. tvOS: ONE focusable unit per row, an inert one included —
    /// the remote scrolls by focus, so a row nobody can focus could not be
    /// reached; Select opens an arrived title or withdraws a pending one.
    /// iOS: only those two kinds of row are buttons.
    @ViewBuilder
    private func requestRow(_ row: SeerrRequestRow) -> some View {
        let id = "seerr.request.\(row.id)"
        let action = requestRowAction(row)
        #if os(tvOS)
        Button {
            press(row, action)
        } label: {
            rowChrome(id: id) { requestRowContent(row, action: action) }
        }
        .buttonStyle(.plain)
        .modifier(RowFocus(id: id, focus: focusBinding))
        .accessibilityElement(children: .combine)
        #else
        if action == .none {
            rowChrome(id: id) { requestRowContent(row, action: .none) }
                .accessibilityElement(children: .combine)
        } else {
            Button {
                press(row, action)
            } label: {
                rowChrome(id: id) { requestRowContent(row, action: action) }
            }
            .buttonStyle(.plain)
            .disabled(action == .cancel && myRequests.cancelling != nil)
            .accessibilityElement(children: .combine)
        }
        #endif
    }

    @ViewBuilder
    private func requestRowContent(_ row: SeerrRequestRow, action: RequestRowAction) -> some View {
        let text = HStack(spacing: CinemaSpacing.spacing3) {
            requestPoster(row)
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                requestTitleText(row)
                Text(loc.localized(SeerrMyRequestsModel.statusKey(row.request)))
                    .font(rowDetailFont)
                    .foregroundStyle(statusTint(row.request))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let watch = Group {
            switch action {
            case .watch:
                Label(loc.localized("seerr.myRequests.watch"), systemImage: "play.fill")
                    .font(rowDetailFont.weight(.semibold))
                    .foregroundStyle(themeManager.accent)
            case .cancel:
                if myRequests.cancelling == row.id {
                    ProgressView()
                        .accessibilityLabel(loc.localized("seerr.myRequests.cancelling"))
                } else {
                    Label(loc.localized("seerr.myRequests.cancel"), systemImage: "xmark.circle")
                        .font(rowDetailFont.weight(.semibold))
                        .foregroundStyle(CinemaColor.error)
                }
            case .none:
                EmptyView()
            }
        }
        #if os(tvOS)
        HStack(spacing: CinemaSpacing.spacing3) {
            text.padding(.vertical, CinemaSpacing.spacing2)
            Spacer(minLength: CinemaSpacing.spacing3)
            watch
        }
        #else
        SettingsRowAdaptiveLayout {
            text
        } control: {
            watch
        }
        #endif
    }

    /// The row's title line — a placeholder bar while its lookup is on its way.
    private func requestTitleText(_ row: SeerrRequestRow) -> some View {
        Text(requestTitle(row))
            .font(rowLabelFont)
            .foregroundStyle(row.title == nil ? CinemaColor.onSurfaceVariant : CinemaColor.onSurface)
            .fixedSize(horizontal: false, vertical: true)
            .redacted(reason: row.isTitlePending ? .placeholder : [])
            .accessibilityHidden(row.isTitlePending)
    }

    /// The title, or « Titre indisponible » once its lookup failed (a bar
    /// while it is on its way); a series adds its seasons.
    private func requestTitle(_ row: SeerrRequestRow) -> String {
        let title = row.title ?? loc.localized("seerr.myRequests.titleUnavailable")
        guard let seasons = SeerrMyRequestsModel.seasonsSuffix(row.request, loc: loc) else { return title }
        return "\(title) · \(seasons)"
    }

    private func statusTint(_ request: SeerrRequest) -> Color {
        switch SeerrMyRequestsModel.status(request) {
        case .available: CinemaColor.success
        case .declined: CinemaColor.error
        case .pending, .approved: CinemaColor.onSurfaceVariant
        }
    }

    private func requestPoster(_ row: SeerrRequestRow) -> some View {
        let url = seerr.client.flatMap {
            SeerrImages.posterURL(path: row.posterPath, seerrBase: $0.baseURL,
                                  cacheImages: seerr.publicSettings?.cacheImages ?? false)
        }
        return Color.clear
            .frame(width: requestPosterWidth, height: requestPosterWidth * 1.5)
            .overlay {
                CinemaLazyImage(url: url, fallbackIcon: row.request.kind == .movie ? "film" : "tv")
            }
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private var requestPosterWidth: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(60)
        #else
        CinemaScale.pt(44)
        #endif
    }

    // MARK: - À valider

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            // The count only once the listing said it: « (0) » while loading
            // would be false.
            sectionHeader(pending.phase == .loaded
                          ? loc.counted("seerr.settings.section.pendingCount", pending.count)
                          : loc.localized("seerr.settings.section.pending"))
            pendingContent
        }
    }

    @ViewBuilder
    private var pendingContent: some View {
        switch pending.phase {
        case .idle, .loading:
            if isRetryingPending {
                failedPanel(retryId: "seerr.pending.retry", isRetrying: true) {}
            } else {
                skeletonPanel(rows: 1)
            }
        case .failed:
            failedPanel(retryId: "seerr.pending.retry", isRetrying: false) {
                Task { await retryPending() }
            }
        case .loaded:
            let rows = pending.rows
            panel {
                // Every listed row settled while more wait on the server: only
                // « Afficher plus » remains.
                if rows.isEmpty, !pending.canLoadMore {
                    infoRow(icon: "checkmark.circle", text: loc.localized("seerr.pending.empty"))
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    pendingRow(row)
                    if index < rows.count - 1 || pending.canLoadMore { divider }
                }
                if pending.canLoadMore {
                    actionRow(id: "seerr.pending.more", icon: "ellipsis.circle",
                              label: loc.localized("seerr.myRequests.more"), isBusy: pending.isLoadingMore) {
                        Task { await pending.loadNextPage(session: seerr) }
                    }
                }
            }
        }
    }

    /// One pending request: poster, title, who asked and when, then
    /// « Approuver » / « Refuser » side by side under the text. tvOS: the two
    /// buttons are the row's focus units (the text itself takes no focus).
    @ViewBuilder
    private func pendingRow(_ row: SeerrRequestRow) -> some View {
        let content = VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            HStack(spacing: CinemaSpacing.spacing3) {
                requestPoster(row)
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                    requestTitleText(row)
                    Text(SeerrPendingModel.requestedLine(row.request, loc: loc))
                        .font(rowDetailFont)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: CinemaSpacing.spacing3) {
                pendingButton(row, .approve)
                pendingButton(row, .decline)
            }
        }
        #if os(tvOS)
        content
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: CinemaRadius.large).fill(CinemaColor.surfaceContainer))
        #else
        iOSSettingsRow { content }
        #endif
    }

    /// « Approuver » acts on one tap; « Refuser » asks first (recette Q1 —
    /// Seerr's own page asks neither). While the row's
    /// request is being settled, both its buttons wait: disabled on iOS; on
    /// tvOS still focusable — disabling the focused button would throw focus
    /// off it — the pressed one reading « Approbation en cours… » and the
    /// model ignoring any press.
    @ViewBuilder
    private func pendingButton(_ row: SeerrRequestRow, _ action: SeerrPendingModel.Action) -> some View {
        let inFlight = pending.inFlight[row.id]
        let isApprove = action == .approve
        let label = loc.localized(isApprove ? "seerr.pending.approve" : "seerr.pending.decline")
        // What VoiceOver reads (and tvOS shows): the busy state while it runs.
        let current = loc.localized(SeerrPendingModel.buttonTitleKey(action, inFlight: inFlight))
        let press: () -> Void = {
            if isApprove { settle(row, action) } else { declineCandidate = row }
        }
        #if os(tvOS)
        let id = pendingButtonId(row.id, action)
        let isBusy = inFlight == action
        Button {
            press()
        } label: {
            rowChrome(id: id) {
                HStack(spacing: CinemaSpacing.spacing2) {
                    rowIcon(isApprove ? "checkmark.circle.fill" : "xmark.circle",
                            tint: isApprove ? themeManager.accent : CinemaColor.error)
                    Text(current)
                        .font(rowLabelFont)
                        .foregroundStyle(CinemaColor.onSurface)
                }
            }
            .opacity(inFlight != nil && !isBusy ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .modifier(RowFocus(id: id, focus: focusBinding))
        .accessibilityLabel(current)
        #else
        CinemaButton(title: label, style: isApprove ? .accent : .ghost, isLoading: inFlight == action) {
            press()
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(inFlight != nil)
        .accessibilityLabel(current)
        #endif
    }

    /// Sends the decision to Seerr. tvOS: then puts focus back where it was.
    private func settle(_ row: SeerrRequestRow, _ action: SeerrPendingModel.Action) {
        #if os(tvOS)
        let formerIndex = pending.rows.firstIndex { $0.id == row.id }
        // « Refuser » was confirmed in an alert, which held focus: the press
        // itself says where focus was. « Approuver » asks the live focus.
        let wasOnButton = action == .decline || focusedItem == .toggle(pendingButtonId(row.id, action))
        #endif
        Task {
            if action == .approve {
                await pending.approve(row.id, session: seerr, toasts: toasts, loc: loc)
            } else {
                await pending.decline(row.id, session: seerr, toasts: toasts, loc: loc)
            }
            #if os(tvOS)
            focusAfterSettling(row.id, action, formerIndex: formerIndex, wasOnButton: wasOnButton)
            #endif
        }
    }

    #if os(tvOS)
    /// The withdrawn row left the list: focus goes to the row now in its place
    /// (or the last one) — left to itself the engine sent it to the tab bar
    /// (measured on the tvOS simulator, 2026-11-08): the confirmation alert
    /// held focus, so a strict « still on the row » test always failed. Focus
    /// still on the row, or nowhere yet, moves; a user who moved on stays.
    private func focusAfterWithdrawing(_ requestId: Int, formerIndex: Int?) {
        let rows = myRequests.rows
        let pressed = SettingsFocus.toggle("seerr.request.\(requestId)")
        guard focusedItem == nil || focusedItem == pressed, let formerIndex,
              !rows.contains(where: { $0.id == requestId }), !rows.isEmpty else { return }
        focusedItem = .toggle("seerr.request.\(rows[min(formerIndex, rows.count - 1)].id)")
    }

    private func pendingButtonId(_ requestId: Int, _ action: SeerrPendingModel.Action) -> String {
        "seerr.pending.\(requestId).\(action == .approve ? "approve" : "decline")"
    }

    /// The focused button's row just left the list: focus goes to the same
    /// button of the row that took its place — left to itself, the engine
    /// sends it back to the top of the page, and a manager working down the
    /// queue would walk down again after every press (recette 2026-11-07).
    /// Only when focus was on the pressed button (`wasOnButton`, read by the
    /// caller — through an alert, focus is the alert's) and still is, or is
    /// nowhere yet (the alert just closed): a user who moved on keeps their place.
    private func focusAfterSettling(
        _ requestId: Int, _ action: SeerrPendingModel.Action, formerIndex: Int?, wasOnButton: Bool
    ) {
        let rows = pending.rows
        let pressed = SettingsFocus.toggle(pendingButtonId(requestId, action))
        guard wasOnButton, focusedItem == nil || focusedItem == pressed, let formerIndex,
              !rows.contains(where: { $0.id == requestId }) else { return }
        if rows.isEmpty {
            if pending.canLoadMore { focusedItem = .toggle("seerr.pending.more") }
            return
        }
        focusedItem = .toggle(pendingButtonId(rows[min(formerIndex, rows.count - 1)].id, action))
    }
    #endif

    // MARK: - Shared states

    /// A list on its way: rows sketched as they will come (poster, title,
    /// status), the shimmer Home's skeleton uses. Never focusable on tvOS —
    /// the focus stays where it is (the « Actualiser » row, typically).
    private func skeletonPanel(rows: Int) -> some View {
        panel {
            ForEach(0..<rows, id: \.self) { index in
                skeletonRow(index)
                if index < rows - 1 { divider }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized("seerr.settings.loading"))
    }

    @ViewBuilder
    private func skeletonRow(_ index: Int) -> some View {
        let widths: [CGFloat] = [0.7, 0.5, 0.62]
        let line = widths[index % widths.count]
        #if os(tvOS)
        let base = CinemaScale.pt(520), lineHeight = CinemaScale.pt(20)
        #else
        let base = CinemaScale.pt(220), lineHeight = CinemaScale.pt(14)
        #endif
        let content = HStack(spacing: CinemaSpacing.spacing3) {
            SkeletonBlock(cornerRadius: CinemaRadius.small)
                .frame(width: requestPosterWidth, height: requestPosterWidth * 1.5)
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                SkeletonBlock(cornerRadius: lineHeight / 2)
                    .frame(width: base * line, height: lineHeight)
                SkeletonBlock(cornerRadius: lineHeight / 2)
                    .frame(width: base * 0.45, height: lineHeight * 0.8)
            }
            Spacer(minLength: 0)
        }
        #if os(tvOS)
        content
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
        #else
        iOSSettingsRow { content }
        #endif
    }

    /// A list Seerr did not serve: say so, and offer « Réessayer » (R30).
    private func failedPanel(retryId: String, isRetrying: Bool, retry: @escaping () -> Void) -> some View {
        panel {
            infoRow(icon: "info.circle", text: loc.localized("seerr.settings.connection.unavailable"))
            divider
            actionRow(id: retryId, icon: "arrow.clockwise", label: loc.localized("action.retry"),
                      isBusy: isRetrying, action: retry)
        }
    }

    // MARK: - Connexion

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader(loc.localized("seerr.settings.section.connection"))
            panel {
                connectionRows
            }
        }
    }

    @ViewBuilder
    private var connectionRows: some View {
        switch seerr.connection {
        case .connected(let user):
            let name = user.displayName ?? appState.currentUser?.name ?? ""
            if seerr.usesDeviceKey {
                infoRow(icon: "key.fill", text: loc.localized("seerr.settings.deviceKeyProfile", name))
            } else {
                infoRow(icon: "checkmark.circle.fill", text: loc.localized("seerr.settings.connectedAs", name),
                        tint: CinemaColor.success)
                divider
                actionRow(id: "seerr.signOut", icon: "rectangle.portrait.and.arrow.right",
                          label: loc.localized("seerr.settings.signOut")) {
                    Task { await seerr.signOut() }
                }
            }
        case .notConnected:
            actionRow(id: "seerr.signIn", icon: "person.crop.circle.badge.checkmark",
                      label: loc.localized("seerr.settings.signIn"), isBusy: isSigningIn) {
                Task { await signIn() }
            }
            .disabled(busy(isSigningIn))
        case .notLinked:
            failureRow(.notInSeerr)
        case .keyRefused:
            failureRow(.keyRefused)
        case .unavailable:
            infoRow(icon: "info.circle", text: loc.localized(
                seerr.config?.url == nil ? "seerr.settings.connection.noAddress" : "seerr.settings.connection.unavailable"))
        }
    }

    // MARK: - Configuration (admin)

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader(loc.localized("seerr.settings.section.configuration"))

            addressField

            panel {
                actionRow(id: "seerr.test", icon: "checkmark.shield", label: loc.localized("seerr.settings.test"),
                          isBusy: isTesting) {
                    Task { await runTest() }
                }
                .disabled(busy(isTesting) || typedAddress == nil)
            }

            // Account mode signs the admin in: say what that leaves behind.
            if !testUsesKey {
                noteText(loc.localized("seerr.settings.test.accountNote"))
            }

            if let report {
                reportView(report)
            }
        }
    }

    @ViewBuilder
    private var addressField: some View {
        #if os(iOS)
        GlassTextField(label: loc.localized("seerr.settings.address"), text: $addressText,
                       placeholder: loc.localized("seerr.settings.address.placeholder"), icon: "link",
                       keyboardType: .URL)
        #else
        GlassTextField(label: loc.localized("seerr.settings.address"), text: $addressText,
                       placeholder: loc.localized("seerr.settings.address.placeholder"), icon: "link")
        #endif
    }

    @ViewBuilder
    private var usersBlock: some View {
        // No header: the page's title says it, and its summary row the count.
        let lines = activation.lines
        if lines.isEmpty {
            if isLoadingLines {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CinemaSpacing.spacing3)
            }
        } else {
            panel {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    userRow(line)
                    if index < lines.count - 1 { divider }
                }
            }

            panel {
                actionRow(id: "seerr.enableAll", icon: "person.3.fill", label: loc.localized("seerr.settings.enableAll"),
                          isBusy: isBulkUpdating) {
                    Task { await enableAll() }
                }
                .disabled(busy(isBulkUpdating))
                divider
                actionRow(id: "seerr.disableAll", icon: "person.3", label: loc.localized("seerr.settings.disableAll"),
                          tint: CinemaColor.error) {
                    guard !isBulkUpdating else { return }
                    showsDisableAllConfirm = true
                }
                .disabled(busy(isBulkUpdating) || activation.enabledCount == 0)
            }
        }

        noteText(loc.localized("seerr.settings.footnote"))
    }

    // MARK: - Report

    private func reportView(_ report: SeerrTestReport) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            ForEach(report.verified, id: \.self) { line in
                reportLine(icon: "checkmark.circle.fill", tint: CinemaColor.success, title: line, detail: nil)
            }
            ForEach(report.warnings, id: \.self) { warning in
                reportLine(icon: "exclamationmark.triangle.fill", tint: themeManager.accent, title: warning, detail: nil)
            }
            if let failure = report.failure {
                reportLine(icon: "xmark.octagon.fill", tint: CinemaColor.error, title: failureTitle(failure),
                           detail: loc.localized(failure.fixKey))
            }
        }
        .padding(CinemaSpacing.spacing4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        // One element per line for VoiceOver, read in order.
        .accessibilityElement(children: .contain)
    }

    private func reportLine(icon: String, tint: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CinemaSpacing.spacing3) {
            Image(systemName: icon)
                .font(.system(size: CinemaScale.pt(16), weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                Text(title)
                    .font(rowLabelFont)
                    .foregroundStyle(CinemaColor.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(rowDetailFont)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func failureTitle(_ failure: SeerrTestFailure) -> String {
        if case .tooOld(let version) = failure { return loc.localized(failure.titleKey, version) }
        return loc.localized(failure.titleKey)
    }

    /// A failure inside the Connexion section: its title, then how to fix it.
    private func failureRow(_ failure: SeerrTestFailure) -> some View {
        contentRow {
            reportLine(icon: "exclamationmark.circle.fill", tint: CinemaColor.error, title: failureTitle(failure),
                       detail: loc.localized(failure.fixKey))
        }
    }

    // MARK: - Sur cet appareil (admin)

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader(loc.localized("seerr.settings.section.device"))
            #if os(tvOS)
            // Above the field, so the remote's scroll to the last row still shows it.
            noteText(loc.localized("seerr.settings.key.explanation"))
            #endif

            if hasStoredKey {
                panel {
                    // The key is never shown back — only that there is one.
                    infoRow(icon: "key.fill", text: loc.localized("seerr.settings.key.saved"))
                    if storedKeyIsForAnotherAddress {
                        divider
                        infoRow(icon: "exclamationmark.triangle", text: loc.localized("seerr.settings.key.otherAddress"),
                                tint: CinemaColor.error)
                    }
                    divider
                    actionRow(id: "seerr.key.remove", icon: "trash", label: loc.localized("seerr.settings.key.remove"),
                              tint: CinemaColor.error) {
                        Task { await removeKey() }
                    }
                }
            } else {
                #if os(tvOS)
                GlassTextField(label: loc.localized("seerr.settings.key"), text: $keyText,
                               placeholder: loc.localized("seerr.settings.key.placeholder"), icon: "key", isSecure: true)
                #else
                // No label of its own: its bold, inset caption read as a second,
                // misaligned section header under « Sur cet appareil » (recette R3).
                GlassTextField(label: "", text: $keyText,
                               placeholder: loc.localized("seerr.settings.key.placeholder"), icon: "key", isSecure: true)
                    .accessibilityLabel(loc.localized("seerr.settings.key"))
                #endif
                panel {
                    actionRow(id: "seerr.key.save", icon: "square.and.arrow.down", label: loc.localized("seerr.settings.key.save")) {
                        Task { await saveKey() }
                    }
                    .disabled(typedKey.isEmpty)
                }
            }
            #if os(iOS)
            noteText(loc.localized("seerr.settings.key.explanation"))
            #endif
        }
    }

    // MARK: - Actions

    private func seedAddress() {
        if addressText.isEmpty, let url = seerr.config?.url { addressText = url.absoluteString }
    }

    private func refreshStoredKey() {
        storedKeyOrigin = seerr.storedDeviceKeyOrigin(appState: appState)
    }

    private func resetForAccountChange() {
        // Another account's pages are never left on screen.
        openedUser = nil
        openedPage = nil
        #if os(tvOS)
        settingsNav.requestsUserId = nil
        settingsNav.requestsPage = nil
        #endif
        activation = SeerrActivationModel()
        loadedTrigger = nil
        myRequests = SeerrMyRequestsModel()
        myRequestsLoadedFor = nil
        pending = SeerrPendingModel()
        pendingLoadedFor = nil
        isRetryingMyRequests = false
        isRetryingPending = false
        report = nil
        reportAddress = nil
        keyText = ""
        // Emptied, then refilled by `seedAddress` once the new account's
        // configuration is read — never the previous account's address.
        addressText = ""
        seedAddress()
        refreshStoredKey()
    }

    /// The per-user lines need a Seerr identity: they are (re)loaded each time
    /// it, the address or the account moves — not on a mere re-presentation.
    private func loadLinesIfNeeded() async {
        let current = trigger
        guard current.isAdmin, current.url != nil, current != loadedTrigger else { return }
        isLoadingLines = true
        let didLoad = await activation.load(appState: appState, session: seerr)
        // A cancelled load is replaced by the next trigger's: leave it its state.
        guard !Task.isCancelled else { return }
        isLoadingLines = false
        // A failed load records nothing: the next re-presentation tries again.
        if didLoad { loadedTrigger = current }
    }

    /// « Mes demandes » is (re)loaded each time who is asking, as whom or
    /// toward which Seerr moves — not on a mere re-presentation. Leaving the
    /// section (signed out) forgets what it was loaded for, so signing in
    /// again reads the list afresh. A FAILED first page records nothing: the
    /// next re-presentation tries again, and the section offers « Réessayer »
    /// meanwhile (recette R30).
    private func loadMyRequestsIfNeeded() async {
        guard let current = myRequestsTrigger else {
            myRequestsLoadedFor = nil
            return
        }
        guard current != myRequestsLoadedFor else { return }
        await myRequests.loadFirstPage(session: seerr)
        guard !Task.isCancelled, myRequests.phase == .loaded else { return }
        myRequestsLoadedFor = current
    }

    private func retryMyRequests() async {
        guard !isRetryingMyRequests, let current = myRequestsTrigger else { return }
        isRetryingMyRequests = true
        defer { isRetryingMyRequests = false }
        await myRequests.loadFirstPage(session: seerr)
        if myRequests.phase == .loaded, current == myRequestsTrigger { myRequestsLoadedFor = current }
    }

    /// « À valider », on the same terms as Mes demandes.
    private func loadPendingIfNeeded() async {
        guard let current = pendingTrigger else {
            pendingLoadedFor = nil
            return
        }
        guard current != pendingLoadedFor else { return }
        await pending.load(session: seerr)
        guard !Task.isCancelled, pending.phase == .loaded else { return }
        pendingLoadedFor = current
    }

    private func retryPending() async {
        guard !isRetryingPending, let current = pendingTrigger else { return }
        isRetryingPending = true
        defer { isRetryingPending = false }
        await pending.load(session: seerr)
        if pending.phase == .loaded, current == pendingTrigger { pendingLoadedFor = current }
    }

    /// « Actualiser »: both lists re-read side by side (each shows its
    /// skeleton meanwhile), « À valider » writing the bubble's fresh count.
    /// A second press while one runs does nothing.
    private func refresh() async {
        guard !isRefreshing, showsRefresh else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let mine = myRequestsTrigger, waiting = pendingTrigger
        let myModel = myRequests, pendingModel = pending, session = seerr
        await withTaskGroup(of: Void.self) { group in
            if mine != nil { group.addTask { await myModel.loadFirstPage(session: session) } }
            if waiting != nil { group.addTask { await pendingModel.load(session: session) } }
        }
        // A list that had failed to open is now loaded: its `.task` re-fire
        // must not read it a third time.
        if let mine, mine == myRequestsTrigger, myRequests.phase == .loaded { myRequestsLoadedFor = mine }
        if let waiting, waiting == pendingTrigger, pending.phase == .loaded { pendingLoadedFor = waiting }
    }

    /// « Tester la connexion »: on the TYPED address (R18), in key mode when
    /// the key field holds one — or, empty, when this device's stored key was
    /// entered for that address (never displayed). The address is saved only
    /// when nothing failed; an empty report (the account changed, R19) shows
    /// nothing new.
    private func runTest() async {
        guard let address = typedAddress, !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        let key = typedKey.isEmpty ? seerr.deviceKeyForTest(address: address, appState: appState) : typedKey
        let result = await SeerrConnectionTest.run(
            address: address, deviceKey: key, session: seerr, appState: appState, loc: loc)
        guard result != SeerrTestReport() else { return }
        reportAddress = address
        report = result
        guard result.failure == nil else { return }
        addressText = address.absoluteString
        var saveFailed = false
        if !SeerrAddress.sameOrigin(address, seerr.config?.url),
           let message = await activation.setAddress(address, appState: appState, loc: loc) {
            toasts.error(message)
            saveFailed = true
        }
        // The admin's own address (and the session the test signed in) are
        // read again: the lines follow through `trigger`.
        await seerr.reload(appState: appState)
        // A write failed: the field shows the address the server now holds.
        if saveFailed { addressText = seerr.config?.url?.absoluteString ?? "" }
    }

    /// « Se connecter à Seerr », toward the SAVED address only. A failure says
    /// what the connection test would say for the same reason.
    private func signIn() async {
        guard seerr.config?.url != nil, !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        if let failure = await seerr.signInToSavedAddress(appState: appState) {
            showFailure(failure)
        }
    }

    /// The summary's « Réessayer »: the identity read again; still nothing
    /// from Seerr ⇒ the connection test's message for it.
    private func retrySummary() async {
        guard !isRetryingSummary else { return }
        isRetryingSummary = true
        defer { isRetryingSummary = false }
        await seerr.reload(appState: appState)
        if seerr.connection == .unavailable { showFailure(.unreachable) }
    }

    private func showFailure(_ failure: SeerrTestFailure) {
        toasts.error(failureTitle(failure), message: loc.localized(failure.fixKey))
    }

    private func enableAll() async {
        guard !isBulkUpdating else { return }
        isBulkUpdating = true
        defer { isBulkUpdating = false }
        let summary = await activation.enableAll(appState: appState, loc: loc)
        let everyoneOn = activation.lines.allSatisfy(\.isEnabled)
        if everyoneOn { toasts.success(summary) } else { toasts.info(summary) }
        await seerr.reload(appState: appState)
    }

    private func disableAll() async {
        guard !isBulkUpdating else { return }
        isBulkUpdating = true
        defer { isBulkUpdating = false }
        if let message = await activation.disableAll(appState: appState, loc: loc) {
            toasts.error(message)
        } else {
            toasts.success(loc.localized("seerr.settings.disableAll.done"))
        }
        await seerr.reload(appState: appState)
    }

    /// Bound to the SAVED address: the key is only ever sent there.
    private func saveKey() async {
        let key = typedKey
        guard !key.isEmpty else { return }
        guard let address = seerr.config?.url else {
            toasts.info(loc.localized("seerr.activation.noAddress"))
            return
        }
        keyText = ""
        await seerr.setDeviceKey(key, address: address, appState: appState)
        refreshStoredKey()
        if hasStoredKey { toasts.success(loc.localized("seerr.settings.key.savedToast")) }
    }

    private func removeKey() async {
        await seerr.setDeviceKey(nil, address: seerr.config?.url, appState: appState)
        refreshStoredKey()
        if !hasStoredKey { toasts.success(loc.localized("seerr.settings.key.removedToast")) }
    }

    // MARK: - Row building blocks (one look per platform)

    /// Whether an action in flight disables its row. iOS: yes (dimmed, with
    /// its spinner). tvOS: never — disabling the FOCUSED row throws focus
    /// (Seerr RULE); the row keeps its spinner and the action's own
    /// `guard !isX` ignores the press. Only data conditions disable there.
    private func busy(_ inFlight: Bool) -> Bool {
        #if os(tvOS)
        false
        #else
        inFlight
        #endif
    }

    /// A non-interactive row's padding and frame, per platform.
    @ViewBuilder
    private func contentRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(tvOS)
        content()
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: CinemaRadius.large).fill(CinemaColor.surfaceContainerHigh))
        #else
        iOSSettingsRow {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }

    private func infoRow(icon: String, text: String, tint: Color? = nil) -> some View {
        contentRow {
            HStack(spacing: CinemaSpacing.spacing3) {
                rowIcon(icon, tint: tint ?? themeManager.accent)
                Text(text)
                    .font(rowLabelFont)
                    .foregroundStyle(CinemaColor.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rowIcon(_ name: String, tint: Color) -> some View {
        #if os(tvOS)
        Image(systemName: name)
            .font(.system(size: CinemaScale.pt(20), weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 24)
            .accessibilityHidden(true)
        #else
        iOSRowIcon(systemName: name, color: tint)
            .accessibilityHidden(true)
        #endif
    }

    private func actionRow(
        id: String, icon: String, label: String, tint: Color? = nil, isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            rowChrome(id: id) {
                HStack(spacing: CinemaSpacing.spacing3) {
                    rowIcon(icon, tint: tint ?? themeManager.accent)
                    Text(label)
                        .font(rowLabelFont)
                        .foregroundStyle(tint ?? CinemaColor.onSurface)
                    Spacer(minLength: 0)
                    if isBusy { ProgressView() }
                }
            }
        }
        .buttonStyle(.plain)
        .modifier(RowFocus(id: id, focus: focusBinding))
    }

    /// One Jellyfin user: the row opens their account page (« Peut demander »,
    /// « Validation automatique »), its Seerr state under the name and
    /// « Activé » / « Désactivé » beside it (ONE focusable unit on tvOS).
    private func userRow(_ line: SeerrUserLine) -> some View {
        let id = "seerr.user.\(line.id)"
        let subtitle = SeerrActivationModel.lineText(line.kind, loc: loc)
        let state = loc.localized(line.isEnabled ? "seerr.user.on" : "seerr.user.off")
        return Button {
            #if os(tvOS)
            settingsNav.requestsUserId = line.id
            #else
            openedUser = OpenedSeerrUser(id: line.id)
            #endif
        } label: {
            rowChrome(id: id) {
                HStack(spacing: CinemaSpacing.spacing3) {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                        Text(line.name)
                            .font(rowLabelFont)
                            .foregroundStyle(CinemaColor.onSurface)
                        Text(subtitle)
                            .font(rowDetailFont)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    #if os(tvOS)
                    .padding(.vertical, CinemaSpacing.spacing2)
                    #endif
                    Spacer(minLength: CinemaSpacing.spacing3)
                    if activation.togglingUserIds.contains(line.id) {
                        ProgressView()
                    } else {
                        Text(state)
                            .font(rowDetailFont.weight(.semibold))
                            .foregroundStyle(line.isEnabled ? themeManager.accent : CinemaColor.onSurfaceVariant)
                    }
                    Image(systemName: "chevron.right")
                        .font(rowDetailFont.weight(.semibold))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .modifier(RowFocus(id: id, focus: focusBinding))
        // One VoiceOver element: name, then its state and line.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.name)
        .accessibilityValue("\(state), \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }

    /// The row's padding, background and focus look.
    @ViewBuilder
    private func rowChrome<Content: View>(id: String, @ViewBuilder _ content: () -> Content) -> some View {
        #if os(tvOS)
        content()
            .padding(.horizontal, CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, minHeight: 80)
            .tvSettingsFocusable(isFocused: focusedItem == .toggle(id), accent: themeManager.accent,
                                 animated: motionEffects,
                                 colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        #else
        iOSSettingsRow { content() }
        #endif
    }

    #if os(tvOS)
    private var focusBinding: FocusState<SettingsFocus?>.Binding { $focusedItem }
    #else
    private var focusBinding: Void { () }
    #endif
}

/// The account page open over Réglages → Demandes (a Jellyfin user id).
struct OpenedSeerrUser: Hashable, Identifiable {
    let id: String
}

/// A page of an admin's Réglages → Demandes summary (layout A).
enum RequestsPage: String, Hashable, Identifiable {
    case pending, mine, users, server

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .pending: "seerr.settings.section.pending"
        case .mine: "seerr.settings.section.myRequests"
        case .users: "seerr.hub.users"
        case .server: "seerr.hub.server"
        }
    }

    var icon: String {
        switch self {
        case .pending: "tray.full"
        case .mine: "clock"
        case .users: "person.2"
        case .server: "server.rack"
        }
    }
}

#if os(iOS)
/// A page pushed over the summary. A standalone view (root RULE: a pushed
/// destination built by a method never redraws on an `@Observable` change):
/// the screen's section runs inside THIS body, so its reads of the shared
/// models are tracked here, and a change of the screen's own state redraws
/// the screen, which hands the destination a fresh copy.
private struct RequestsSubpageHost: View {
    let screen: RequestsSettingsScreen
    let page: RequestsPage
    /// Never read: a text-size change must redraw the page (its fonts are
    /// point sizes computed in the body, as on the screen).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        screen.subpage(page)
    }
}
#endif

/// `.refreshable` only where there is something to re-read.
private struct PullToRefresh: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.refreshable { action() }
        } else {
            content
        }
    }
}

/// tvOS: a row is ONE focusable unit in the screen's lane, without the
/// system focus effect (Settings and design-system focus RULEs). iOS: nothing.
struct RowFocus: ViewModifier {
    let id: String
    #if os(tvOS)
    let focus: FocusState<SettingsFocus?>.Binding
    #else
    let focus: Void
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .focusEffectDisabled()
            .hoverEffectDisabled()
            .focused(focus, equals: .toggle(id))
        #else
        content
        #endif
    }
}
