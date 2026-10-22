import SwiftUI

/// The contextual sheet of ONE locked feature (story PRO-03): what it does,
/// the purchase, « Voir tout ce que Pro inclut », « Pas maintenant ». Opened
/// only when the user reaches for a Pro feature — a tap on an entry marked
/// PRO, on « Lire sur… », or a Siri / Raccourcis run (`ProFeatureAccess.admit`)
/// — never on its own (spec R9), never on a playback path.
///
/// Presented from places that do not inherit the root's environment (a
/// popover, a settings sheet): every presenter re-injects `EntitlementStore`,
/// `EarlyAdopterService`, `ProStore`, `LocalizationManager`, `ThemeManager`
/// and `ToastCenter`.
struct ProUpsellSheet: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    let feature: ProFeatureID
    @State private var showAll = false

    var body: some View {
        #if os(tvOS)
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            if showAll {
                ScrollView {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                        CinemaButton(title: loc.localized("action.back"), style: .ghost) { showAll = false }
                            .frame(width: CinemaTVLayout.ctaWidth)
                        ProScreen(hostsResultAlert: false)
                    }
                    .padding(.horizontal, CinemaTVLayout.pagePadding)
                    .padding(.vertical, CinemaSpacing.spacing8)
                }
                .scrollClipDisabled()
            } else {
                content
                    .frame(width: 760)
            }
        }
        .onExitCommand { if showAll { showAll = false } else { dismiss() } }
        .proPurchaseResultAlert { dismiss() }
        #else
        NavigationStack {
            ScrollView { content.padding(CinemaSpacing.spacing5) }
                .background(CinemaColor.surface.ignoresSafeArea())
                .navigationDestination(isPresented: $showAll) { ProScreen(hostsResultAlert: false) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(loc.localized("pro.upsell.notNow"))
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .proPurchaseResultAlert { dismiss() }
        #endif
    }

    private var content: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Image(systemName: catalogueFeature?.icon ?? "lock")
                .font(.system(size: CinemaScale.pt(28), weight: .semibold))
                .foregroundStyle(themeManager.accent)
                .frame(width: 64, height: 64)
                .background(themeManager.accent.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
                .accessibilityHidden(true)
            Text(catalogueFeature.map { loc.localized($0.shownTitleKey) } ?? loc.localized("settings.pro"))
                .font(CinemaFont.dynamicHeadline(.medium))
                .foregroundStyle(CinemaColor.onSurface)
                .multilineTextAlignment(.center)
            Text(description)
                .font(CinemaFont.dynamicBody)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ProPurchaseBlock()
            secondaryButton(loc.localized("pro.upsell.seeAll"), color: themeManager.accent) { showAll = true }
            secondaryButton(loc.localized("pro.upsell.notNow"), color: CinemaColor.onSurfaceVariant) { dismiss() }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private var catalogueFeature: ProFeatureCatalogue.Feature? {
        ProFeatureCatalogue.feature(feature)
    }

    private var description: String {
        let detail = catalogueFeature.map { loc.localized($0.shownDetailKey) } ?? ""
        return [detail, loc.localized("pro.upsell.partOf")].filter { !$0.isEmpty }.joined(separator: " ")
    }

    @ViewBuilder
    private func secondaryButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        CinemaButton(title: title, style: .ghost, action: action)
        #else
        Button(action: action) {
            Text(title)
                .font(CinemaFont.dynamicLabel(.large))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #endif
    }
}

/// Hosts the contextual sheet of a REFUSED gate at the root
/// (`ProFeatureAccess.upsell`, lot B): « Lire sur… », the Administration row
/// and the App Intents raise it from places that cannot present it
/// themselves — a context menu, a lazy grid, no scene at all. The stores are
/// re-injected, as every presenter of this sheet does.
struct ProUpsellPresentation: ViewModifier {
    @Binding var feature: ProFeatureID?
    let entitlements: EntitlementStore
    let earlyAdopter: EarlyAdopterService
    let proStore: ProStore
    let loc: LocalizationManager
    let themeManager: ThemeManager
    let toasts: ToastCenter

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.fullScreenCover(item: $feature) { sheet($0) }
        #else
        content.sheet(item: $feature) { sheet($0) }
        #endif
    }

    private func sheet(_ feature: ProFeatureID) -> some View {
        ProUpsellSheet(feature: feature)
            .environment(entitlements)
            .environment(earlyAdopter)
            .environment(proStore)
            .environment(loc)
            .environment(themeManager)
            .environment(toasts)
    }
}

/// The « Comptes mémorisés · PRO » entry the free account switch carries
/// (iOS switcher, Settings' plain sheet on both platforms): a tap opens the
/// contextual sheet. Free users only — the caller checks the tier.
struct ProLockedFeatureRow: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    let feature: ProFeatureID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CinemaSpacing.spacing3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(catalogueFeature.map { loc.localized($0.shownTitleKey) } ?? "")
                        .font(CinemaFont.dynamicSystem(16, weight: .semibold, relativeTo: .headline))
                        .foregroundStyle(themeManager.accent)
                    Text(catalogueFeature.map { loc.localized($0.shownDetailKey) } ?? "")
                        .font(CinemaFont.dynamicLabel(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: CinemaSpacing.spacing2)
                ProBadge()
            }
            .padding(CinemaSpacing.spacing3)
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        // A row (`CinemaRadius.large`), so the row level's rounded ring —
        // the chip style drew a capsule over it.
        .buttonStyle(TVFilterRowButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        #else
        .buttonStyle(.plain)
        #endif
    }

    private var catalogueFeature: ProFeatureCatalogue.Feature? {
        ProFeatureCatalogue.feature(feature)
    }
}
