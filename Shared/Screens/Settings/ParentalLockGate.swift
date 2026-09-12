import SwiftUI
import CinemaxKit

// MARK: - Gate

/// Reveals `content` only while the parental lock is open (or absent).
///
/// **RULE — the controller is read as a NON-optional `@Environment`, against the
/// project's usual optional-`@Observable` discipline, and that is deliberate.**
/// An optional read resolves to `nil` wherever the injection was forgotten, and
/// for a *gate* `nil` would mean "no lock" — i.e. a missing injection would
/// silently unprotect the screen. A non-optional read traps instead, which fails
/// loudly in development rather than quietly in a user's hands. The one host is
/// `SettingsScreen.privacySecuritySheet`, which re-injects the environment by
/// hand like every other sheet there.
struct ParentalLockGate<Content: View>: View {
    @Environment(ParentalLockController.self) private var lock
    @ViewBuilder var content: () -> Content

    var body: some View {
        if lock.isEnabled && !lock.isUnlocked {
            ParentalUnlockView()
        } else {
            content()
        }
    }
}

// MARK: - Unlock

/// The PIN (and, on iOS, biometric) challenge shown in place of the gated
/// content. Deliberately NOT a presentation: it renders inside the host screen's
/// chrome so the Done button stays reachable — a modal challenge a parent could
/// not dismiss would be a trap, and on tvOS a cover whose only focusable is a
/// pad would swallow the Menu press.
private struct ParentalUnlockView: View {
    @Environment(ParentalLockController.self) private var lock
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    @State private var entry = ""
    @State private var message: String?
    /// Re-rendered every second while a back-off window is open, so the
    /// countdown moves and the pad re-enables itself when it closes. The loop
    /// exits on its own — no timer outlives the window.
    @State private var tick = Date()

    private var throttledUntil: Date? { lock.throttledUntil }

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Image(systemName: "lock.shield")
                .font(.system(size: CinemaScale.pt(34), weight: .semibold))
                .foregroundStyle(themeManager.accent)

            VStack(spacing: CinemaSpacing.spacing1) {
                Text(loc.localized("privacy.lock.unlock.title"))
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Text(loc.localized("privacy.lock.unlock.subtitle"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }

            ParentalPINDots(count: entry.count)

            if let text = statusMessage {
                Text(text)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.error)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isStaticText)
            }

            ParentalPINPad(
                entry: $entry,
                isDisabled: lock.isVerifying || throttledUntil != nil,
                onSubmit: { Task { await submit() } }
            )

            #if os(iOS)
            if lock.biometricsEnabled, ParentalLockController.biometricsAvailable {
                Button {
                    Task { await tryBiometrics() }
                } label: {
                    Label(loc.localized("privacy.lock.unlock.biometrics"), systemImage: "faceid")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(themeManager.accent)
                }
                .buttonStyle(.plain)
            }
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CinemaSpacing.spacing6)
        .task {
            // A lock whose biometric shortcut is on challenges straight away:
            // the parent's intent is already expressed by opening the screen.
            #if os(iOS)
            if lock.biometricsEnabled { await tryBiometrics() }
            #endif
        }
        .task(id: throttledUntil) {
            guard let deadline = throttledUntil else { return }
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                tick = Date()
            }
            tick = Date()
        }
    }

    /// The throttle countdown wins over a stale "wrong PIN" line — it is the
    /// only one that tells the user what to do next (wait).
    private var statusMessage: String? {
        if let until = throttledUntil {
            _ = tick   // re-read each tick so the countdown actually moves
            return loc.parentalLockThrottle(secondsRemaining: Int(until.timeIntervalSinceNow.rounded(.up)))
        }
        return message
    }

    private func submit() async {
        let pin = entry
        guard ParentalLockPolicy.isValidPIN(pin) else {
            message = loc.localized("privacy.lock.enroll.invalid")
            entry = ""
            return
        }
        let verdict = await lock.verify(pin: pin)
        entry = ""
        switch verdict {
        case .unlocked:
            message = nil
        case .wrong(_, let attemptsLeft):
            message = attemptsLeft > 0
                ? loc.parentalLockAttemptsLeft(attemptsLeft)
                : loc.localized("privacy.lock.wrong")
            Haptics.error()
        case .throttled:
            message = nil   // `statusMessage` renders the countdown instead
        }
    }

    #if os(iOS)
    private func tryBiometrics() async {
        let reason = loc.localized("privacy.lock.unlock.reason")
        if await lock.unlockWithBiometrics(reason: reason) {
            message = nil
        }
    }
    #endif
}

