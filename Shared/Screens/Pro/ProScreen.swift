import SwiftUI

/// « JellyGlass Pro » — Réglages' first entry (stories PRO-01…07, spec R7).
/// What Pro adds, what stays free, and by tier: the purchase (free), the
/// thank-you (founder), « Pro est actif » (Pro). « Restaurer les achats » is
/// on screen in every tier (App Review requires it).
///
/// iOS: pushed from the Settings landing. tvOS: the body of the « JellyGlass
/// Pro » settings detail (inside `tvDetailView`'s scroll view and back button).
/// RULE: never shown at launch, never re-offered on its own (spec R9).
struct ProScreen: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(EarlyAdopterService.self) private var earlyAdopter
    @Environment(ProStore.self) private var proStore
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(ToastCenter.self) private var toasts

    /// Apple's standard licensed-application EULA, and the app's privacy page
    /// (the one App Store Connect lists — `docs/app-store-metadata.md`).
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    static let privacyURL = URL(string: "https://b-raillard.github.io/Cinemax/privacy.html")

    private var tier: ProTier { entitlements.proTier(earlyAdopter: earlyAdopter) }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        iOSBody
        #endif
    }

    // MARK: - Shared pieces

    private var headline: String {
        switch tier {
        case .free: loc.localized("pro.headline.free")
        case .founder: loc.localized("pro.headline.founder")
        case .pro: loc.localized("pro.headline.pro")
        }
    }

    private var kicker: some View {
        Text(loc.localized("pro.kicker"))
            .font(CinemaFont.dynamicLabel(.medium))
            .tracking(1.6)
            .foregroundStyle(themeManager.accent)
    }

    private var alwaysFreeCard: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Text(loc.localized("pro.alwaysFree.title"))
                .font(CinemaFont.dynamicHeadline())
                .foregroundStyle(CinemaColor.onSurface)
            Text(loc.localized("pro.alwaysFree.body"))
                .font(CinemaFont.dynamicBody)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CinemaSpacing.spacing4)
        .background(CinemaColor.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var tierBlock: some View {
        switch tier {
        case .free:
            ProPurchaseBlock()
        case .founder:
            ProNoticeCard(text: loc.localized("pro.founder.card"), systemImage: "star")
        case .pro:
            Label(loc.localized("pro.active"), systemImage: "checkmark.circle.fill")
                .font(CinemaFont.dynamicHeadline())
                .foregroundStyle(CinemaColor.success)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(CinemaColor.success.opacity(0.14))
                .clipShape(Capsule())
        }
    }

    private func restore() {
        Task {
            switch await proStore.restore() {
            case .restored: toasts.success(loc.localized("pro.restore.found"))
            case .nothingFound: toasts.info(loc.localized("pro.restore.none"))
            case .failed: toasts.error(loc.localized("pro.restore.failed"))
            case .cancelled: break
            }
        }
    }

    // MARK: - iOS

    #if !os(tvOS)
    private var iOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                    kicker
                    Text(headline)
                        .font(CinemaFont.dynamicSystem(30, weight: .heavy, relativeTo: .largeTitle))
                        .foregroundStyle(CinemaColor.onSurface)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(loc.localized(tier == .free ? "pro.subline.free" : "pro.subline.unlocked"))
                        .font(CinemaFont.dynamicBody)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if tier == .founder { tierBlock }

                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    ForEach(ProFeatureCatalogue.features) { feature in
                        featureRow(feature)
                    }
                }

                alwaysFreeCard

                if tier != .founder { tierBlock }

                iOSLinks
            }
            .padding(.horizontal, CinemaSpacing.spacing5)
            .padding(.vertical, CinemaSpacing.spacing4)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("settings.pro"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func featureRow(_ feature: ProFeatureCatalogue.Feature) -> some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
            Image(systemName: feature.icon)
                .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                .foregroundStyle(themeManager.accent)
                .frame(width: 36, height: 36)
                .background(themeManager.accent.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.localized(feature.titleKey))
                    .font(CinemaFont.dynamicSystem(16, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(CinemaColor.onSurface)
                Text(loc.localized(feature.detailKey))
                    .font(CinemaFont.dynamicLabel(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var iOSLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CinemaSpacing.spacing5) { linkItems }
            VStack(spacing: CinemaSpacing.spacing3) { linkItems }
        }
        .font(CinemaFont.dynamicLabel(.large))
        .frame(maxWidth: .infinity)
        .padding(.top, CinemaSpacing.spacing2)
    }

    @ViewBuilder
    private var linkItems: some View {
        Button(loc.localized("pro.restore"), action: restore)
            .disabled(proStore.isRestoring)
        if let terms = Self.termsURL {
            Link(loc.localized("pro.terms"), destination: terms)
        }
        if let privacy = Self.privacyURL {
            Link(loc.localized("pro.privacy"), destination: privacy)
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing10) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                kicker
                Text(headline)
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                    ForEach(ProFeatureCatalogue.features) { feature in
                        Label(loc.localized(feature.titleKey), systemImage: "checkmark")
                            .font(CinemaFont.bodyLarge)
                            .foregroundStyle(CinemaColor.onSurface)
                    }
                }
                Text(loc.localized("pro.alwaysFree.tv"))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                tierBlock
                if tier == .free {
                    Text(loc.localized("pro.tv.storeNote"))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                CinemaButton(title: loc.localized("pro.restore"), style: .ghost, isLoading: proStore.isRestoring, action: restore)
                Text(loc.localized("pro.tv.legal"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 560)
            .padding(CinemaSpacing.spacing6)
            .background(CinemaColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.extraLarge))
            .focusSection()
        }
    }
    #endif
}

