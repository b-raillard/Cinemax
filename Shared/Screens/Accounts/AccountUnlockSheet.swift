import SwiftUI
import CinemaxKit

/// Asks the code that opens ONE account outside « Qui regarde ? » — a SERVER
/// switch from « Mes serveurs » whose target account is protected, or less
/// restricted than the current one while the parental code is set
/// (`SwitchDecision.locked`). The account's own code when it has one, else the
/// parental code, which is closed again at once (it opened a switch, not the
/// parental settings).
///
/// Reads the two process singletons directly: « Mes serveurs » is hosted from
/// three places (Réglages and the two pre-auth screens), none of which injects
/// them.
struct AccountUnlockSheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let accountKey: String
    let name: String
    /// Called once the code is right; the caller then switches with `unlocked: true`.
    let onUnlocked: () -> Void

    @State private var entry = ""
    @State private var message: String?
    @State private var isVerifying = false

    private var locks: AccountLockStore { AppNavigation.sharedAccountLocks }
    private var parentalLock: ParentalLockController { AppNavigation.sharedParentalLock }
    private var parental: Bool { !locks.hasLock(accountKey) }
    private var minimum: Int { parental ? ParentalLockPolicy.minUnlockPINLength : ParentalLockPolicy.accountPINLength }
    private var maximum: Int { parental ? ParentalLockPolicy.maxPINLength : ParentalLockPolicy.accountPINLength }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            VStack(spacing: CinemaSpacing.spacing4) {
                #if os(tvOS)
                HStack {
                    Spacer()
                    CinemaButton(title: loc.localized("action.cancel"), style: .accent) { dismiss() }
                        .frame(width: CinemaTVLayout.ctaWidth)
                }
                .padding(.horizontal, CinemaTVLayout.pagePadding)
                .padding(.top, CinemaSpacing.spacing8)
                .focusSection()
                #else
                HStack {
                    Spacer()
                    Button(loc.localized("action.cancel")) { dismiss() }
                }
                .padding(CinemaSpacing.spacing4)
                #endif
                Text(parental ? loc.localized("accounts.pin.parental.title") : loc.localized("accounts.pin.title", name))
                    .font(CinemaFont.dynamicHeadline())
                    .foregroundStyle(CinemaColor.onSurface)
                if parental {
                    Text(loc.localized("accounts.pin.parental.subtitle", name))
                        .font(CinemaFont.dynamicBody)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, CinemaSpacing.spacing4)
                }
                ParentalPINDots(count: entry.count, minimumSlots: minimum)
                Text(message ?? " ")
                    .font(CinemaFont.dynamicLabel(.medium))
                    .foregroundStyle(CinemaColor.error)
                ParentalPINPad(entry: $entry, minimumLength: minimum, maximumLength: maximum, isDisabled: isVerifying) {
                    Task { await verify() }
                }
                Spacer(minLength: 0)
            }
        }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
        .onChange(of: entry) { _, value in
            if !parental, value.count == ParentalLockPolicy.accountPINLength { Task { await verify() } }
        }
    }

    private func verify() async {
        guard !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        let pin = entry
        entry = ""
        let verdict = parental ? await parentalLock.verify(pin: pin) : await locks.verify(key: accountKey, pin: pin)
        switch verdict {
        case .unlocked:
            if parental { parentalLock.lockForBackground() }
            dismiss()
            onUnlocked()
        case .wrong:
            message = loc.localized("accounts.pin.wrong")
            Haptics.error()
        case .throttled(let until, _):
            message = loc.localized("accounts.pin.throttled", max(1, Int(until.timeIntervalSinceNow.rounded(.up))))
        }
    }
}
