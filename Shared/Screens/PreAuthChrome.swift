import SwiftUI
import CinemaxKit

// Chrome shared by the two pre-auth screens. `ServerSetupScreen` and
// `LoginScreen` are deliberately one journey (pick a server, then sign in) and
// are both reused verbatim to ADD a server, so their furniture was written
// twice, byte for byte: an error banner, a helper link and the accent easter
// egg behind the header icon. Three copies of the same thing is how two screens
// that must look like one page drift apart — the focus treatment below, for
// instance, was added to one copy first.
//
// Nothing here is specific to either screen; anything that IS (the four shapes
// of `LoginScreen`'s escape hatch, `ServerSetupScreen`'s status pill) stays at
// home.

/// The inline error line both pre-auth screens show under their form.
struct PreAuthErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(CinemaColor.error)
            Text(message)
                .font(CinemaFont.label(.small))
                .foregroundStyle(CinemaColor.error)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.medium)
                .fill(CinemaColor.errorContainer.opacity(0.2))
        )
    }
}

/// A secondary text+glyph action under a pre-auth form: Quick Connect, network
/// discovery, "how do I find my server?", the servers list, and every escape
/// hatch out of an add-a-server flow.
struct PreAuthHelperLink: View {
    @Environment(ThemeManager.self) private var themeManager
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(CinemaFont.label(.medium))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            #if os(tvOS)
            // « Pastille » focus level: a capsule carrying the shared chip
            // stroke. A bare `.plain` link had no focus treatment at all, and
            // this is the Quick Connect / discovery / servers-list entry.
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(CinemaColor.surfaceContainer)
            .clipShape(Capsule())
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        #else
        .buttonStyle(.plain)
        #endif
    }
}

/// The accent-cycling easter egg behind both pre-auth headers' icon block.
///
/// Takes `Binding`s rather than reading the state itself: the tap count is
/// per-screen `@State` and the unlock flag is `@AppStorage`, and both must keep
/// living on the screen so a trip through the other one doesn't reset the run.
/// `AccentEasterEgg.tap` stays the pure resolver; this is only the side effects
/// (persist, haptic, toast) that used to be duplicated.
enum PreAuthEasterEgg {
    @MainActor
    static func tap(
        tapCount: Binding<Int>,
        rainbowUnlocked: Binding<Bool>,
        themeManager: ThemeManager,
        toasts: ToastCenter,
        loc: LocalizationManager
    ) {
        let result = AccentEasterEgg.tap(
            currentAccentKey: themeManager.accentColorKey,
            previousTapCount: tapCount.wrappedValue,
            rainbowAlreadyUnlocked: rainbowUnlocked.wrappedValue
        )
        tapCount.wrappedValue += 1
        themeManager.accentColorKey = result.nextAccentKey
        if result.unlockedRainbow {
            rainbowUnlocked.wrappedValue = true
            Haptics.success()
            toasts.success(
                loc.localized("easterEgg.rainbow.title"),
                message: loc.localized("easterEgg.rainbow.message")
            )
        } else {
            Haptics.tap()
        }
    }
}

/// The app's language, pickable BEFORE signing in — the server screen is the
/// first thing somebody sees after the onboarding, and a fresh install guesses
/// its language from the device (`AppLanguage`), which may be the wrong one.
///
/// iOS: a compact « 🌐 FR » capsule opening a `Menu`, top trailing — out of the
/// form's way, where a language switch is expected. tvOS: a row of chips, one
/// per language, under the helper links — a `Menu` hides its choices behind a
/// press on a remote, and a corner control is the hardest place to reach with
/// the focus engine. Both write `loc.languageCode`, the same mutator as
/// Réglages → Apparence.
struct PreAuthLanguagePicker: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        #if os(tvOS)
        HStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: "globe")
                .font(.system(size: CinemaScale.pt(20), weight: .medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .accessibilityHidden(true)
            ForEach(AppLanguage.supported, id: \.self) { code in
                chip(code)
            }
        }
        .focusSection()
        #else
        Menu {
            ForEach(AppLanguage.supported, id: \.self) { code in
                Button {
                    loc.languageCode = code
                } label: {
                    if code == loc.languageCode {
                        Label(loc.localized(AppLanguage.nameKey(code)), systemImage: "checkmark")
                    } else {
                        Text(loc.localized(AppLanguage.nameKey(code)))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(loc.languageCode.uppercased())
            }
            .font(CinemaFont.label(.medium))
            .foregroundStyle(CinemaColor.onSurface)
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(CinemaColor.surfaceContainerHigh, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // « FR » read aloud is two letters, not a language.
        .accessibilityLabel(loc.localized("settings.language"))
        .accessibilityValue(loc.localized(AppLanguage.nameKey(loc.languageCode)))
        #endif
    }

    #if os(tvOS)
    private func chip(_ code: String) -> some View {
        let isSelected = loc.languageCode == code
        return Button {
            loc.languageCode = code
        } label: {
            Text(loc.localized(AppLanguage.nameKey(code)))
                .font(.system(size: CinemaScale.pt(18), weight: isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurface)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(isSelected ? themeManager.accent : CinemaColor.surfaceContainerHigh)
                .clipShape(Capsule())
        }
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    #endif
}
