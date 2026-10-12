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

/// « Oui » / « Non » / « Inconnu » / « Environnement de test » — the « Early
/// adopter » Debug row's value, shared by both platforms. A forced status
/// reads « Oui (simulé) », a grant coming from the other app « Oui (via
/// l'autre app) ».
@MainActor
func earlyAdopterStatusText(_ service: EarlyAdopterService, loc: LocalizationManager) -> String {
    #if DEBUG
    if service.debugOverride != .automatic {
        let forced = loc.localized(service.isEarlyAdopter ? "settings.debug.earlyAdopter.yes" : "settings.debug.earlyAdopter.no")
        return loc.localized("settings.debug.earlyAdopter.simulated", forced)
    }
    #endif
    if service.status != .earlyAdopter, service.otherPlatformStatus == .earlyAdopter {
        return loc.localized("settings.debug.earlyAdopter.otherPlatform")
    }
    return switch service.status {
    case .earlyAdopter: loc.localized("settings.debug.earlyAdopter.yes")
    case .regular: loc.localized("settings.debug.earlyAdopter.no")
    case .unknown: loc.localized("settings.debug.earlyAdopter.unknown")
    case .nonProduction: loc.localized("settings.debug.earlyAdopter.nonProduction")
    }
}

/// What the App Store said, for checking a production build by eye: « build
/// 2.3.2 · 14/06/2026 · production », plus « Autre app : … » once the other
/// platform has published. `nil` until something is known. Display only —
/// the decision is `EarlyAdopterPolicy`'s.
@MainActor
func earlyAdopterFactsText(_ service: EarlyAdopterService, loc: LocalizationManager) -> String? {
    var lines: [String] = []
    if let own = service.transaction {
        lines.append(earlyAdopterFacts(own, loc: loc))
    }
    if let other = service.otherPlatformTransaction {
        lines.append(loc.localized("settings.debug.earlyAdopter.otherApp", earlyAdopterFacts(other, loc: loc)))
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

@MainActor
private func earlyAdopterFacts(_ transaction: AppTransactionSnapshot, loc: LocalizationManager) -> String {
    let date = transaction.originalPurchaseDate
        .formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(loc.locale))
    let environment = switch transaction.environment {
    case .production: loc.localized("settings.debug.earlyAdopter.env.production")
    case .sandbox: loc.localized("settings.debug.earlyAdopter.env.sandbox")
    case .xcode: loc.localized("settings.debug.earlyAdopter.env.xcode")
    }
    return loc.localized("settings.debug.earlyAdopter.facts", transaction.originalAppVersion, date, environment)
}

/// « Automatique (Fondateur) » / « Gratuit » / « Pro » / « Fondateur » — the
/// « Palier simulé » Debug row's value: the forced tier, or the real one in
/// parentheses while nothing is forced.
@MainActor
func proTierText(_ entitlements: EntitlementStore, earlyAdopter: EarlyAdopterService, loc: LocalizationManager) -> String {
    let tier = entitlements.proTier(earlyAdopter: earlyAdopter)
    let tierText = switch tier {
    case .free: loc.localized("settings.debug.proTier.free")
    case .pro: loc.localized("settings.debug.proTier.pro")
    case .founder: loc.localized("settings.debug.proTier.founder")
    }
    #if DEBUG
    if entitlements.proTierOverride == .automatic {
        return loc.localized("settings.debug.proTier.automatic", tierText)
    }
    #endif
    return tierText
}

/// The « Early adopter » row's press. DEBUG: cycles the override (automatic →
/// early adopter → regular). Release: asks the App Store again — a tap is the
/// user-triggered path `AppTransaction` is allowed on.
@MainActor
func earlyAdopterRowAction(_ service: EarlyAdopterService) {
    #if DEBUG
    service.setDebugOverride(service.debugOverride.next)
    #else
    Task { await service.evaluate() }
    #endif
}

#if os(iOS)
/// Settings → Lecture → Débogage (iOS): the read-only « Droits » row, the
/// « Simuler Pro » switch in DEBUG builds, then the « Early adopter » row.
///
/// A standalone `View` with its own `@Environment`, like `DiagnosticsExportRows`:
/// the Playback page is pushed through `navigationDestination`, where only a
/// standalone view re-renders on an `@Observable` change (root iOS
/// `NavigationStack` RULE) — the switch would otherwise look dead.
struct EntitlementDebugRows: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(EarlyAdopterService.self) private var earlyAdopter
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            iOSSettingsDivider
            earlyAdopterRow
            #if DEBUG
            iOSSettingsDivider
            proTierRow
            #endif
        }
    }

    #if DEBUG
    /// Free / Pro / founder, forced — what the Pro features (multi-account)
    /// see. A press cycles automatic → free → Pro → founder.
    private var proTierRow: some View {
        Button {
            entitlements.setProTierOverride(entitlements.proTierOverride.next)
        } label: {
            iOSSettingsRow {
                SettingsRowAdaptiveLayout {
                    HStack {
                        iOSRowIcon(systemName: "person.2.badge.key", color: .orange)
                        Text(loc.localized("settings.debug.proTier"))
                            .font(CinemaFont.dynamicLabel(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                    }
                } control: {
                    Text(proTierText(entitlements, earlyAdopter: earlyAdopter, loc: loc))
                        .font(CinemaFont.dynamicLabel(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
    #endif

    private var earlyAdopterRow: some View {
        Button {
            earlyAdopterRowAction(earlyAdopter)
        } label: {
            iOSSettingsRow {
                // Adaptive like every other settings row: side by side, the
                // value took half the row and German words broke mid-word at
                // the accessibility sizes (« Berechtigun/gen », recette 2026-10-02).
                SettingsRowAdaptiveLayout {
                    HStack {
                        iOSRowIcon(systemName: "star.circle", color: .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc.localized("settings.debug.earlyAdopter"))
                                .font(CinemaFont.dynamicLabel(.large))
                                .foregroundStyle(CinemaColor.onSurface)
                            if let facts = earlyAdopterFactsText(earlyAdopter, loc: loc) {
                                Text(facts)
                                    .font(CinemaFont.dynamicLabel(.small))
                                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                            }
                        }
                    }
                } control: {
                    Text(earlyAdopterStatusText(earlyAdopter, loc: loc))
                        .font(CinemaFont.dynamicLabel(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var statusRow: some View {
        iOSSettingsRow {
            SettingsRowAdaptiveLayout {
                HStack {
                    iOSRowIcon(systemName: "crown", color: .orange)
                    Text(loc.localized("settings.debug.entitlement"))
                        .font(CinemaFont.dynamicLabel(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                }
            } control: {
                Text(entitlementStatusText(entitlements.state, loc: loc))
                    .font(CinemaFont.dynamicLabel(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
