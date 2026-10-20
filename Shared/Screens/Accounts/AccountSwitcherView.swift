import SwiftUI
import CinemaxKit

/// One profile of the switcher: avatar (accent ring on the current one), name,
/// and what opening it involves (« En cours », « Code requis », « Session
/// expirée »). Shared by the iOS switcher and the tvOS « Qui regarde ? ».
struct AccountTile: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    let account: SavedAccount
    let isCurrent: Bool
    let isLocked: Bool
    let isExpired: Bool
    /// Opening it asks for a sign-in (free tier, or no session on this device)
    /// — said quietly, unlike a real expiry (`AppState.needsSignIn`).
    var needsSignIn: Bool = false
    let avatarSize: CGFloat
    /// tvOS: the tile has focus — a round portrait draws its own circular
    /// accent ring and grows (card focus level, `CinemaTVFocus`).
    var isFocused: Bool = false

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            UserAvatar(userId: account.userId, name: account.username, primaryImageTag: nil, size: avatarSize)
                .overlay(alignment: .bottomTrailing) {
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: CinemaScale.pt(avatarSize * 0.14), weight: .bold))
                            .foregroundStyle(CinemaColor.onSurface)
                            .padding(avatarSize * 0.07)
                            .background(Circle().fill(CinemaColor.surfaceContainerHighest))
                            .accessibilityHidden(true)
                    }
                }
                .padding(4)
                .overlay {
                    if isCurrent || isFocused {
                        Circle().strokeBorder(themeManager.accent.opacity(isFocused ? 1 : 0.7), lineWidth: 3)
                    }
                }
                .shadow(color: themeManager.accent.opacity(isFocused ? 0.35 : 0), radius: 22, y: 12)
                .scaleEffect(isFocused ? 1.06 : 1)
            Text(account.username)
                .font(CinemaFont.dynamicLabel(.large))
                .foregroundStyle(CinemaColor.onSurface)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(status ?? " ")
                .font(CinemaFont.dynamicLabel(.small))
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(account.username))
        .accessibilityValue(Text(status ?? ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var status: String? {
        if isCurrent { return loc.localized("accounts.current") }
        if isExpired { return loc.localized("accounts.expired") }
        if needsSignIn { return loc.localized("accounts.signedOut") }
        if isLocked { return loc.localized("accounts.codeRequired") }
        return nil
    }

    private var statusColor: Color {
        if isCurrent { return themeManager.accent }
        if isExpired { return CinemaColor.error }
        return CinemaColor.onSurfaceMuted
    }
}

/// The code step shared by both platforms: avatar, title, dots, pad, message.
struct AccountCodeStep: View {
    @Environment(LocalizationManager.self) private var loc
    @Bindable var flow: AccountSwitchFlow
    let account: SavedAccount
    let parental: Bool
    let avatarSize: CGFloat
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            UserAvatar(userId: account.userId, name: account.username, primaryImageTag: nil, size: avatarSize)
            VStack(spacing: CinemaSpacing.spacing1) {
                Text(parental ? loc.localized("accounts.pin.parental.title")
                              : loc.localized("accounts.pin.title", account.username))
                    .font(CinemaFont.dynamicHeadline())
                    .foregroundStyle(CinemaColor.onSurface)
                    .multilineTextAlignment(.center)
                if parental {
                    Text(loc.localized("accounts.pin.parental.subtitle", account.username))
                        .font(CinemaFont.dynamicBody)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
            }
            ParentalPINDots(count: flow.entry.count,
                            minimumSlots: parental ? ParentalLockPolicy.minUnlockPINLength : ParentalLockPolicy.accountPINLength)
            Text(flow.message ?? " ")
                .font(CinemaFont.dynamicLabel(.medium))
                .foregroundStyle(CinemaColor.error)
                .accessibilityHidden(flow.message == nil)
            ParentalPINPad(
                entry: $flow.entry,
                minimumLength: parental ? ParentalLockPolicy.minUnlockPINLength : ParentalLockPolicy.accountPINLength,
                maximumLength: parental ? ParentalLockPolicy.maxPINLength : ParentalLockPolicy.accountPINLength,
                isDisabled: flow.isWorking,
                onSubmit: onSubmit
            )
        }
        // A 4-digit account code submits by itself on its 4th digit.
        .onChange(of: flow.entry) { _, value in
            if !parental, value.count == ParentalLockPolicy.accountPINLength { onSubmit() }
        }
    }
}