// MARK: - Enrolment

/// Two-step PIN enrolment (choose, then confirm), rendered IN PLACE inside the
/// Privacy screen rather than as a nested sheet — raising a presentation from
/// inside one is the documented hazard, and on tvOS a second full-screen cover
/// would bring its own chrome and focus contract for two pad screens.
struct ParentalLockEnrollView: View {
    @Environment(ParentalLockController.self) private var lock
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    /// `true` once a PIN is in place (or the user cancelled — the caller only
    /// needs to know the flow is over).
    let onFinish: (Bool) -> Void

    @State private var first = ""
    @State private var entry = ""
    @State private var message: String?
    @State private var isSaving = false

    private var isConfirming: Bool { !first.isEmpty }

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Text(loc.localized(isConfirming ? "privacy.lock.enroll.confirm" : "privacy.lock.enroll.title"))
                .font(CinemaFont.headline(.large))
                .foregroundStyle(CinemaColor.onSurface)

            Text(loc.localized("privacy.lock.enroll.hint"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)

            ParentalPINDots(count: entry.count)

            if let message {
                Text(message)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.error)
                    .multilineTextAlignment(.center)
            }

            ParentalPINPad(
                entry: $entry,
                isDisabled: isSaving,
                onSubmit: { Task { await advance() } }
            )

            CinemaButton(title: loc.localized("action.cancel"), style: .ghost) {
                onFinish(false)
            }
            #if os(tvOS)
            .frame(width: CinemaTVLayout.ctaWidth)
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CinemaSpacing.spacing6)
    }

    private func advance() async {
        guard ParentalLockPolicy.isValidPIN(entry) else {
            message = loc.localized("privacy.lock.enroll.invalid")
            entry = ""
            return
        }
        guard isConfirming else {
            first = entry
            entry = ""
            message = nil
            return
        }
        guard entry == first else {
            // Restart from the first step: keeping the original and only
            // clearing the confirmation lets a typo in step ONE be confirmed
            // forever without the user ever seeing it.
            message = loc.localized("privacy.lock.enroll.mismatch")
            first = ""
            entry = ""
            return
        }
        isSaving = true
        // Face ID / Touch ID on by default where the device has it: it is a
        // shortcut past the PIN, the PIN stays valid, and the row below lets the
        // parent turn it off. tvOS has no sensor, so this resolves to `false`.
        let ok = await lock.enroll(pin: entry, useBiometrics: ParentalLockController.biometricsAvailable)
        isSaving = false
        entry = ""
        first = ""
        if ok {
            onFinish(true)
        } else {
            message = loc.localized("privacy.lock.enroll.failed")
        }
    }
}

// MARK: - Dots

/// Entered-digit indicator. Shows at least `minPINLength` slots so the required
/// length is legible before anything is typed, and grows with a longer PIN.
private struct ParentalPINDots: View {
    @Environment(ThemeManager.self) private var themeManager
    let count: Int

