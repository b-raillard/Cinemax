import SwiftUI

/// « Gratuit » / « Pro — <source> » — the Debug row's value, shared by both
/// platforms.
@MainActor
func entitlementStatusText(_ state: EntitlementState, loc: LocalizationManager) -> String {
    switch state {
    case .free:
        return loc.localized("settings.debug.entitlement.free")
    case .pro(let source):
        let sourceKey = switch source {
        case .purchase: "settings.debug.entitlement.source.purchase"
        case .cloudMirror: "settings.debug.entitlement.source.cloudMirror"
        case .debugOverride: "settings.debug.entitlement.source.debugOverride"
        }
        return loc.localized("settings.debug.entitlement.pro", loc.localized(sourceKey))
    }
}

#if os(iOS)
/// Settings → Lecture → Débogage (iOS): the read-only « Droits » row, plus the
/// « Simuler Pro » switch in DEBUG builds.
///
/// A standalone `View` with its own `@Environment`, like `DiagnosticsExportRows`:
/// the Playback page is pushed through `navigationDestination`, where only a
/// standalone view re-renders on an `@Observable` change (root iOS
/// `NavigationStack` RULE) — the switch would otherwise look dead.
struct EntitlementDebugRows: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(LocalizationManager.self) private var loc
    #if DEBUG
    @Environment(\.motionEffectsEnabled) private var motionEffects
    #endif

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            #if DEBUG
            iOSSettingsDivider
            // Custom Binding: the write goes through the store's mutator,
            // never a property setter (`@Observable` RULE).
            iOSToggleRow(
                icon: "crown.fill",
                label: loc.localized("settings.debug.simulatePro"),
                value: Binding(
                    get: { entitlements.debugOverride },
                    set: { entitlements.setDebugOverride($0) }
                ),
                accent: .orange,
                animated: motionEffects,
                loc: loc
            )
            #endif
        }
    }

    private var statusRow: some View {
        iOSSettingsRow {
            HStack {
                iOSRowIcon(systemName: "crown", color: .orange)
                Text(loc.localized("settings.debug.entitlement"))
                    .font(CinemaFont.dynamicLabel(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Text(entitlementStatusText(entitlements.state, loc: loc))
                    .font(CinemaFont.dynamicLabel(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