#if os(iOS)
/// « Qui regarde ? » on iPhone and iPad, opened from the avatar in Home's bar.
/// Presented as a `.popover`: a popover on iPad / Duo open, a sheet in compact
/// width (iPhone, Duo closed) — the class decides, never the device.
struct AccountSwitcherView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(AccountLockStore.self) private var locks
    @Environment(ParentalLockController.self) private var parentalLock
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(EarlyAdopterService.self) private var earlyAdopter
    @Environment(ProStore.self) private var proStore
    @Environment(\.dismiss) private var dismiss

    @State private var flow = AccountSwitchFlow()
    @State private var showAddAccount = false
    @State private var showAddChoice = false
    @State private var showQuickConnect = false
    @State private var quickConnect = LoginViewModel()
    /// The remembered account whose password step is open (« Se reconnecter »
    /// → Mot de passe).
    @State private var reconnectWithPassword: SavedAccount?
    @State private var reconnectTarget: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch flow.step {
                    case .pick:
                        pickGrid
                    case .code(let account, let parental):
                        AccountCodeStep(flow: flow, account: account, parental: parental, avatarSize: 72) {
                            Task { if await flow.submit(appState: appState, locks: locks, parentalLock: parentalLock, toasts: toasts, loc: loc) { dismiss() } }
                        }
                        faceIDButton(account: account, parental: parental)
                    }
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .code = flow.step {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { flow.back() } label: { Image(systemName: "chevron.backward") }
                            .accessibilityLabel(loc.localized("action.back"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(loc.localized("action.done"))
                }
            }
        }
        .frame(minWidth: 360, idealWidth: 400, minHeight: 460, idealHeight: 560)
        .sheet(isPresented: $showAddAccount) { signInSheet(prefilled: nil) }
        // « Ajouter »: Quick Connect (approve from a device where the account
        // is signed in — no password typed) or username + password.
        .confirmationDialog(loc.localized("accounts.add.title"), isPresented: $showAddChoice, titleVisibility: .visible) {
            Button(loc.localized("accounts.add.quickConnect")) { showQuickConnect = true }
            Button(loc.localized("accounts.add.password")) { showAddAccount = true }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("accounts.add.subtitle"))
        }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectSheet(viewModel: quickConnect)
                .environment(themeManager)
                .environment(loc)
        }
        .onChange(of: showQuickConnect) { _, presented in
            if presented {
                quickConnect.addsAccount = true
                quickConnect.startQuickConnect(using: appState, loc: loc)
            } else {
                quickConnect.cancelQuickConnect()
                // A reconnection abandoned here leaves no marker behind
                // (`AppState.clearPendingSignIn`); after a success it is a no-op.
                appState.clearPendingSignIn()
            }
        }
        .onChange(of: quickConnect.showSuccess) { _, success in
            guard success else { return }
            quickConnect.showSuccess = false
            showQuickConnect = false
            dismiss()
        }
        // « Se reconnecter » (free tier, or an account without a session):
        // Quick Connect or the password, as for « Ajouter ».
        .confirmationDialog(
            loc.localized("accounts.reconnect.title", flow.reconnect?.username ?? ""),
            isPresented: reconnectChoice,
            titleVisibility: .visible,
            presenting: flow.reconnect
        ) { account in
            Button(loc.localized("accounts.add.quickConnect")) { showQuickConnect = true }
            Button(loc.localized("accounts.add.password")) {
                reconnectTarget = account.userId
                reconnectWithPassword = account
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        }
        .sheet(item: $reconnectWithPassword, onDismiss: finishReconnection) { account in
            signInSheet(prefilled: account.username, showsProHint: !appState.keepsAccountSessions)
        }
    }

    /// The reconnection choice is up while `flow.reconnect` names an account.
    /// Closing it without picking a way in drops the pending sign-in marker;
    /// the check waits a turn, the picked button's action having run first.
    private var reconnectChoice: Binding<Bool> {
        Binding(
            get: { flow.reconnect != nil },
            set: { presented in
                guard !presented else { return }
                flow.reconnect = nil
                Task { @MainActor in
                    if reconnectWithPassword == nil && !showQuickConnect { appState.clearPendingSignIn() }
                }
            }
        )
    }

    /// The password step closed: a success opened the profile (the switcher
    /// closes too); anything else just drops the pending sign-in marker.
    private func finishReconnection() {
        appState.clearPendingSignIn()
        let opened = reconnectTarget != nil && reconnectTarget == appState.currentUserId
        reconnectTarget = nil
        if opened { dismiss() }
    }

    private var title: String {
        if case .code = flow.step { return "" }
        return loc.localized("accounts.title")
    }

    // MARK: Profiles

    private var pickGrid: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            Text(appState.activeServerDisplayName)
                .font(CinemaFont.dynamicLabel(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: CinemaSpacing.spacing3)],
                      spacing: CinemaSpacing.spacing4) {
                ForEach(appState.activeAccounts, id: \.userId) { account in
                    Button {
                        Task {
                            if await flow.select(account, appState: appState, locks: locks, toasts: toasts, loc: loc) { dismiss() }
                        }
                    } label: {
                        AccountTile(
                            account: account,
                            isCurrent: account.userId == appState.currentUserId,
                            isLocked: appState.accountKey(for: account).map(locks.hasLock) ?? false,
                            isExpired: appState.isExpired(account),
                            needsSignIn: appState.needsSignIn(account),
                            avatarSize: 72
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(flow.isWorking)
                }
                Button { showAddChoice = true } label: {
                    VStack(spacing: CinemaSpacing.spacing2) {
                        Image(systemName: "plus")
                            .font(.system(size: CinemaScale.pt(26), weight: .semibold))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .frame(width: 80, height: 80)
                            .background(Circle().fill(CinemaColor.surfaceContainerHigh))
                        Text(loc.localized("accounts.add"))
                            .font(CinemaFont.dynamicLabel(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                        Text(" ").font(CinemaFont.dynamicLabel(.small))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            NavigationLink {
                AccountManageView()
            } label: {
                HStack {
                    Image(systemName: "person.2.badge.gearshape")
                        .foregroundStyle(themeManager.accent)
                    Text(loc.localized("accounts.manage"))
                        .font(CinemaFont.dynamicLabel(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .foregroundStyle(CinemaColor.onSurfaceMuted)
                }
                .padding(CinemaSpacing.spacing3)
                .background(RoundedRectangle(cornerRadius: CinemaRadius.large).fill(CinemaColor.surfaceContainerHigh))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func faceIDButton(account: SavedAccount, parental: Bool) -> some View {
        let available = parental
            ? (parentalLock.biometricsArmed)
            : (appState.accountKey(for: account).map(locks.biometricsEnabled) ?? false)
        if available {
            Button {
                Task { if await flow.biometrics(appState: appState, locks: locks, parentalLock: parentalLock, toasts: toasts, loc: loc) { dismiss() } }
            } label: {
                Label(loc.localized("accounts.detail.faceID"), systemImage: "faceid")
                    .font(CinemaFont.dynamicLabel(.large))
            }
            .padding(.top, CinemaSpacing.spacing2)
        }
    }

    private func signInSheet(prefilled: String?, showsProHint: Bool = false) -> some View {
        UserSwitchSheet(prefilledUsername: prefilled, showsProReconnectHint: showsProHint)
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toasts)
            .environment(entitlements)
            .environment(earlyAdopter)
            .environment(proStore)
    }
}

/// The avatar leading every tab root's navigation bar (iOS, `MainTabView`). A toolbar item: iOS 26 draws its
/// Liquid Glass itself — never `.buttonStyle(.glass)` on it (root RULE).
struct AccountAvatarToolbarButton: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(AccountLockStore.self) private var locks
    @Environment(ParentalLockController.self) private var parentalLock
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(EarlyAdopterService.self) private var earlyAdopter
    @Environment(ProStore.self) private var proStore
    @Environment(NetworkMonitor.self) private var network
    @State private var showSwitcher = false

    var body: some View {
        Button { showSwitcher = true } label: {
            UserAvatar(userId: appState.currentUserId, name: appState.currentUser?.name,
                       primaryImageTag: appState.currentUser?.primaryImageTag, size: 30)
        }
        .accessibilityLabel(loc.localized("accessibility.accounts.switcher"))
        .accessibilityValue(Text(appState.currentUser?.name ?? ""))
        .popover(isPresented: $showSwitcher) {
            // Presentations don't inherit the root's injected @Observables.
            AccountSwitcherView()
                .environment(appState)
                .environment(themeManager)
                .environment(loc)
                .environment(toasts)
                .environment(locks)
                .environment(parentalLock)
                .environment(entitlements)
                .environment(earlyAdopter)
                .environment(proStore)
                .environment(network)
                .preferredColorScheme(themeManager.colorScheme)
        }
    }
}
#endif
