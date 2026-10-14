import SwiftUI
import CinemaxKit

#if os(tvOS)
/// « Qui regarde ? » on Apple TV (multi-account): the living-room profile
/// picker.
///
/// Two hosts, one screen, both full-screen covers whose Menu dismisses:
/// - `.launch`: at launch (signed in, ≥ 2 remembered accounts, « Demander à
///   l'ouverture » on), BEFORE « Quoi de neuf ». Menu keeps the last profile.
/// - `.cover`: from the account avatar left of the tab bar
///   (`TVAccountAvatarButton`) or Réglages → Compte.
struct WhoIsWatchingScreen: View {
    enum Mode { case launch, cover }

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(AccountLockStore.self) private var locks
    @Environment(ParentalLockController.self) private var parentalLock
    @Environment(\.motionEffectsEnabled) private var motionEffects

    let mode: Mode
    /// Called once a profile is open (or kept): the host dismisses or goes to
    /// Accueil.
    let onFinished: () -> Void

    @State private var flow = AccountSwitchFlow()
    @State private var showAddChoice = false
    @State private var showSignIn = false
    @State private var showQuickConnect = false
    @State private var quickConnect = LoginViewModel()
    @State private var showManage = false
    @FocusState private var focusedTile: String?

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            switch flow.step {
            case .pick:
                if showAddChoice { addChoice } else { picker }
            case .code(let account, let parental):
                VStack(spacing: CinemaSpacing.spacing5) {
                    AccountCodeStep(flow: flow, account: account, parental: parental, avatarSize: 140) {
                        Task { if await flow.submit(appState: appState, locks: locks, parentalLock: parentalLock, toasts: toasts, loc: loc) { onFinished() } }
                    }
                    CinemaButton(title: loc.localized("action.cancel"), style: .ghost) { flow.back() }
                        .frame(width: CinemaTVLayout.ctaWidth)
                        .focusSection()
                }
            }
        }
        .onExitCommand(perform: exit)
        .fullScreenCover(isPresented: $showSignIn) {
            UserSwitchSheet()
                .environment(appState)
                .environment(themeManager)
                .environment(loc)
                .environment(toasts)
        }
        .fullScreenCover(item: $flow.reconnect) { account in
            UserSwitchSheet(prefilledUsername: account.username)
                .environment(appState)
                .environment(themeManager)
                .environment(loc)
                .environment(toasts)
        }
        .fullScreenCover(isPresented: $showQuickConnect) {
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
            }
        }
        .onChange(of: quickConnect.showSuccess) { _, success in
            guard success else { return }
            quickConnect.showSuccess = false
            showQuickConnect = false
            showAddChoice = false
            onFinished()
        }
        .fullScreenCover(isPresented: $showManage) {
            TVAccountManageScreen()
                .environment(appState)
                .environment(themeManager)
                .environment(loc)
                .environment(toasts)
                .environment(locks)
                .environment(parentalLock)
                .environment(\.motionEffectsEnabled, motionEffects)
        }
    }

    // MARK: Picker

    private var picker: some View {
        VStack(spacing: CinemaSpacing.spacing8) {
            VStack(spacing: CinemaSpacing.spacing2) {
                Text(appState.activeServerDisplayName.uppercased())
                    .font(CinemaFont.label(.medium))
                    .tracking(2)
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                Text(loc.localized("accounts.title"))
                    .font(CinemaFont.display(.small))
                    .foregroundStyle(CinemaColor.onSurface)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: CinemaSpacing.spacing8) {
                    ForEach(appState.activeAccounts, id: \.userId) { account in
                        Button {
                            Task {
                                if await flow.select(account, appState: appState, locks: locks, toasts: toasts, loc: loc) { onFinished() }
                            }
                        } label: {
                            AccountTile(
                                account: account,
                                isCurrent: account.userId == appState.currentUserId,
                                isLocked: appState.accountKey(for: account).map(locks.hasLock) ?? false,
                                isExpired: appState.isExpired(account),
                                avatarSize: 150,
                                isFocused: focusedTile == account.userId
                            )
                            .frame(width: 220)
                            .animation(motionEffects ? .easeInOut(duration: 0.2) : nil, value: focusedTile)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .hoverEffectDisabled()
                        .focused($focusedTile, equals: account.userId)
                        .disabled(flow.isWorking)
                    }
                    Button { showAddChoice = true } label: {
                        VStack(spacing: CinemaSpacing.spacing2) {
                            Image(systemName: "plus")
                                .font(.system(size: CinemaScale.pt(40), weight: .semibold))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                                .frame(width: 158, height: 158)
                                .background(Circle().fill(CinemaColor.surfaceContainerHigh))
                                .overlay {
                                    if focusedTile == "add" { Circle().strokeBorder(themeManager.accent, lineWidth: 3) }
                                }
                                .scaleEffect(focusedTile == "add" ? 1.06 : 1)
                            Text(loc.localized("accounts.add"))
                                .font(CinemaFont.dynamicLabel(.large))
                                .foregroundStyle(CinemaColor.onSurface)
                        }
                        .frame(width: 220)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .hoverEffectDisabled()
                    .focused($focusedTile, equals: "add")
                }
                .padding(.vertical, CinemaSpacing.spacing4)
                .padding(.horizontal, CinemaTVLayout.pagePadding)
            }
            // A row narrower than the screen sits centred under the centred
            // title (it started at the left edge — recette 2026-10-14, TV-11);
            // a longer one still scrolls from the left.
            .defaultScrollAnchor(.center, for: .alignment)
            .scrollClipDisabled()
            .focusSection()

            HStack(spacing: CinemaSpacing.spacing4) {
                CinemaButton(title: loc.localized("accounts.manage"), style: .ghost) { showManage = true }
                    .frame(width: 420)
                CinemaButton(title: loc.localized("action.done"), style: .accent) { onFinished() }
                    .frame(width: CinemaTVLayout.ctaWidth)
            }
            .focusSection()
        }
        .defaultFocus($focusedTile, appState.currentUserId)
    }

    private var addChoice: some View {
        VStack(spacing: CinemaSpacing.spacing6) {
            Text(loc.localized("accounts.add.title"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)
            Text(loc.localized("accounts.add.subtitle"))
                .font(CinemaFont.dynamicBody)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            VStack(spacing: CinemaSpacing.spacing3) {
                CinemaButton(title: loc.localized("accounts.add.quickConnect"), style: .accent, icon: "qrcode") {
                    showQuickConnect = true
                }
                CinemaButton(title: loc.localized("accounts.add.password"), style: .ghost, icon: "keyboard") {
                    showSignIn = true
                }
                CinemaButton(title: loc.localized("action.cancel"), style: .ghost) { showAddChoice = false }
            }
            .frame(width: 620)
            .focusSection()
        }
    }

    private func exit() {
        if case .code = flow.step { flow.back(); return }
        if showAddChoice { showAddChoice = false; return }
        onFinished()
    }
}

/// « Gérer les profils » (tvOS): one row per remembered account (code, age
/// cap, removal) and « Demander « Qui regarde ? » à l'ouverture ». Behind the
/// parental gate like its iOS counterpart; its chrome stays outside the gate so
/// « OK » is always reachable.
struct TVAccountManageScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(AccountLockStore.self) private var locks
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.accountsAskOnLaunch) private var askOnLaunch = SettingsKey.Default.accountsAskOnLaunch

    private enum Stage: Equatable {
        case list
        case unlock(SavedAccount)
        case choose(SavedAccount)
        case confirm(SavedAccount, String)
    }

    @State private var stage: Stage = .list
    @State private var entry = ""
    @State private var message: String?
    @State private var removing: SavedAccount?
    /// Protected accounts (other than the current one) whose code was typed in
    /// this screen: their rows unlock, as on iOS (`AccountDetailView`).
    @State private var openedKeys: Set<String> = []
    @FocusState private var focused: String?

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ParentalLockGate {
                    ScrollView {
                        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                            switch stage {
                            case .list: list
                            case .unlock(let account): pad(title: loc.localized("accounts.pin.title", account.username))
                            case .choose: pad(title: loc.localized("accounts.detail.code.set"))
                            case .confirm: pad(title: loc.localized("accounts.detail.code.confirm"))
                            }
                        }
                        .frame(maxWidth: CinemaTVLayout.formMaxWidth)
                        .padding(.horizontal, CinemaTVLayout.pagePadding)
                        .padding(.bottom, CinemaSpacing.spacing8)
                    }
                }
            }
        }
        .onExitCommand {
            if stage != .list { stage = .list; entry = ""; message = nil } else { dismiss() }
        }
        .alert(
            loc.localized("accounts.detail.remove.confirm.title", removing?.username ?? ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(loc.localized("accounts.detail.remove"), role: .destructive) { remove() }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("accounts.detail.remove.confirm.message"))
        }
    }

    private var header: some View {
        HStack {
            Text(loc.localized("accounts.manage"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)
            Spacer(minLength: CinemaSpacing.spacing6)
            CinemaButton(title: loc.localized("action.done"), style: .accent) { dismiss() }
                .frame(width: CinemaTVLayout.ctaWidth)
        }
        .padding(.horizontal, CinemaTVLayout.pagePadding)
        .padding(.top, CinemaSpacing.spacing8)
        .padding(.bottom, CinemaSpacing.spacing5)
        .focusSection()
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            ForEach(appState.activeAccounts, id: \.userId) { account in
                accountBlock(account)
            }
            row(id: "askOnLaunch",
                title: loc.localized("accounts.askOnLaunch"),
                subtitle: loc.localized("accounts.askOnLaunch.subtitle"),
                value: loc.localized(askOnLaunch ? "a11y.toggle.on" : "a11y.toggle.off")) {
                askOnLaunch.toggle()
            }
            .padding(.top, CinemaSpacing.spacing4)
            Text(loc.localized("accounts.manage.footer"))
                .font(CinemaFont.dynamicLabel(.small))
                .foregroundStyle(CinemaColor.onSurfaceMuted)
        }
    }

    @ViewBuilder
    private func accountBlock(_ account: SavedAccount) -> some View {
        let key = appState.accountKey(for: account) ?? ""
        let hasCode = locks.hasLock(key)
        let age = appState.ageCap(forAccountKey: key)
        let option = ParentalAgeOption(rawValue: age) ?? .all
        // Same rule as iOS: another account's protected settings (its code,
        // age cap, removal) open only with ITS code (security review parity).
        let mustOpen = hasCode && account.userId != appState.currentUserId && !openedKeys.contains(key)
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            HStack(spacing: CinemaSpacing.spacing3) {
                UserAvatar(userId: account.userId, name: account.username, primaryImageTag: nil, size: 60)
                Text(account.username)
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurface)
            }
            if mustOpen {
                row(id: "open-\(key)", title: loc.localized("accounts.pin.title", account.username),
                    subtitle: loc.localized("accounts.codeRequired"), value: nil) {
                    begin(.unlock(account))
                }
            } else {
            row(id: "code-\(key)", title: loc.localized("accounts.detail.code"),
                subtitle: loc.localized("accounts.detail.code.subtitle"),
                value: loc.localized(hasCode ? "a11y.toggle.on" : "a11y.toggle.off")) {
                if hasCode {
                    locks.remove(key: key)
                } else {
                    begin(.choose(account))
                }
            }
            row(id: "age-\(key)", title: loc.localized("accounts.detail.age"), subtitle: nil,
                value: loc.localized(option.localizationKey)) {
                let all = ParentalAgeOption.allCases
                let next = all[((all.firstIndex(of: option) ?? 0) + 1) % all.count]
                appState.setAgeCap(next.age, forAccountKey: key)
            }
            row(id: "remove-\(key)", title: loc.localized("accounts.detail.remove"), subtitle: nil, value: nil) {
                removing = account
            }
            }
        }
        .padding(.bottom, CinemaSpacing.spacing4)
    }

    private func row(id: String, title: String, subtitle: String?, value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: CinemaSpacing.spacing3) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    if let subtitle {
                        Text(subtitle)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                }
                Spacer()
                if let value {
                    Text(value)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing5)
            .padding(.vertical, CinemaSpacing.spacing4)
            .tvSettingsFocusable(isFocused: focused == id, accent: themeManager.accent, animated: motionEffects,
                                 colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focused, equals: id)
    }

    private func pad(title: String) -> some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Text(title)
                .font(CinemaFont.headline(.medium))
                .foregroundStyle(CinemaColor.onSurface)
            ParentalPINDots(count: entry.count, minimumSlots: ParentalLockPolicy.accountPINLength)
            Text(message ?? " ")
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.error)
            ParentalPINPad(entry: $entry, minimumLength: ParentalLockPolicy.accountPINLength,
                           maximumLength: ParentalLockPolicy.accountPINLength, isDisabled: locks.isVerifying) {
                Task { await advance() }
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: entry) { _, value in
            if value.count == ParentalLockPolicy.accountPINLength { Task { await advance() } }
        }
    }

    private func begin(_ next: Stage) {
        entry = ""
        message = nil
        stage = next
    }

    private func advance() async {
        guard entry.count == ParentalLockPolicy.accountPINLength else { return }
        let pin = entry
        entry = ""
        switch stage {
        case .list:
            return
        case .unlock(let account):
            guard let key = appState.accountKey(for: account) else { return }
            switch await locks.verify(key: key, pin: pin) {
            case .unlocked:
                openedKeys.insert(key)
                begin(.list)
            case .wrong:
                message = loc.localized("accounts.pin.wrong")
            case .throttled(let until, _):
                message = loc.localized("accounts.pin.throttled", max(1, Int(until.timeIntervalSinceNow.rounded(.up))))
            }
        case .choose(let account):
            message = nil
            stage = .confirm(account, pin)
        case .confirm(let account, let first):
            guard first == pin else {
                message = loc.localized("accounts.detail.code.mismatch")
                stage = .choose(account)
                return
            }
            guard let key = appState.accountKey(for: account) else { return }
            if await locks.enroll(key: key, pin: pin, useBiometrics: false) {
                begin(.list)
            } else {
                message = loc.localized("error.generic")
            }
        }
    }

    private func remove() {
        guard let account = removing, let key = appState.accountKey(for: account) else { return }
        removing = nil
        locks.remove(key: key)
        Task {
            _ = await appState.removeAccount(userId: account.userId)
            toasts.success(loc.localized("accounts.removed", account.username))
        }
    }
}

