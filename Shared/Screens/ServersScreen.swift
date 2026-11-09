import SwiftUI
import CinemaxKit

private extension View {
    /// The switch / delete confirmations. iOS: an alert — iOS 27 draws a
    /// `confirmationDialog` as a popover with no « Annuler » (recette
    /// 2026-10-26, SRV-DLG-01; the account switcher's Q-ANNULER decision).
    /// tvOS keeps the confirmation dialog: a SwiftUI `.alert` has focus bugs
    /// there (`docs/design-system/patterns.md`).
    @ViewBuilder
    func serverConfirmation<T, A: View, M: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A,
        @ViewBuilder message: @escaping (T) -> M
    ) -> some View {
        #if os(iOS)
        alert(title, isPresented: isPresented, presenting: data, actions: actions, message: message)
        #else
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible,
                           presenting: data, actions: actions, message: message)
        #endif
    }
}

// MARK: - View Model

/// Reachability state for the servers list. Lives outside the view so the
/// probe fan-out survives body re-evaluations and so the "already probed"
/// guard is real state rather than a view-local flag.
@MainActor @Observable
final class ServersViewModel {

    enum PingStatus: Sendable, Equatable {
        case pinging
        case online
        case offline
    }

    private(set) var statuses: [String: PingStatus] = [:]
    /// Which road answered each online entry: its LAN address or its public one.
    private(set) var routes: [String: ServerRouteKind] = [:]

    /// Attempt flag. The tvOS Settings surface re-presents (and re-fires its
    /// `.task`) on **every** `MenuConfigStore` mutation, so an unguarded probe
    /// would re-ping the whole fleet on each menu interaction — same precedent
    /// as `SettingsScreen.serverUsersLoadAttempted`.
    private var hasPinged = false

    func status(for id: String) -> PingStatus? { statuses[id] }

    /// The road the last probe of this entry answered on; nil while unknown or
    /// offline.
    func route(for id: String) -> ServerRouteKind? { routes[id] }

    /// Drops a removed entry's status so a re-added server starts from a clean
    /// "probing" state instead of inheriting a stale dot.
    func forget(id: String) {
        statuses[id] = nil
        routes[id] = nil
    }

    /// Probes one entry again — after its local address was saved or removed,
    /// so its card's « Local » / « Internet » follows without reopening.
    func refresh(id: String, using appState: AppState) async {
        guard let entry = appState.servers.first(where: { $0.id == id }) else { return }
        let reach = ServerRouteController.shared.currentReach
        apply(await Self.probe(entry, reach: reach), using: appState)
    }

    func pingIfNeeded(using appState: AppState) async {
        guard !hasPinged else { return }
        hasPinged = true
        await ping(using: appState)
    }

    /// Fans every registered server out to the **unauthenticated** public probe
    /// (`ServerReachability` — see the RULE in its header: no auth header, own
    /// `URLSession`, so it can never feed the shared 401 machinery and a dead
    /// secondary server can't sign the user out of the active one).
    ///
    /// Results are applied as they land, so a slow server never holds up the
    /// others and never blocks first paint; a discovered name / version
    /// self-heals the stored entry through `AppState.updateServerMetadata`.
    func ping(using appState: AppState) async {
        let entries = appState.servers
        guard !entries.isEmpty else { return }
        for entry in entries where statuses[entry.id] == nil {
            statuses[entry.id] = .pinging
        }

        let reach = ServerRouteController.shared.currentReach
        await withTaskGroup(of: Probe.self) { group in
            for entry in entries {
                group.addTask { await Self.probe(entry, reach: reach) }
            }
            for await probe in group {
                guard !Task.isCancelled else { break }
                apply(probe, using: appState)
            }
        }

        // A cancelled sweep (screen dismissed mid-probe) must not latch the
        // guard: the next presentation would otherwise render whatever partial
        // or cancellation-derived state it left behind (a dot stuck on
        // "probing", or a spurious "offline").
        if Task.isCancelled { hasPinged = false }
    }

    private func apply(_ probe: Probe, using appState: AppState) {
        switch probe.result {
        case .online(let name, let version, let serverID):
            statuses[probe.id] = .online
            routes[probe.id] = probe.answeredLocally ? .local : .internet
            appState.updateServerMetadata(id: probe.id, name: name, version: version, serverID: serverID)
        case .offline:
            // The LAN address proved the same server even with the public one down.
            statuses[probe.id] = probe.answeredLocally ? .online : .offline
            routes[probe.id] = probe.answeredLocally ? .local : nil
        }
    }

    /// The LAN address (decided as the route owner decides: https, a local
    /// peer answering with the entry's own `Id`) and the public ping, run side
    /// by side so a user away from home never waits for the LAN timeout. The
    /// card is online when either answers; the local answer names the road.
    /// Nothing here is logged: no address may reach a log line.
    nonisolated private static func probe(_ entry: ServerEntry, reach: NetworkReach) async -> Probe {
        async let publicResult = ServerReachability.ping(url: entry.url)
        async let localDial = localDial(for: entry, reach: reach)
        let result = await publicResult
        let answeredLocally = await localDial != nil
        return Probe(id: entry.id, result: result, answeredLocally: answeredLocally)
    }