    var body: some View {
        let slots = max(count, ParentalLockPolicy.minPINLength)
        HStack(spacing: CinemaSpacing.spacing2) {
            ForEach(0..<slots, id: \.self) { index in
                Circle()
                    .fill(index < count ? themeManager.accent : CinemaColor.surfaceContainerHighest)
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(count)"))
        .accessibilityHint(Text(verbatim: ""))
    }

    private var dotSize: CGFloat {
        #if os(tvOS)
        20
        #else
        12
        #endif
    }
}

// MARK: - Pad

/// Ten-key numeric pad, shared by the unlock and enrolment screens.
///
/// A custom pad rather than a `SecureField` on both platforms: on tvOS a
/// `TextField` is drawn by the system as an unstylable white capsule and raises
/// a full-screen keyboard driven from a remote (the documented reason the Watch
/// Together sheet dropped its name field), and on iOS one pad keeps the two
/// platforms on a single implementation with the dot row always visible above
/// the keys instead of behind a software keyboard.
struct ParentalPINPad: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.motionEffectsEnabled) private var motionEffects

    @Binding var entry: String
    let isDisabled: Bool
    let onSubmit: () -> Void

    private enum Key: Hashable {
        case digit(Int)
        case delete
        case submit
    }

    #if os(tvOS)
    @FocusState private var focusedKey: Key?
    #endif

    var body: some View {
        VStack(spacing: keySpacing) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: keySpacing) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
        .disabled(isDisabled)
        #if os(tvOS)
        // The pad is a self-contained block of focusables inside a scrolling
        // page; without this, a left/right press at its edge walks out of the
        // pad instead of moving between keys.
        .focusSection()
        #endif
    }

    private var rows: [[Key]] {
        [
            [.digit(1), .digit(2), .digit(3)],
            [.digit(4), .digit(5), .digit(6)],
            [.digit(7), .digit(8), .digit(9)],
            [.delete, .digit(0), .submit]
        ]
    }

    @ViewBuilder
    private func keyButton(_ key: Key) -> some View {
        Button {
            press(key)
        } label: {
            keyLabel(key)
                .frame(width: keySize, height: keySize)
                #if os(tvOS)
                .tvSettingsFocusable(
                    isFocused: focusedKey == key,
                    accent: themeManager.accent,
                    animated: motionEffects,
                    colorScheme: themeManager.darkModeEnabled ? .dark : .light
                )
                #else
                .background(
                    Circle().fill(CinemaColor.surfaceContainerHigh)
                )
                .contentShape(Circle())
                #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(key))
        #if os(tvOS)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedKey, equals: key)
        #endif
    }

    @ViewBuilder
    private func keyLabel(_ key: Key) -> some View {
        switch key {
        case .digit(let value):
            Text(verbatim: "\(value)")
                .font(.system(size: CinemaScale.pt(digitFontSize), weight: .semibold))
                .foregroundStyle(CinemaColor.onSurface)
        case .delete:
            Image(systemName: "delete.left")
                .font(.system(size: CinemaScale.pt(glyphFontSize), weight: .semibold))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        case .submit:
            Image(systemName: "checkmark")
                .font(.system(size: CinemaScale.pt(glyphFontSize), weight: .bold))
                .foregroundStyle(canSubmit ? themeManager.accent : CinemaColor.outlineVariant)
        }
    }

    private var canSubmit: Bool { entry.count >= ParentalLockPolicy.minPINLength }

    private func press(_ key: Key) {
        switch key {
        case .digit(let value):
            guard entry.count < ParentalLockPolicy.maxPINLength else { return }
            entry.append(String(value))
            Haptics.tap()
        case .delete:
            guard !entry.isEmpty else { return }
            entry.removeLast()
            Haptics.tap()
        case .submit:
            guard canSubmit else { return }
            onSubmit()
        }
    }

    private func accessibilityLabel(_ key: Key) -> String {
        switch key {
        case .digit(let value): return "\(value)"
        case .delete:           return loc.localized("privacy.lock.pad.delete")
        case .submit:           return loc.localized("privacy.lock.pad.submit")
        }
    }

    private var keySize: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pinKeySize
        #else
        66
        #endif
    }

    private var keySpacing: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing3
        #else
        CinemaSpacing.spacing2
        #endif
    }

    private var digitFontSize: CGFloat {
        #if os(tvOS)
        30
        #else
        24
        #endif
    }

    private var glyphFontSize: CGFloat {
        #if os(tvOS)
        26
        #else
        20
        #endif
    }
}
