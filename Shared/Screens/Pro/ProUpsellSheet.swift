import SwiftUI

/// The contextual sheet of ONE locked feature (story PRO-03): what it does,
/// the purchase, « Voir tout ce que Pro inclut », « Pas maintenant ». Opened
/// only by a tap on an entry marked PRO — never on its own (spec R9), never on
/// a playback path.
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
                        ProScreen()
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
        #else
        NavigationStack {
            ScrollView { content.padding(CinemaSpacing.spacing5) }
                .background(CinemaColor.surface.ignoresSafeArea())
                .navigationDestination(isPresented: $showAll) { ProScreen() }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(loc.localized("pro.upsell.notNow"))
                    }
                }
        }
        .presentationDetents([.medium, .large])
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
            Text(catalogueFeature.map { loc.localized($0.titleKey) } ?? loc.localized("settings.pro"))
                .font(CinemaFont.dynamicHeadline(.medium))
                .foregroundStyle(CinemaColor.onSurface)
                .multilineTextAlignment(.center)
            Text(description)
                .font(CinemaFont.dynamicBody)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ProPurchaseBlock { dismiss() }
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
        let detail = catalogueFeature.map { loc.localized($0.detailKey) } ?? ""
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
                    Text(catalogueFeature.map { loc.localized($0.titleKey) } ?? "")
                        .font(CinemaFont.dynamicSystem(16, weight: .semibold, relativeTo: .headline))
                        .foregroundStyle(CinemaColor.onSurface)
                    Text(catalogueFeature.map { loc.localized($0.detailKey) } ?? "")
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
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
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