    nonisolated private static func localDial(for entry: ServerEntry, reach: NetworkReach) async -> URL? {
        guard ServerRoutePolicy.shouldProbe(localURL: entry.localURL, reach: reach), let local = entry.localURL,
              let expected = entry.serverID, !expected.isEmpty else { return nil }
        let outcome = await LocalRouteProbe.probe(local, timeout: LocalRouteProbe.runtimeTimeout)
        return ServerRoutePolicy.decide(localURL: local, reach: reach, expectedServerID: expected, probe: outcome)
    }

    private struct Probe: Sendable {
        let id: String
        let result: PingResult
        let answeredLocally: Bool
    }
}

// MARK: - Local address feedback

/// What saving a local address says, as a toast. Pure, so the mapping is tested.
enum LocalAddressToast {
    /// `nil` for `.needsCertificateApproval`: the screen asks for the
    /// certificate's approval instead of toasting.
    static func message(for outcome: LocalAddressSaveOutcome) -> (key: String, level: Toast.Level)? {
        switch outcome {
        case .removed:                 ("servers.localAddress.removed", .info)
        case .reachable:               ("servers.localAddress.reachable", .success)
        case .savedUnreachable:        ("servers.localAddress.savedUnreachable", .info)
        case .savedLocalNetworkDenied: ("servers.localAddress.denied", .error)
        case .refusedNotLocal:         ("servers.localAddress.notLocal", .error)
        case .refusedOtherServer:      ("servers.localAddress.otherServer", .error)
        case .needsSignIn:             ("servers.localAddress.signInFirst", .error)
        case .refusedNotHTTPS:         ("servers.localAddress.notHTTPS", .error)
        case .savedNeedsApproval:      ("servers.localAddress.savedNeedsApproval", .info)
        case .needsCertificateApproval: nil
        }
    }
}

/// A LAN certificate waiting for the user's approval: the entry id (re-resolved
/// at action time, like every pending action here), the text typed, and the
/// summary SHOWN — its exact fingerprint is what gets pinned (R15).
struct LocalCertificateApproval: Identifiable {
    let entryId: String
    let raw: String
    let summary: ServerCertificateSummary
    /// The host already carried a pin: the certificate CHANGED since.
    let isRotation: Bool
    var id: String { summary.fingerprint }
}

/// The route line under the active server's address in Réglages → Serveur:
/// « Local · 192.168.1.128:8920 » or « Internet ». Reads the route owner
/// directly (no environment injection) — a standalone `View`, so it redraws
/// on a route change even inside a pushed destination.
struct ServerRouteLine: View {
    @Environment(LocalizationManager.self) private var loc
    let font: Font

    var body: some View {
        let route = ServerRouteController.shared
        let local = route.route == .local ? route.dialURL.flatMap(Self.hostAndPort) : nil
        // One line; else « Local » over the address; « Local » alone only as
        // the last resort — never a cut address (memory
        // `feedback_short_label_over_truncation`).
        ViewThatFits(in: .horizontal) {
            if let local {
                line(loc.localized("settings.server.route.local", local), icon: "house.fill")
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) {
                    line(loc.localized("servers.route.local"), icon: "house.fill")
                    Text(local).lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                line(loc.localized("servers.route.local"), icon: "house.fill")
            } else {
                line(loc.localized("servers.route.internet"), icon: "globe")
            }
        }
        .font(font)
        .foregroundStyle(CinemaColor.onSurfaceMuted)
    }

    /// Icon and text side by side at a set gap — a `Label` spreads them far
    /// apart on tvOS.
    private func line(_ text: String, icon: String) -> some View {
        HStack(spacing: CinemaSpacing.spacing1) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
    }

    /// `host[:port]`, an IPv6 literal in brackets.
    static func hostAndPort(_ url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        let shown = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(shown):\($0)" } ?? shown
    }
}

// MARK: - Servers Screen

