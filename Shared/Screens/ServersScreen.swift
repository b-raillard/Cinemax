import SwiftUI
import CinemaxKit

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

    /// Attempt flag. The tvOS Settings surface re-presents (and re-fires its
    /// `.task`) on **every** `MenuConfigStore` mutation, so an unguarded probe
    /// would re-ping the whole fleet on each menu interaction — same precedent
    /// as `SettingsScreen.serverUsersLoadAttempted`.
    private var hasPinged = false

    func status(for id: String) -> PingStatus? { statuses[id] }

    /// Drops a removed entry's status so a re-added server starts from a clean
    /// "probing" state instead of inheriting a stale dot.
    func forget(id: String) { statuses[id] = nil }

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

        await withTaskGroup(of: Probe.self) { group in
            for entry in entries {
                let id = entry.id
                let url = entry.url
                group.addTask { Probe(id: id, result: await ServerReachability.ping(url: url)) }
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
        case .online(let name, let version):
            statuses[probe.id] = .online
            appState.updateServerMetadata(id: probe.id, name: name, version: version)
        case .offline:
            statuses[probe.id] = .offline
        }
    }

    private struct Probe: Sendable {
        let id: String
        let result: PingResult
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
/// (`.swipeActions` only exists on `List`). The glass card look is preserved via
/// `.listStyle(.plain)` + cleared row backgrounds / separators. Same kind of
/// explicit exception as `MenuSettingsScreen+iOS`'s native `List` + `Picker`.
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

    /// Active first, then most-recently-used (total order — the list never
    /// reshuffles between renders).
    private var entries: [ServerEntry] {
        ServerRegistry.sorted(appState.servers, activeId: appState.activeServerId)
    }

    private func isActive(_ entry: ServerEntry) -> Bool {
        entry.id == appState.activeServerId
    }

    private func name(for id: String) -> String {
        appState.servers.first(where: { $0.id == id })?.name ?? ServerEntry.fallbackName
    }

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSChrome
            #else
            iOSChrome
            #endif
        }
        .task { await viewModel.pingIfNeeded(using: appState) }
        .confirmationDialog(
            loc.localized("servers.switch.action"),
            isPresented: Binding(
                get: { pendingSwitchId != nil },
                set: { if !$0 { pendingSwitchId = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingSwitchId
        ) { id in
            Button(loc.localized("servers.switch.action")) {
                Task { await performSwitch(id: id) }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: { id in
            Text(loc.localized("servers.switch.confirm", name(for: id)))
        }
        .confirmationDialog(
            loc.localized("servers.delete"),
            isPresented: Binding(
                get: { pendingDeleteId != nil },
                set: { if !$0 { pendingDeleteId = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteId
        ) { id in
            Button(loc.localized("servers.delete"), role: .destructive) {
                Task { await performDelete(id: id) }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: { id in
            Text(loc.localized("servers.delete.confirm", name(for: id)))
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
            toasts.success(loc.localized("servers.switchedTo", entry.name))
            dismiss()
        case .offline:
            toasts.error(loc.localized("servers.offline"))
        case .unreachable:
            toasts.error(loc.localized("servers.unreachable"))
        case .needsLogin:
            // The root already swapped to `LoginScreen` scoped to that server.
            // Dismiss so this modal doesn't sit on top of it (it survives when
            // the host is `LoginScreen` itself, which stays mounted).
            dismiss()
        }
    }

    private func performDelete(id: String) async {
        guard let entry = appState.servers.first(where: { $0.id == id }),
              entry.id != appState.activeServerId else { return }
        await appState.removeServer(entry)
        viewModel.forget(id: id)
        toasts.success(loc.localized("servers.deleted", entry.name))
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
                HStack(spacing: CinemaSpacing.spacing2) {
                    Text(entry.name)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)

                    if isActive(entry) { currentPill }
                }

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

            Spacer(minLength: CinemaSpacing.spacing2)

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
        let source = entry.username?.isEmpty == false ? entry.username! : entry.name
        return ZStack {
            Circle()
                .fill(themeManager.accentContainer)
                .frame(width: badgeSize, height: badgeSize)

            Text(String(source.prefix(1)).uppercased())
                .font(CinemaFont.label(.large))
                .foregroundStyle(themeManager.onAccent)
        }
        .accessibilityHidden(true)
    }

    private var currentPill: some View {
        Text(loc.localized("servers.current"))
            .font(CinemaFont.label(.small))
            .foregroundStyle(themeManager.onAccent)
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
            .accessibilityLabel(
                status == .online
                    ? loc.localized("servers.online")
                    : loc.localized("servers.offlineBadge")
            )
    }

    private func statusColor(_ status: ServersViewModel.PingStatus?) -> Color {
        switch status {
        case .online:  CinemaColor.success
        case .offline: CinemaColor.error
        default:       CinemaColor.onSurfaceVariant.opacity(0.5)
        }
    }

    private func displayAddress(_ entry: ServerEntry) -> String {
        entry.url.host ?? entry.url.absoluteString
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(loc.localized("action.done")) { dismiss() }
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
        }
    }

    private var serverList: some View {
        List {
            ForEach(entries, id: \.id) { entry in
                iOSRow(entry)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
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
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
                .overlay { activeWash(entry) }
                .contentShape(RoundedRectangle(cornerRadius: CinemaRadius.extraLarge))
        }
        .buttonStyle(.plain)
        // The active card is not a switch target, and no second switch may
        // start while one is in flight.
        .disabled(active || switchingId != nil)
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
                        if entries.isEmpty {
                            emptyState
                        } else {
                            ForEach(entries, id: \.id) { entry in
                                tvRow(entry)
                            }
                        }

                        CinemaButton(
                            title: loc.localized("servers.add"),
                            style: .accent,
                            icon: "plus"
                        ) {
                            addServer()
                        }
                        .frame(width: 480)
                        .focused($focusedItem, equals: .add)
                        .padding(.top, CinemaSpacing.spacing4)
                    }
                    .padding(.horizontal, CinemaSpacing.spacing10)
                    .padding(.bottom, CinemaSpacing.spacing10)
                    .frame(maxWidth: 1400, alignment: .leading)
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
            .frame(width: 240)
        }
        .padding(.horizontal, CinemaSpacing.spacing10)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
        // Without this, up-presses from the first card never reach Done
        // (separate container — same rule as the Home / Library hero).
        .focusSection()
    }

    /// One focusable unit per server (never per sub-element). Delete rides a
    /// `.contextMenu` (long-press-select) — tvOS has no swipe.
    ///
    /// The active card stays focusable and merely inert (the guard lives in the
    /// action, not in `.disabled`): it sorts first, and a disabled first row
    /// would make focus skip it and read as a missing card.
    @ViewBuilder
    private func tvRow(_ entry: ServerEntry) -> some View {
        let active = isActive(entry)
        Button {
            guard !active, switchingId == nil else { return }
            pendingSwitchId = entry.id
        } label: {
            rowContent(entry)
                .padding(CinemaSpacing.spacing4)
                .frame(maxWidth: .infinity, minHeight: 110)
                .tvSettingsFocusable(
                    isFocused: focusedItem == .server(entry.id),
                    accent: themeManager.accent,
                    animated: motionEffects,
                    colorScheme: themeManager.darkModeEnabled ? .dark : .light
                )
                .overlay { activeWash(entry) }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .server(entry.id))
        .contextMenu {
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
