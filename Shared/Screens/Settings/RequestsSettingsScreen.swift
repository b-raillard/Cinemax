import SwiftUI
import CinemaxKit

/// Réglages → Demandes (Seerr, spec 2026-11-06), iOS AND tvOS. Five sections,
/// in this order: **Mes demandes** (an enabled account signed in to Seerr,
/// admin or not), **À valider** (a Seerr user who may manage requests —
/// Seerr's permission, never Jellyfin's admin flag), **Connexion** (everyone
/// who sees the page), then — Jellyfin admin only — **Configuration** (the
/// address, « Tester la connexion » and its report, who may request) and
/// **Sur cet appareil** (the optional API key).
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
struct RequestsSettingsScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(SeerrSession.self) private var seerr
    @Environment(\.motionEffectsEnabled) private var motionEffects

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
    /// A « Réessayer » press is on its way: the failed panel stays, its row
    /// turning, rather than giving way to the spinner (on tvOS the pressed row
    /// would vanish under focus).
    @State private var isRetryingMyRequests = false
    @State private var isRetryingPending = false
    @State private var isTesting = false
    @State private var isSigningIn = false
    @State private var isBulkUpdating = false
    @State private var isLoadingLines = false
    @State private var pendingUserIds: Set<String> = []
    /// The address this device's key was entered for (`nil` = no key). Read
    /// from the Keychain on appear and after each change, never per render.
    @State private var storedKeyOrigin: URL?
    @State private var showsDisableAllConfirm = false
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
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            if isVisible {
                if myRequestsTrigger != nil {
                    myRequestsSection
                }
                if pendingTrigger != nil {
                    pendingSection
                }
                connectionSection
                if appState.isAdministrator {
                    configurationSection
                    deviceSection
                }
            } else {
                noteText(loc.localized("seerr.settings.unavailable"))
            }
        }
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
        .alert(loc.localized("seerr.settings.disableAll"), isPresented: $showsDisableAllConfirm) {
            Button(loc.localized("seerr.settings.disableAll"), role: .destructive) {
                Task { await disableAll() }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("seerr.settings.disableAll.confirm"))
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
                loadingRow
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

    /// One request. tvOS: ONE focusable unit per row, an inert one included —
    /// the remote scrolls by focus, so a row nobody can focus could not be
    /// reached; Select opens an arrived title. iOS: only an arrived title is a
    /// button.
    @ViewBuilder
    private func requestRow(_ row: SeerrRequestRow) -> some View {
        let id = "seerr.request.\(row.id)"
        let canWatch = SeerrMyRequestsModel.watchTarget(row.request) != nil
        #if os(tvOS)
        Button {
            SeerrMyRequestsModel.watch(row.request, appState: appState)
        } label: {
            rowChrome(id: id) { requestRowContent(row, canWatch: canWatch) }
        }
        .buttonStyle(.plain)
        .modifier(RowFocus(id: id, focus: focusBinding))
        .accessibilityElement(children: .combine)
        #else
        if canWatch {
            Button {
                SeerrMyRequestsModel.watch(row.request, appState: appState)
            } label: {
                rowChrome(id: id) { requestRowContent(row, canWatch: true) }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        } else {
            rowChrome(id: id) { requestRowContent(row, canWatch: false) }
                .accessibilityElement(children: .combine)
        }
        #endif
    }

    @ViewBuilder
    private func requestRowContent(_ row: SeerrRequestRow, canWatch: Bool) -> some View {
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
            if canWatch {
                Label(loc.localized("seerr.myRequests.watch"), systemImage: "play.fill")
                    .font(rowDetailFont.weight(.semibold))
                    .foregroundStyle(themeManager.accent)
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
        switch SeerrMyRequestsModel.statusKey(request) {
        case "seerr.myRequests.status.available": CinemaColor.success
        case "seerr.myRequests.status.declined": CinemaColor.error
        default: CinemaColor.onSurfaceVariant
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
                loadingRow
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

    /// One tap, no confirmation (Seerr's own page asks none). While the row's
    /// request is being settled, both its buttons wait: disabled on iOS; on
    /// tvOS still focusable — disabling the focused button would throw focus
    /// off it — the pressed one reading « Approbation en cours… » and the
    /// model ignoring any press.
    @ViewBuilder
    private func pendingButton(_ row: SeerrRequestRow, _ action: SeerrPendingModel.Action) -> some View {
        let inFlight = pending.inFlight[row.id]
        let isApprove = action == .approve
        let label = loc.localized(isApprove ? "seerr.pending.approve" : "seerr.pending.decline")
        let press: () -> Void = {
            #if os(tvOS)
            let formerIndex = pending.rows.firstIndex { $0.id == row.id }
            #endif
            Task {
                if isApprove {
                    await pending.approve(row.id, session: seerr, toasts: toasts, loc: loc)
                } else {
                    await pending.decline(row.id, session: seerr, toasts: toasts, loc: loc)
                }
                #if os(tvOS)
                focusAfterSettling(row.id, action, formerIndex: formerIndex)
                #endif
            }
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
                    Text(isBusy
                         ? loc.localized(isApprove ? "seerr.pending.approving" : "seerr.pending.declining")
                         : label)
                        .font(rowLabelFont)
                        .foregroundStyle(CinemaColor.onSurface)
                }
            }
            .opacity(inFlight != nil && !isBusy ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .modifier(RowFocus(id: id, focus: focusBinding))
        .accessibilityLabel(label)
        #else
        CinemaButton(title: label, style: isApprove ? .accent : .ghost, isLoading: inFlight == action) {
            press()
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(inFlight != nil)
        #endif
    }

    #if os(tvOS)
    private func pendingButtonId(_ requestId: Int, _ action: SeerrPendingModel.Action) -> String {
        "seerr.pending.\(requestId).\(action == .approve ? "approve" : "decline")"
    }

    /// The focused button's row just left the list: focus goes to the same
    /// button of the row that took its place — left to itself, the engine
    /// sends it back to the top of the page, and a manager working down the
    /// queue would walk down again after every press (recette 2026-11-07).
    /// Only while focus is still on the pressed button: a user who moved on
    /// during the call keeps their place.
    private func focusAfterSettling(_ requestId: Int, _ action: SeerrPendingModel.Action, formerIndex: Int?) {
        let rows = pending.rows
        guard focusedItem == .toggle(pendingButtonId(requestId, action)), let formerIndex,
              !rows.contains(where: { $0.id == requestId }) else { return }
        if rows.isEmpty {
            if pending.canLoadMore { focusedItem = .toggle("seerr.pending.more") }
            return
        }
        focusedItem = .toggle(pendingButtonId(rows[min(formerIndex, rows.count - 1)].id, action))
    }
    #endif

    // MARK: - Shared states

    private var loadingRow: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, CinemaSpacing.spacing3)
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
            .disabled(isSigningIn)
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
                .disabled(isTesting || typedAddress == nil)
            }

            // Account mode signs the admin in: say what that leaves behind.
            if !testUsesKey {
                noteText(loc.localized("seerr.settings.test.accountNote"))
            }

            if let report {
                reportView(report)
            }

            if seerr.config?.url != nil {
                usersBlock
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
        let lines = activation.lines
        sectionHeader(loc.localized("seerr.settings.whoCanRequest", activation.enabledCount, lines.count))
            .padding(.top, CinemaSpacing.spacing3)

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
                .disabled(isBulkUpdating)
                divider
                actionRow(id: "seerr.disableAll", icon: "person.3", label: loc.localized("seerr.settings.disableAll"),
                          tint: CinemaColor.error) {
                    showsDisableAllConfirm = true
                }
                .disabled(isBulkUpdating || activation.enabledCount == 0)
            }
        }

        noteText(loc.localized("seerr.settings.footnote"))
    }

    private func lineText(_ kind: SeerrUserLineKind) -> String {
        switch kind {
        case .ageCapped: loc.localized("seerr.settings.line.ageCapped")
        case .linked(let autoApproves):
            loc.localized(autoApproves ? "seerr.settings.line.linkedAutoApprove" : "seerr.settings.line.linked")
        case .willBeCreated: loc.localized("seerr.settings.line.willBeCreated")
        case .mustBeAdded: loc.localized("seerr.settings.line.mustBeAdded")
        case .unknown: loc.localized("seerr.settings.line.unknown")
        }
    }

    // MARK: - Report

    private func reportView(_ report: SeerrTestReport) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            ForEach(report.verified, id: \.self) { line in
                reportLine(icon: "checkmark.circle.fill", tint: CinemaColor.success, title: line, detail: nil)
            }
            if let warning = report.warning {
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
            // Above the field, so the remote's scroll to the last row still shows it.
            noteText(loc.localized("seerr.settings.key.explanation"))

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
                GlassTextField(label: loc.localized("seerr.settings.key"), text: $keyText,
                               placeholder: loc.localized("seerr.settings.key.placeholder"), icon: "key", isSecure: true)
                panel {
                    actionRow(id: "seerr.key.save", icon: "square.and.arrow.down", label: loc.localized("seerr.settings.key.save")) {
                        Task { await saveKey() }
                    }
                    .disabled(typedKey.isEmpty)
                }
            }
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
        await activation.load(appState: appState, session: seerr)
        // A cancelled load is replaced by the next trigger's: leave it its state.
        guard !Task.isCancelled else { return }
        isLoadingLines = false
        loadedTrigger = current
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

    private func showFailure(_ failure: SeerrTestFailure) {
        toasts.error(failureTitle(failure), message: loc.localized(failure.fixKey))
    }

    private func toggle(_ line: SeerrUserLine) async {
        guard !pendingUserIds.contains(line.id) else { return }
        pendingUserIds.insert(line.id)
        defer { pendingUserIds.remove(line.id) }
        let turningOn = !line.isEnabled
        if let message = await activation.setEnabled(turningOn, userId: line.id, appState: appState, loc: loc) {
            // A refusal (age cap, no address yet) informs; a failed write is an error.
            if turningOn, line.kind == .ageCapped || seerr.config?.url == nil {
                toasts.info(message)
            } else {
                toasts.error(message)
            }
            return
        }
        // The admin's own switch changes the admin's own configuration (R22).
        if line.id == appState.currentUserId { await seerr.reload(appState: appState) }
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

    private var rowLabelFont: Font {
        #if os(tvOS)
        .system(size: CinemaScale.pt(20), weight: .medium)
        #else
        CinemaFont.dynamicLabel(.large)
        #endif
    }

    private var rowDetailFont: Font {
        #if os(tvOS)
        .system(size: CinemaScale.pt(16), weight: .regular)
        #else
        CinemaFont.dynamicLabel(.medium)
        #endif
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        #if os(tvOS)
        Text(title.uppercased())
            .font(.system(size: CinemaScale.pt(17), weight: .bold))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.5)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
        #else
        iOSSettingsSectionHeader(title)
        #endif
    }

    /// iOS: one glass panel, rows split by dividers. tvOS: separate focusable
    /// rows, each with its own opaque background (`tvSettingsFocusable`).
    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) { content() }
        #else
        VStack(spacing: 0) { content() }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        #endif
    }

    @ViewBuilder
    private var divider: some View {
        #if os(iOS)
        iOSSettingsDivider
        #endif
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(rowDetailFont)
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CinemaSpacing.spacing2)
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

    /// One Jellyfin user: the whole row is the switch, its Seerr state under
    /// the name (ONE focusable unit on tvOS).
    private func userRow(_ line: SeerrUserLine) -> some View {
        let id = "seerr.user.\(line.id)"
        let subtitle = lineText(line.kind)
        let action: () -> Void = { Task { await toggle(line) } }
        return Button(action: action) {
            rowChrome(id: id) {
                toggleRowContent(label: line.name, subtitle: subtitle, isOn: line.isEnabled,
                                 isBusy: pendingUserIds.contains(line.id))
            }
        }
        .buttonStyle(.plain)
        .modifier(RowFocus(id: id, focus: focusBinding))
        // One VoiceOver element: name, state line, on / off, toggle semantics.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.name)
        .accessibilityValue(loc.localized(line.isEnabled ? "a11y.toggle.on" : "a11y.toggle.off"))
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { action() }
    }

    @ViewBuilder
    private func toggleRowContent(label: String, subtitle: String, isOn: Bool, isBusy: Bool) -> some View {
        let text = VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
            Text(label)
                .font(rowLabelFont)
                .foregroundStyle(CinemaColor.onSurface)
            Text(subtitle)
                .font(rowDetailFont)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        let control = Group {
            if isBusy {
                ProgressView()
            } else {
                CinemaToggleIndicator(isOn: isOn, accent: themeManager.accent, animated: motionEffects)
            }
        }
        #if os(tvOS)
        HStack(spacing: CinemaSpacing.spacing3) {
            text.padding(.vertical, CinemaSpacing.spacing2)
            Spacer(minLength: CinemaSpacing.spacing3)
            control
        }
        #else
        SettingsRowAdaptiveLayout {
            text
        } control: {
            control
        }
        #endif
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

/// tvOS: a row is ONE focusable unit in the screen's lane, without the
/// system focus effect (Settings and design-system focus RULEs). iOS: nothing.
private struct RowFocus: ViewModifier {
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