/// The registered-servers list (Settings → Account → Servers, and — when the
/// user is signed out with more than one entry — from `LoginScreen`).
///
/// Presented as a `.sheet` on iOS and a `.fullScreenCover` on tvOS, the same
/// platform-branched chrome as `PrivacySecurityScreen` / `WatchedHistoryScreen`:
/// iOS `NavigationStack` + toolbar Done, tvOS a custom header with an accent
/// Done button inside a `.focusSection()` (that always-present button is what
/// guarantees a focusable in the loading / empty states).
///
/// **RULE — every "is this the server we're on?" test keys on
/// `appState.activeServerId`, never `appState.currentActiveEntry`.** The latter
/// falls back to the most-recently-used entry when the active id is nil or
/// stale, which resolves to a server the app is NOT actually on while signed
/// out — exactly the state this screen is reachable in from `LoginScreen`. The
/// active wash, the "current" pill and the delete suppression would all point
/// at the wrong card.
///
/// **RULE — pending actions hold an entry `id`, never a captured entry.** The
/// row's snapshot goes stale the moment a reachability probe writes back a
/// discovered name / version, and `ServerRegistry.upsert` *replaces* rather than
/// merges — handing `AppState` a stale snapshot would silently regress the
/// entry's metadata. Every action re-resolves from `appState.servers` by id.
///
/// **RULE — nothing here may read authenticated state** (`currentUserId`,
/// `imageBuilder`, the API client): the screen also renders with
/// `isAuthenticated == false`. That is also why the per-entry avatar is drawn
/// locally from the stored username instead of `UserAvatar` — `imageBuilder`
/// points at the *active* server, so a non-active entry's avatar URL would 404
/// or leak a cross-server request.
///
/// **iOS uses a native `List`** — a deliberate exception to the app's
/// "hand-rolled rows" idiom, mandated by the swipe-to-delete requirement
/// (`.swipeActions` only exists on `List`) and by reordering (`.onMove` and its
/// ≡ handle exist nowhere else). The glass card look is preserved via
/// `.listStyle(.plain)` + cleared row backgrounds / separators. Same kind of
/// explicit exception as `MenuSettingsScreen+iOS`'s native `List` + `Picker`.
///
/// **Rename and reorder are local and user-owned** (`ServerEntry.displayNameOverride`
/// / `sortIndex`): every row prints `displayName`, and the two fields survive
/// the probe's metadata write-back and every `upsert` — see the RULE on
/// `ServerRegistry.upsert`. Reorder follows `PlaylistDetailScreen`'s idiom:
/// iOS drags in an explicit « Ordonner » edit mode (never forced on — every row
/// is a switch target, and an always-editing `List` would swallow the tap),
/// tvOS carries « Monter » / « Descendre » in each card's context menu.
struct ServersScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    #if os(tvOS)
    @Environment(\.motionEffectsEnabled) private var motionEffects
    private enum FocusTarget: Hashable {
        case server(String)
        case add
    }
    @FocusState private var focusedItem: FocusTarget?
    #endif

    @State private var viewModel = ServersViewModel()
    /// Ids, not entries — see the freshness RULE above.
    @State private var pendingSwitchId: String?
    @State private var pendingDeleteId: String?
    @State private var switchingId: String?
    /// Id of the entry being renamed (same freshness RULE as the two above).
    @State private var pendingRenameId: String?
    /// A switch refused with `.locked`: the server whose account needs a code.
    @State private var lockedSwitch: ServerEntry?
    @State private var renameText = ""
    /// Id of the entry whose local address is being edited (same freshness RULE).
    @State private var pendingLocalAddressId: String?
    @State private var localAddressText = ""
    /// The LAN certificate the last save asked to approve.
    @State private var pendingApproval: LocalCertificateApproval?
    #if !os(tvOS)
    @State private var editMode: EditMode = .inactive
    #endif

    /// The user's manual order when there is one, else active first then
    /// most-recently-used (total order — the list never reshuffles between
    /// renders). See `ServerRegistry.sorted`.
    private var entries: [ServerEntry] {
        ServerRegistry.sorted(appState.servers, activeId: appState.activeServerId)
    }

    private func isActive(_ entry: ServerEntry) -> Bool {
        entry.id == appState.activeServerId
    }

    private func name(for id: String) -> String {
        appState.servers.first(where: { $0.id == id })?.displayName ?? ServerEntry.fallbackName
    }

    /// The name the SERVER reports — what an empty rename falls back to.
    private func serverOwnName(for id: String) -> String {
        appState.servers.first(where: { $0.id == id })?.name ?? ServerEntry.fallbackName
    }

    var body: some View {
        localAddressPresentations(screen)
    }

    private var screen: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSChrome
            #else
            iOSChrome
            #endif
        }
        .task { await viewModel.pingIfNeeded(using: appState) }
        #if os(tvOS)
        .fullScreenCover(item: $lockedSwitch) { entry in unlockSheet(for: entry) }
        #else
        .sheet(item: $lockedSwitch) { entry in unlockSheet(for: entry) }
        #endif
        .serverConfirmation(
            loc.localized("servers.switch.action"),
            isPresented: Binding(
                get: { pendingSwitchId != nil },
                set: { if !$0 { pendingSwitchId = nil } }
            ),
            presenting: pendingSwitchId
        ) { id in
            Button(loc.localized("servers.switch.action")) {
                Task { await performSwitch(id: id) }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: { id in
            Text(loc.localized("servers.switch.confirm", name(for: id)))
        }
        .serverConfirmation(
            loc.localized("servers.delete"),
            isPresented: Binding(
                get: { pendingDeleteId != nil },
                set: { if !$0 { pendingDeleteId = nil } }
            ),
            presenting: pendingDeleteId
        ) { id in
            Button(loc.localized("servers.delete"), role: .destructive) {
                Task { await performDelete(id: id) }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: { id in
            Text(loc.localized("servers.delete.confirm", name(for: id)))
        }
        .alert(
            loc.localized("servers.rename.title"),
            isPresented: Binding(
                get: { pendingRenameId != nil },
                set: { if !$0 { pendingRenameId = nil } }
            ),
            presenting: pendingRenameId
        ) { id in
            // The placeholder is the server's own name — exactly what an empty
            // field falls back to.
            TextField(serverOwnName(for: id), text: $renameText)
            Button(loc.localized("action.save")) { commitRename(id: id) }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: { id in
            Text(loc.localized("servers.rename.message", serverOwnName(for: id)))
        }
    }

    /// The local-address entry alert and the LAN certificate approval, kept
    /// out of `screen`'s chain. The entry is an `.alert` with a `TextField` on
    /// both platforms (tvOS: the system text entry, as the rename alert). The
    /// approval is `serverConfirmation`: an alert on iOS, a confirmation
    /// dialog on tvOS (a SwiftUI alert has focus bugs there), whose first
    /// button « Faire confiance à ce certificat » takes the focus.
    @ViewBuilder
    private func localAddressPresentations(_ content: some View) -> some View {
        content
            .alert(
                loc.localized("servers.localAddress.title"),
                isPresented: Binding(
                    get: { pendingLocalAddressId != nil },
                    set: { if !$0 { pendingLocalAddressId = nil } }
                ),
                presenting: pendingLocalAddressId
            ) { id in
                TextField(loc.localized("servers.localAddress.placeholder"), text: $localAddressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                Button(loc.localized("action.save")) { commitLocalAddress(id: id) }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: { _ in
                Text(loc.localized("servers.localAddress.message"))
            }
            .serverConfirmation(
                loc.localized("server.certificate.title"),
                isPresented: Binding(
                    get: { pendingApproval != nil },
                    set: { if !$0 { pendingApproval = nil } }
                ),
                presenting: pendingApproval
            ) { approval in
                Button(loc.localized("server.certificate.trust")) { trust(approval) }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: { approval in
                Text(approvalMessage(approval))
            }
    }

    // MARK: - Actions

    /// Connectivity is deliberately read INSIDE `switchTo` (on confirm), not
    /// before the dialog: the card never renders disabled, and the offline
    /// answer reflects the moment the user actually acted.
    private func performSwitch(id: String) async {
        guard let entry = appState.servers.first(where: { $0.id == id }) else { return }
        switchingId = id
        defer { switchingId = nil }

        switch await appState.switchTo(entry) {
        case .commit:
            toasts.success(loc.localized("servers.switchedTo", entry.displayName))
            dismiss()
        case .offline:
            toasts.error(loc.localized("servers.offline"))
        case .unreachable:
            toasts.error(loc.localized("servers.unreachable"))
        case .locked:
            // Its account carries a code (or would lift the age cap while the
            // parental code is set): ask it, then switch — see `unlockSheet`.
            lockedSwitch = entry
        case .needsLogin:
            // The root already swapped to `LoginScreen` scoped to that server.
            // Dismiss so this modal doesn't sit on top of it (it survives when
            // the host is `LoginScreen` itself, which stays mounted).
            dismiss()
        }
    }

    private func unlockSheet(for entry: ServerEntry) -> some View {
        AccountUnlockSheet(
            accountKey: ServerRegistry.accountKey(serverId: entry.id, userId: entry.userId ?? ""),
            name: entry.username ?? entry.displayName
        ) {
            Task {
                switch await appState.switchTo(entry, unlocked: true) {
                case .commit:
                    toasts.success(loc.localized("servers.switchedTo", entry.displayName))
                    dismiss()
                case .offline:
                    toasts.error(loc.localized("servers.offline"))
                case .unreachable:
                    toasts.error(loc.localized("servers.unreachable"))
                case .needsLogin, .locked:
                    dismiss()
                }
            }
        }
        .environment(themeManager)
        .environment(loc)
    }

    private func performDelete(id: String) async {
        guard let entry = appState.servers.first(where: { $0.id == id }),
              entry.id != appState.activeServerId else { return }
        await appState.removeServer(entry)
        viewModel.forget(id: id)
        toasts.success(loc.localized("servers.deleted", entry.displayName))
    }

    /// Opens the rename alert pre-filled with the name currently shown.
    private func beginRename(id: String) {
        renameText = appState.servers.first(where: { $0.id == id })?.displayName ?? ""
        pendingRenameId = id
    }

    /// Toasts only on a real change — saving the field untouched says nothing.
    private func commitRename(id: String) {
        let before = appState.servers.first(where: { $0.id == id })?.displayNameOverride
        guard let updated = appState.renameServer(id: id, to: renameText),
              updated.displayNameOverride != before else { return }
        if updated.displayNameOverride == nil {
            toasts.success(loc.localized("servers.renameReset", updated.name))
        } else {
            toasts.success(loc.localized("servers.renamed", updated.displayName))
        }
    }

    /// Opens the local-address alert pre-filled with the stored address.
    private func beginLocalAddress(id: String) {
        localAddressText = appState.servers.first(where: { $0.id == id })?.localURL?.absoluteString ?? ""
        pendingLocalAddressId = id
    }

    private func commitLocalAddress(id: String) {
        let raw = localAddressText
        Task { await handleLocalAddress(await appState.setLocalAddress(id: id, raw: raw), id: id, raw: raw) }
    }

    /// Pins exactly the fingerprint the user was shown (R15): `AppState` pins
    /// it only while the pending certificate still carries it, and otherwise
    /// answers `.needsCertificateApproval` again with the new one.
    private func trust(_ approval: LocalCertificateApproval) {
        Task {
            let outcome = await appState.trustLocalCertificate(
                id: approval.entryId, raw: approval.raw, fingerprint: approval.summary.fingerprint
            )
            await handleLocalAddress(outcome, id: approval.entryId, raw: approval.raw)
        }
    }

    /// Every save's outcome lands here: a toast, or the certificate approval.
    private func handleLocalAddress(_ outcome: LocalAddressSaveOutcome, id: String, raw: String) async {
        if outcome == .needsCertificateApproval {
            guard appState.servers.contains(where: { $0.id == id }),
                  let summary = appState.pendingLocalCertificate(raw: raw) else {
                // The pending certificate is gone (the entry was removed, or
                // another probe replaced it): nothing to show, nothing saved.
                toasts.error(loc.localized("server.connectFailed"))
                return
            }
            pendingApproval = LocalCertificateApproval(
                entryId: id,
                raw: raw,
                summary: summary,
                isRotation: ServerTrustDelegate.shared.isPinned(trustKey: summary.trustKey)
            )
            return
        }
        if let message = LocalAddressToast.message(for: outcome) {
            let text = loc.localized(message.key)
            switch message.level {
            case .success: toasts.success(text)
            case .error:   toasts.error(text)
            case .info:    toasts.info(text)
            }
        }
        // The card's « Local » / « Internet » follows the new address (the
        // active one through the route owner, which the save re-evaluates).
        await viewModel.refresh(id: id, using: appState)
    }

    /// What the approval shows, in the server-setup panel's order: why, what
    /// to check, then the host, the subject and the SHA-256 fingerprint in its
    /// grouped form — the thing that gets pinned.
    private func approvalMessage(_ approval: LocalCertificateApproval) -> String {
        let summary = approval.summary
        var lines = [
            loc.localized(approval.isRotation ? "server.certificate.changed" : "server.certificate.untrusted"),
            loc.localized("server.certificate.explain"),
            "",
            loc.localized("server.certificate.host").uppercased(),
            summary.host
        ]
        if let subject = summary.subject, !subject.isEmpty {
            lines += ["", loc.localized("server.certificate.subject").uppercased(), subject]
        }
        lines += ["", loc.localized("server.certificate.fingerprint").uppercased(), summary.formattedFingerprint]
        return lines.joined(separator: "\n")
    }

    /// Moves one card a step up (`-1`) or down (`+1`) — tvOS's « Monter » /
    /// « Descendre ». Always writes the COMPLETE displayed order, the only
    /// shape `ServerRegistry.applyingOrder` accepts.
    private func move(id: String, by offset: Int) {
        var ids = entries.map(\.id)
        guard let from = ids.firstIndex(of: id), ids.indices.contains(from + offset) else { return }
        ids.swapAt(from, from + offset)
        appState.reorderServers(orderedIds: ids)
    }

    /// Hands the pre-auth flow over to "add" mode — the root swaps to
    /// `ServerSetupScreen`, which renders a cancel affordance while
    /// `isAddingServer` is set.
    private func addServer() {
        appState.beginAddServer()
        dismiss()
    }

    // MARK: - Shared Row Content

    @ViewBuilder
    private func rowContent(_ entry: ServerEntry) -> some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            initialBadge(for: entry)

            VStack(alignment: .leading, spacing: 4) {
                titleLine(entry)

                Text(displayAddress(entry))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detailLine(entry))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.8))
                    .lineLimit(1)
            }
            // The column takes every point up to the status dot — no Spacer
            // between them: its minimum length plus a second HStack gap
            // left ~27 pt empty, enough to push « Local » down to its icon.
            .frame(maxWidth: .infinity, alignment: .leading)

            if switchingId == entry.id {
                ProgressView()
                    .tint(themeManager.accent)
            } else {
                statusDot(entry)
            }
        }
    }

    /// Locally drawn identity badge — never `UserAvatar` (see the RULE in the
    /// type header: `imageBuilder` points at the active server).
    private func initialBadge(for entry: ServerEntry) -> some View {
        let source = entry.username?.isEmpty == false ? entry.username! : entry.displayName
        return ZStack {
            Circle()
                .fill(themeManager.accentContainer)
                .frame(width: badgeSize, height: badgeSize)

            Text(String(source.prefix(1)).uppercased())
                .font(CinemaFont.label(.large))
                .foregroundStyle(themeManager.onAccentContainer)
        }
        .accessibilityHidden(true)
    }

    /// The name, then « Actuel », then the road (« Local » / « Internet »).
    /// The pills never truncate the name: when the line runs out the road
    /// pill shrinks to its icon first, and only a name too long for the card
    /// on its own is cut (memory `feedback_short_label_over_truncation`).
    private func titleLine(_ entry: ServerEntry) -> some View {
        let route = displayedRoute(entry)
        return ViewThatFits(in: .horizontal) {
            titleRow(entry, route: route, compactRoute: false, nameFits: true)
            titleRow(entry, route: route, compactRoute: true, nameFits: true)
            titleRow(entry, route: route, compactRoute: true, nameFits: false)
        }
    }

    private func titleRow(
        _ entry: ServerEntry, route: ServerRouteKind?, compactRoute: Bool, nameFits: Bool
    ) -> some View {
        // `spacing1`, as the mockup's tight gap: at `spacing2` « Nivadax ·
        // Actuel · 🏠 Local » missed the iPhone 17 Pro card by a few points.
        HStack(spacing: CinemaSpacing.spacing1) {
            Text(entry.displayName)
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurface)
                .lineLimit(1)
                .fixedSize(horizontal: nameFits, vertical: false)
                .layoutPriority(1)

            if isActive(entry) { currentPill.fixedSize() }
            if let route { routePill(route, compact: compactRoute).fixedSize() }
        }
    }

    /// The road this card's server answers on, shown only once the card's
    /// own probe found it online (never « Internet » beside a red dot). The
    /// server we are on reads the route owner — what is actually dialled; it
    /// reads `.internet` while signed out (reset at logout, `sessionEnded`).
    /// Every other card reads its own probe.
    private func displayedRoute(_ entry: ServerEntry) -> ServerRouteKind? {
        guard viewModel.status(for: entry.id) == .online else { return nil }
        if isActive(entry) { return ServerRouteController.shared.route }
        return viewModel.route(for: entry.id)
    }

    /// « Local » (`house.fill`) / « Internet » (`globe`), or the icon alone as
    /// the short form — which keeps the word for VoiceOver.
    private func routePill(_ route: ServerRouteKind, compact: Bool) -> some View {
        let label = loc.localized(route == .local ? "servers.route.local" : "servers.route.internet")
        return HStack(spacing: CinemaSpacing.spacing1) {
            Image(systemName: route == .local ? "house.fill" : "globe")
            if !compact { Text(label) }
        }
        .font(CinemaFont.label(.small))
        .foregroundStyle(CinemaColor.onSurfaceVariant)
        .padding(.horizontal, CinemaSpacing.spacing2)
        .padding(.vertical, 3)
        .background(Capsule().fill(routePillFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// iOS: `surfaceContainerHigh` over the glass card. tvOS: one step up —
    /// the tvOS card itself is `surfaceContainerHigh` (`tvSettingsFocusable`),
    /// where the same fill would vanish.
    private var routePillFill: Color {
        #if os(tvOS)
        CinemaColor.surfaceContainerHighest
        #else
        CinemaColor.surfaceContainerHigh
        #endif
    }

    private var currentPill: some View {
        Text(loc.localized("servers.current"))
            .font(CinemaFont.label(.small))
            .foregroundStyle(themeManager.onAccentContainer)
            .padding(.horizontal, CinemaSpacing.spacing2)
            .padding(.vertical, 3)
            .background(Capsule().fill(themeManager.accentContainer))
    }

    @ViewBuilder
    private func statusDot(_ entry: ServerEntry) -> some View {
        let status = viewModel.status(for: entry.id)
        Circle()
            .fill(statusColor(status))
            .frame(width: dotSize, height: dotSize)
            // Three states, not two: while the probe is in flight (or was never
            // run) the answer is unknown, and announcing "Offline" there made
            // every row lie to VoiceOver on first paint.
            .accessibilityLabel(statusLabel(status))
    }

    private func statusLabel(_ status: ServersViewModel.PingStatus?) -> String {
        switch status {
        case .online:  loc.localized("servers.online")
        case .offline: loc.localized("servers.offlineBadge")
        default:       loc.localized("servers.checking")
        }
    }

    private func statusColor(_ status: ServersViewModel.PingStatus?) -> Color {
        switch status {
        case .online:  CinemaColor.success
        case .offline: CinemaColor.error
        default:       CinemaColor.onSurfaceVariant.opacity(0.5)
        }
    }

    /// First line under the name: enough of the URL to tell two entries apart.
    ///
    /// The bare `host` is NOT enough — the registry keys on the full URL, so
    /// `http://nas:8096` / `http://nas:8920` and `https://box/jellyfin` /
    /// `https://box/media` are legitimately distinct entries that all rendered
    /// as the same string. Port and path are appended only when present, so the
    /// common `https://host` case still reads as a plain hostname (the scheme
    /// stays off — it's noise on the row, and the status dot carries liveness).
    private func displayAddress(_ entry: ServerEntry) -> String {
        guard let host = entry.url.host, !host.isEmpty else { return entry.url.absoluteString }
        var address = host
        if let port = entry.url.port { address += ":\(port)" }
        // Drop a trailing "/" so a base-path-less URL doesn't render as "host/".
        let path = entry.url.path
        if !path.isEmpty, path != "/" {
            address += path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return address
    }

    /// Second line: who we're signed in as + the server version, or the
    /// signed-out marker for a tokenless (kept) entry.
    private func detailLine(_ entry: ServerEntry) -> String {
        guard entry.hasSession else { return loc.localized("servers.signedOut") }
        var parts: [String] = []
        if let username = entry.username, !username.isEmpty { parts.append(username) }
        if let version = entry.serverVersion, !version.isEmpty { parts.append(version) }
        return parts.isEmpty ? loc.localized("servers.online") : parts.joined(separator: " · ")
    }

    /// Accent wash marking the server the app is actually on. Deliberately a
    /// tonal shift rather than a stroke — the design system's border exception
    /// list is closed (see `docs/design-system/conventions.md`).
    ///
    /// Applied as a `.background` UNDER the row content and ABOVE the card's
    /// own surface (`.glassPanel` / `tvSettingsFocusable`, both of which are
    /// applied after it). As an `.overlay` it tinted the text itself, costing
    /// contrast, and it stacked on top of the tvOS focus treatment.
    @ViewBuilder
    private func activeWash(_ entry: ServerEntry) -> some View {
        if isActive(entry) {
            RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                .fill(themeManager.accent.opacity(0.12))
                .allowsHitTesting(false)
        }
    }

    private var badgeSize: CGFloat {
        #if os(tvOS)
        56
        #else
        40
        #endif
    }

    private var dotSize: CGFloat {
        #if os(tvOS)
        14
        #else
        10
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        EmptyStateView(
            systemImage: "server.rack",
            title: loc.localized("servers.empty.title"),
            subtitle: loc.localized("servers.empty.subtitle")
        )
    }

    // MARK: - iOS Chrome

    #if !os(tvOS)
    private var iOSChrome: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                if entries.isEmpty {
                    emptyState
                    Spacer()
                } else {
                    serverList
                }

                CinemaButton(
                    title: loc.localized("servers.add"),
                    style: .accent,
                    icon: "plus"
                ) {
                    addServer()
                }
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.top, CinemaSpacing.spacing2)
                .padding(.bottom, CinemaSpacing.spacing4)
            }
        }
        .navigationTitle(loc.localized("servers.title"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            // Hidden while reordering, so the bar never carries two
            // « Terminé » with different meanings (dismiss vs. end editing).
            if !editMode.isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.done")) { dismiss() }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            if entries.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    // NOT the system `EditButton`: it takes its title from the
                    // DEVICE language, not the app's own (see PlaylistDetailScreen).
                    Button {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    } label: {
                        Text(loc.localized(editMode.isEditing ? "action.done" : "servers.reorder"))
                    }
                    .tint(themeManager.accent)
                }
            }
        }
    }

    private var serverList: some View {
        List {
            ForEach(entries, id: \.id) { entry in
                iOSRow(entry)
            }
            .onMove(perform: moveHandler)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    /// Only while « Ordonner » is on: outside edit mode a long press is the
    /// row's context menu (rename), not a drag. Spelled as a typed optional —
    /// an inline `isEditing ? moveRows : nil` defeats the type checker.
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard editMode.isEditing else { return nil }
        return { offsets, destination in moveRows(from: offsets, to: destination) }
    }

    /// `.onMove` hands an insertion point in the pre-move list; `Array.move`
    /// speaks the same convention, so no `PlaylistReorder`-style correction is
    /// needed — the result is the complete new order.
    private func moveRows(from offsets: IndexSet, to destination: Int) {
        var ids = entries.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        appState.reorderServers(orderedIds: ids)
    }

    private func renameAction(_ entry: ServerEntry) -> some View {
        Button {
            beginRename(id: entry.id)
        } label: {
            Label(loc.localized("servers.rename"), systemImage: "pencil")
        }
    }

    private func localAddressAction(_ entry: ServerEntry) -> some View {
        Button {
            beginLocalAddress(id: entry.id)
        } label: {
            Label(loc.localized("servers.localAddress"), systemImage: "house")
        }
    }

    @ViewBuilder
    private func iOSRow(_ entry: ServerEntry) -> some View {
        let active = isActive(entry)
        Button {
            pendingSwitchId = entry.id
        } label: {
            rowContent(entry)
                .padding(CinemaSpacing.spacing4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { activeWash(entry) }
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
                .contentShape(RoundedRectangle(cornerRadius: CinemaRadius.extraLarge))
        }
        .buttonStyle(.plain)
        // The active card is not a switch target, no second switch may start
        // while one is in flight, and a tap mid-reorder must not open the
        // switch dialog.
        .disabled(active || switchingId != nil || editMode.isEditing)
        // Applied OUTSIDE `.disabled`: the environment flows down, so the menu
        // stays reachable on the active card — the one most worth renaming.
        .contextMenu {
            renameAction(entry)
            localAddressAction(entry)
            if !active {
                Button(role: .destructive) {
                    pendingDeleteId = entry.id
                } label: {
                    Label(loc.localized("servers.delete"), systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            renameAction(entry)
                .tint(themeManager.accent)
            localAddressAction(entry)
                .tint(themeManager.accentDim)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(
            top: CinemaSpacing.spacing1,
            leading: CinemaSpacing.spacing4,
            bottom: CinemaSpacing.spacing1,
            trailing: CinemaSpacing.spacing4
        ))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // No delete affordance on the active server — the user has to
            // switch away first (mirrors the "THIS DEVICE" rule in the
            // connected-devices list).
            if !active {
                Button(role: .destructive) {
                    pendingDeleteId = entry.id
                } label: {
                    Label(loc.localized("servers.delete"), systemImage: "trash")
                }
            }
        }
    }
    #endif

    // MARK: - tvOS Chrome

    #if os(tvOS)
    private var tvOSChrome: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                tvHeader

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                        let ordered = entries
                        if ordered.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, entry in
                                tvRow(entry, index: index, count: ordered.count)
                            }
                        }

                        CinemaButton(
                            title: loc.localized("servers.add"),
                            style: .accent,
                            icon: "plus"
                        ) {
                            addServer()
                        }
                        .frame(width: CinemaTVLayout.ctaWidth * 2)
                        .focused($focusedItem, equals: .add)
                        .padding(.top, CinemaSpacing.spacing4)
                    }
                    .padding(.horizontal, CinemaTVLayout.pagePadding)
                    .padding(.bottom, CinemaSpacing.spacing10)
                    .frame(maxWidth: CinemaTVLayout.formMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollClipDisabled()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand { dismiss() }
    }

    private var tvHeader: some View {
        HStack(alignment: .center) {
            Text(loc.localized("servers.title"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)

            Spacer(minLength: CinemaSpacing.spacing6)

            CinemaButton(title: loc.localized("action.done"), style: .accent) {
                dismiss()
            }
            .frame(width: CinemaTVLayout.ctaWidth)
        }
        .padding(.horizontal, CinemaTVLayout.pagePadding)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
        // Without this, up-presses from the first card never reach Done
        // (separate container — same rule as the Home / Library hero).
        .focusSection()
    }

    /// One focusable unit per server (never per sub-element). Rename, the two
    /// moves and delete ride a `.contextMenu` (long-press-select) — tvOS has no
    /// swipe and no drag, the same answer `PlaylistDetailScreen` gives.
    ///
    /// The active card stays focusable and merely inert (the guard lives in the
    /// action, not in `.disabled`): a disabled card would make focus skip it
    /// and read as a missing card — and its context menu, rename included,
    /// would be unreachable.
    @ViewBuilder
    private func tvRow(_ entry: ServerEntry, index: Int, count: Int) -> some View {
        let active = isActive(entry)
        Button {
            // The active card is focusable but not a switch target. Say so
            // rather than swallowing the press: a select that does nothing at
            // all reads as a broken row on tvOS, where there is no hover or
            // disabled styling to explain it.
            guard !active else {
                toasts.info(loc.localized("servers.alreadyCurrent", entry.displayName))
                return
            }
            guard switchingId == nil else { return }
            pendingSwitchId = entry.id
        } label: {
            rowContent(entry)
                .padding(CinemaSpacing.spacing4)
                .frame(maxWidth: .infinity, minHeight: 110)
                .background { activeWash(entry) }
                .tvSettingsFocusable(
                    isFocused: focusedItem == .server(entry.id),
                    accent: themeManager.accent,
                    animated: motionEffects,
                    colorScheme: themeManager.darkModeEnabled ? .dark : .light
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .server(entry.id))
        .contextMenu {
            Button {
                beginRename(id: entry.id)
            } label: {
                Label(loc.localized("servers.rename"), systemImage: "pencil")
            }
            Button {
                beginLocalAddress(id: entry.id)
            } label: {
                Label(loc.localized("servers.localAddress"), systemImage: "house")
            }
            if index > 0 {
                Button {
                    move(id: entry.id, by: -1)
                } label: {
                    Label(loc.localized("servers.moveUp"), systemImage: "arrow.up")
                }
            }
            if index < count - 1 {
                Button {
                    move(id: entry.id, by: 1)
                } label: {
                    Label(loc.localized("servers.moveDown"), systemImage: "arrow.down")
                }
            }
            if !active {
                Button(role: .destructive) {
                    pendingDeleteId = entry.id
                } label: {
                    Label(loc.localized("servers.delete"), systemImage: "trash")
                }
            }
        }
    }
    #endif
}
