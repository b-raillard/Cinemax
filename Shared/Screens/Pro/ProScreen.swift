import SwiftUI

/// « Votre niveau » / « JellyGlass Pro » (stories PRO-01…07, spec R7) — opened
/// by the chip under the Settings title (design D). Its head is the membership
/// card (design B); then what the tier includes, what stays free, and — for a
/// free user only — the purchase. « Restaurer les achats » is on screen in
/// every tier (App Review requires it).
///
/// iOS: pushed from the Settings landing. tvOS: the body of the `.pro`
/// settings detail (inside `tvDetailView`'s scroll view and back button).
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

    /// `false` when pushed inside the contextual sheet, which hosts the
    /// result alert itself (one host at a time).
    var hostsResultAlert = true

    private var tier: ProTier { entitlements.proTier(earlyAdopter: earlyAdopter) }

    var body: some View {
        if hostsResultAlert {
            platformBody.proPurchaseResultAlert()
        } else {
            platformBody
        }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(tvOS)
        tvBody
        #else
        iOSBody
        #endif
    }

    // MARK: - Shared pieces

    /// « Membre depuis juin 2026 » (founder: the first App Store install, of
    /// either app) / « Actif depuis février 2027 » (Pro: the purchase).
    private var since: String? {
        let date: Date?
        let key: String
        switch tier {
        case .founder:
            date = earlyAdopter.transaction?.originalPurchaseDate ?? earlyAdopter.otherPlatformTransaction?.originalPurchaseDate
            key = "pro.card.since.founder"
        case .pro:
            date = (entitlements.localRecord ?? entitlements.cloudRecord)?.purchaseDate
            key = "pro.card.since.pro"
        case .free:
            return nil
        }
        guard let date else { return nil }
        return loc.localized(key, date.formatted(.dateTime.month(.wide).year().locale(loc.locale)))
    }

    private var lead: String {
        switch tier {
        case .free: loc.localized("pro.subline.free")
        case .founder: loc.localized("pro.founder.card")
        case .pro: loc.localized("pro.subline.unlocked")
        }
    }

    private var listTitle: some View {
        Text(loc.localized(tier == .free ? "pro.list.withPro" : "pro.list.included"))
            .font(CinemaFont.dynamicLabel(.medium))
            .fontWeight(.heavy)
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(themeManager.accent)
            .accessibilityAddTraits(.isHeader)
    }

    private var alwaysFreeCard: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Text(loc.localized("pro.alwaysFree.title"))
                .font(CinemaFont.dynamicHeadline())
                .foregroundStyle(themeManager.accent)
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
                ProMembershipCard(tier: tier, since: since)

                Text(lead)
                    .font(CinemaFont.dynamicBody)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    listTitle
                    ForEach(ProFeatureCatalogue.features) { feature in
                        featureRow(feature)
                    }
                }

                alwaysFreeCard

                if tier == .free { ProPurchaseBlock() }

                iOSLinks
            }
            .padding(.horizontal, CinemaSpacing.spacing5)
            .padding(.vertical, CinemaSpacing.spacing4)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("pro.tier.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func featureRow(_ feature: ProFeatureCatalogue.Feature) -> some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
            Image(systemName: tier == .free ? "lock.fill" : feature.icon)
                .font(.system(size: CinemaScale.pt(tier == .free ? 14 : 17), weight: .semibold))
                .foregroundStyle(themeManager.accent)
                .frame(width: 36, height: 36)
                .background(themeManager.accent.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.localized(feature.titleKey))
                    .font(CinemaFont.dynamicSystem(16, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(themeManager.accent)
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
                ProMembershipCard(tier: tier, since: since)
                    .frame(maxWidth: 560)
                Text(lead)
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                listTitle
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                    ForEach(ProFeatureCatalogue.features) { feature in
                        HStack(spacing: CinemaSpacing.spacing3) {
                            Image(systemName: tier == .free ? "lock.fill" : "checkmark")
                                .foregroundStyle(themeManager.accent)
                                .accessibilityHidden(true)
                            Text(loc.localized(feature.titleKey))
                                .foregroundStyle(CinemaColor.onSurface)
                        }
                        .font(CinemaFont.bodyLarge)
                    }
                }
                Text(loc.localized("pro.alwaysFree.tv"))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                if tier == .free { ProPurchaseBlock() }
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
