import SwiftUI
import CinemaxKit

#if os(iOS)
/// « Gérer les comptes » (iOS): the accounts remembered on this device for the
/// active server, each with its code, Face ID, age cap and removal.
///
/// The whole screen sits behind the parental gate when one is enrolled: the
/// age caps live here, and removing then re-adding a restricted account would
/// otherwise reset its cap (a new account inherits the CURRENT values).
struct AccountManageView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(AccountLockStore.self) private var locks

    var body: some View {
        ParentalLockGate {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                    ForEach(appState.activeAccounts, id: \.userId) { account in
                        NavigationLink {
                            AccountDetailView(account: account)
                        } label: {
                            row(account)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(loc.localized("accounts.manage.footer"))
                        .font(CinemaFont.dynamicLabel(.small))
                        .foregroundStyle(CinemaColor.onSurfaceMuted)
                        .padding(.top, CinemaSpacing.spacing3)
                }
                .padding(CinemaSpacing.spacing4)
            }
        }
        .background(CinemaColor.surface)
        .navigationTitle(loc.localized("accounts.manage"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ account: SavedAccount) -> some View {
        let key = appState.accountKey(for: account) ?? ""
        let age = appState.ageCap(forAccountKey: key)
        var badges: [String] = []
        if locks.hasLock(key) { badges.append(loc.localized("accounts.badge.code")) }
        if age > 0 { badges.append(loc.localized("accounts.badge.age", age)) }
        if appState.isExpired(account) { badges.append(loc.localized("accounts.expired")) }
        return HStack(spacing: CinemaSpacing.spacing3) {
            UserAvatar(userId: account.userId, name: account.username, primaryImageTag: nil, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.username)
                    .font(CinemaFont.dynamicLabel(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                if !badges.isEmpty {
                    Text(badges.joined(separator: " · "))
                        .font(CinemaFont.dynamicLabel(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            Spacer()
            Image(systemName: "chevron.forward")
                .foregroundStyle(CinemaColor.onSurfaceMuted)
                .accessibilityHidden(true)
        }
        .padding(CinemaSpacing.spacing3)
        .background(RoundedRectangle(cornerRadius: CinemaRadius.large).fill(CinemaColor.surfaceContainerHigh))
        .contentShape(Rectangle())
    }
}

/// One account's settings. A protected account other than the current one
/// first asks for ITS code: the parental gate in front proves the parent, not
/// the owner of this profile's code.
struct AccountDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(AccountLockStore.self) private var locks
    @Environment(\.motionEffectsEnabled) private var motionEffects
    @Environment(\.dismiss) private var dismiss

    let account: SavedAccount

    private enum CodeStage: Equatable { case choose, confirm(String) }

    /// The account's code typed — or chosen — during this visit.
    @State private var visit = AccountCodeVisit()
    @State private var codeStage: CodeStage?
    @State private var entry = ""
    @State private var message: String?
    @State private var showRemoveConfirm = false

    private var key: String { appState.accountKey(for: account) ?? "" }
    private var isCurrent: Bool { account.userId == appState.currentUserId }
    /// SETTING an account's own code is Pro; a code already set (during a Pro
    /// period) keeps guarding in free, and can be removed there (security
    /// review 2026-10-20).
    private var showsCodeRows: Bool { appState.keepsAccountSessions || locks.hasLock(key) }
    private var mustUnlock: Bool { visit.mustUnlock(key: key, hasCode: locks.hasLock(key), isCurrent: isCurrent) }

    var body: some View {
        // Pushed in the stack, hence OUTSIDE the list's gate: without its own,
        // a background → foreground re-lock left the age cap and « Retirer »
        // usable with no code (final review, I4).
        ParentalLockGate { content }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                if mustUnlock {
                    unlockStep
                } else if let codeStage {
                    enrolStep(codeStage)
                } else {
                    settings
                }
            }
            .padding(CinemaSpacing.spacing4)
        }
        .background(CinemaColor.surface)
        .navigationTitle(account.username)
        .navigationBarTitleDisplayMode(.inline)
        // An alert, not a `confirmationDialog`: iOS 27 shows the dialog as a
        // popover that hides its « Annuler » button (user decision 2026-10-23,
        // same as the account switcher's choices).
        .alert(
            loc.localized("accounts.detail.remove.confirm.title", account.username),
            isPresented: $showRemoveConfirm
        ) {
            Button(loc.localized("accounts.detail.remove"), role: .destructive) { remove() }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("accounts.detail.remove.confirm.message"))
        }
    }

    // MARK: Steps

    private var unlockStep: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Text(loc.localized("accounts.pin.title", account.username))
                .font(CinemaFont.dynamicHeadline())
                .foregroundStyle(CinemaColor.onSurface)
            ParentalPINDots(count: entry.count, minimumSlots: ParentalLockPolicy.accountPINLength)
            messageLine
            ParentalPINPad(entry: $entry, minimumLength: ParentalLockPolicy.accountPINLength,
                           maximumLength: ParentalLockPolicy.accountPINLength, isDisabled: locks.isVerifying) {
                Task { await verifyUnlock() }
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: entry) { _, value in
            if value.count == ParentalLockPolicy.accountPINLength { Task { await verifyUnlock() } }
        }
    }

    private func enrolStep(_ stage: CodeStage) -> some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Text(stage == .choose ? loc.localized("accounts.detail.code.set") : loc.localized("accounts.detail.code.confirm"))
                .font(CinemaFont.dynamicHeadline())
                .foregroundStyle(CinemaColor.onSurface)
            ParentalPINDots(count: entry.count, minimumSlots: ParentalLockPolicy.accountPINLength)
            messageLine
            ParentalPINPad(entry: $entry, minimumLength: ParentalLockPolicy.accountPINLength,
                           maximumLength: ParentalLockPolicy.accountPINLength, isDisabled: locks.isVerifying) {
                Task { await advanceEnrolment() }
            }
            CinemaButton(title: loc.localized("action.cancel"), style: .ghost) {
                codeStage = nil
                entry = ""
                message = nil
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: entry) { _, value in
            if value.count == ParentalLockPolicy.accountPINLength { Task { await advanceEnrolment() } }
        }
    }

    private var messageLine: some View {
        Text(message ?? " ")
            .font(CinemaFont.dynamicLabel(.medium))
            .foregroundStyle(CinemaColor.error)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
            HStack(spacing: CinemaSpacing.spacing3) {
                UserAvatar(userId: account.userId, name: account.username, primaryImageTag: nil, size: 56)
                Text(account.username)
                    .font(CinemaFont.dynamicHeadline())
                    .foregroundStyle(CinemaColor.onSurface)
            }

            if showsCodeRows {
            sectionHeader(loc.localized("accounts.detail.access"))
            VStack(spacing: 0) {
                toggleRow(
                    title: loc.localized("accounts.detail.code"),
                    subtitle: loc.localized("accounts.detail.code.subtitle"),
                    isOn: locks.hasLock(key)
                ) {
                    if locks.hasLock(key) {
                        locks.remove(key: key)
                    } else {
                        entry = ""
                        message = nil
                        codeStage = .choose
                    }
                }
                // Free shows the code row only to remove a code set while Pro:
                // no Face ID enrolment there (spec 2026-10-20).
                if appState.keepsAccountSessions, locks.hasLock(key), AccountLockStore.biometricsAvailable {
                    toggleRow(
                        title: loc.localized("accounts.detail.faceID"),
                        subtitle: loc.localized("accounts.detail.faceID.subtitle"),
                        isOn: locks.biometricsEnabled(key)
                    ) {
                        locks.setBiometricsEnabled(!locks.biometricsEnabled(key), key: key)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: CinemaRadius.large).fill(CinemaColor.surfaceContainerHigh))
            }

            sectionHeader(loc.localized("accounts.detail.own"))
            ageMenu
            Text(loc.localized("accounts.detail.follows"))
                .font(CinemaFont.dynamicLabel(.small))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
            Text(loc.localized("accounts.detail.iconNote"))
                .font(CinemaFont.dynamicLabel(.small))
                .foregroundStyle(CinemaColor.onSurfaceMuted)

            CinemaButton(title: loc.localized("accounts.detail.remove"), style: .ghost, icon: "person.crop.circle.badge.minus") {
                showRemoveConfirm = true
            }
            .padding(.top, CinemaSpacing.spacing2)
        }
    }

    private var ageMenu: some View {
        let current = appState.ageCap(forAccountKey: key)
        let option = ParentalAgeOption(rawValue: current) ?? .all
        return Menu {
            Picker(loc.localized("accounts.detail.age"), selection: Binding(
                get: { option },
                set: { appState.setAgeCap($0.age, forAccountKey: key) }
            )) {
                ForEach(ParentalAgeOption.allCases) { option in
                    Text(loc.localized(option.localizationKey)).tag(option)
                }
            }
        } label: {
            HStack {
                Text(loc.localized("accounts.detail.age"))
                    .font(CinemaFont.dynamicLabel(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Text(loc.localized(option.localizationKey))
                    .font(CinemaFont.dynamicLabel(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                    .accessibilityHidden(true)
            }
            .padding(CinemaSpacing.spacing3)
            .background(RoundedRectangle(cornerRadius: CinemaRadius.large).fill(CinemaColor.surfaceContainerHigh))
            .contentShape(Rectangle())
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(CinemaFont.dynamicLabel(.small))
            .foregroundStyle(CinemaColor.onSurfaceMuted)
            .accessibilityAddTraits(.isHeader)
    }

    private func toggleRow(title: String, subtitle: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CinemaFont.dynamicLabel(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Text(subtitle)
                        .font(CinemaFont.dynamicLabel(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                Spacer()
                CinemaToggleIndicator(isOn: isOn, accent: themeManager.accent, animated: motionEffects)
            }
            .padding(CinemaSpacing.spacing3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(loc.localized(isOn ? "a11y.toggle.on" : "a11y.toggle.off")))
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: Actions

    private func verifyUnlock() async {
        let pin = entry
        entry = ""
        switch await locks.verify(key: key, pin: pin) {
        case .unlocked:
            message = nil
            visit.unlocked(key)
        case .wrong:
            message = loc.localized("accounts.pin.wrong")
            Haptics.error()
        case .throttled(let until, _):
            message = loc.localized("accounts.pin.throttled", max(1, Int(until.timeIntervalSinceNow.rounded(.up))))
        }
    }

    private func advanceEnrolment() async {
        guard let stage = codeStage, entry.count == ParentalLockPolicy.accountPINLength else { return }
        let pin = entry
        entry = ""
        switch stage {
        case .choose:
            message = nil
            codeStage = .confirm(pin)
        case .confirm(let first):
            guard first == pin else {
                message = loc.localized("accounts.detail.code.mismatch")
                codeStage = .choose
                Haptics.error()
                return
            }
            if await locks.enroll(key: key, pin: pin, useBiometrics: false) {
                visit.enrolled(key)
                codeStage = nil
                message = nil
                Haptics.success()
            } else {
                message = loc.localized("error.generic")
            }
        }
    }

    private func remove() {
        let name = account.username
        let key = key
        locks.remove(key: key)
        Task {
            _ = await appState.removeAccount(userId: account.userId)
            toasts.success(loc.localized("accounts.removed", name))
            dismiss()
        }
    }
}
#endif