/// The account avatar LEFT of the top tab bar (recette 2026-10-14, TV-10) —
/// tvOS's counterpart of the iPhone's `AccountAvatarToolbarButton`. It was a
/// leading « Profil » tab, and six tabs overflowed the native bar: the first
/// and last were cut. `UITabBar.leadingAccessoryView` cannot host it (its
/// subviews never take input, per the SDK header), so `MainTabView` overlays
/// it while focus is in the bar, and a left press from the first tab reaches
/// it. The host owns the presentation: this button disappears as soon as
/// focus leaves the bar, which would tear down a cover attached here.
struct TVAccountAvatarButton: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @FocusState private var isFocused: Bool

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            UserAvatar(userId: appState.currentUserId, name: appState.currentUser?.name,
                       primaryImageTag: appState.currentUser?.primaryImageTag, size: 64)
                .overlay {
                    if isFocused {
                        Circle().strokeBorder(themeManager.accent, lineWidth: CinemaTVFocus.cardRingWidth)
                    }
                }
                .scaleEffect(isFocused ? CinemaTVFocus.cardScale : 1)
                .animation(motionEffects ? .easeInOut(duration: 0.2) : nil, value: isFocused)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($isFocused)
        .accessibilityLabel(loc.localized("accessibility.accounts.switcher"))
        .accessibilityValue(Text(appState.currentUser?.name ?? ""))
    }
}
#endif