/// The Settings landing's Pro entry on iOS — a banner card rather than a
/// category pill (mockup « Achat Pro »). A standalone view: it reads the tier
/// and the price live.
struct ProSettingsBanner: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(EarlyAdopterService.self) private var earlyAdopter
    @Environment(ProStore.self) private var proStore
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    let action: () -> Void

    private var tier: ProTier { entitlements.proTier(earlyAdopter: earlyAdopter) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                HStack {
                    Text(loc.localized("pro.kicker"))
                        .font(CinemaFont.dynamicLabel(.small))
                        .tracking(1.6)
                        .foregroundStyle(tier == .pro ? CinemaColor.success : themeManager.accent)
                    Spacer()
                    Text(pill)
                        .font(CinemaFont.dynamicLabel(.small))
                        .foregroundStyle(tier == .pro ? CinemaColor.surface : themeManager.onAccentContainer)
                        .padding(.horizontal, CinemaSpacing.spacing2)
                        .padding(.vertical, 4)
                        .background(tier == .pro ? CinemaColor.success : themeManager.accentContainer)
                        .clipShape(Capsule())
                }
                Text(loc.localized(titleKey))
                    .font(CinemaFont.dynamicSystem(20, weight: .heavy, relativeTo: .title3))
                    .foregroundStyle(CinemaColor.onSurface)
                    .multilineTextAlignment(.leading)
                Text(loc.localized(textKey))
                    .font(CinemaFont.dynamicLabel(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(CinemaSpacing.spacing4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tier == .pro ? CinemaColor.success : themeManager.accent).opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.extraLarge))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task { if tier == .free, proStore.product == nil { await proStore.loadProduct() } }
    }

    private var pill: String {
        switch tier {
        case .free: proStore.product?.displayPrice ?? loc.localized("pro.badge")
        case .founder: loc.localized("pro.banner.pill.founder")
        case .pro: loc.localized("pro.banner.pill.pro")
        }
    }

    private var titleKey: String {
        switch tier {
        case .free: "pro.banner.free.title"
        case .founder: "pro.banner.founder.title"
        case .pro: "pro.banner.pro.title"
        }
    }

    private var textKey: String {
        switch tier {
        case .free: "pro.banner.free.text"
        case .founder: "pro.banner.founder.text"
        case .pro: "pro.banner.pro.text"
        }
    }
}
