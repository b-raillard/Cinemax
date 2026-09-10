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
