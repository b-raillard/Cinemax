import SwiftUI

/// The texts of the Pro page (design C), listed for `pageKeysExistInEveryLanguage`.
enum ProScreenText {
    static let keys = [
        "pro.compare.eyebrow", "pro.compare.title", "pro.compare.subtitle", "pro.compare.you",
        "pro.compare.alwaysFree", "pro.compare.included", "pro.compare.notIncluded",
        "pro.compare.column.accessibility", "pro.list.withPro",
        "pro.panel.title.free", "pro.panel.line.free", "pro.price.once", "pro.buy.short", "pro.buy",
        "pro.perk.noSubscription", "pro.perk.family", "pro.perk.devices",
        "pro.restore", "pro.terms", "pro.privacy", "pro.tv.legal",
        "pro.tier.title", "pro.tier.free", "pro.tier.pro", "pro.tier.founder",
        "pro.card.line.founder", "pro.card.line.pro", "pro.card.since.founder", "pro.card.since.pro"
    ]
}

/// « Votre niveau » / « JellyGlass Pro » (stories PRO-01…07, spec R7) — opened
/// by the chip under the Settings title. Design C (chosen 2026-10-24): « Ce que
/// Pro ajoute », a Gratuit / Pro table, and a purchase panel — the same three
/// pieces on iPhone, iPad and Apple TV (`ProComparisonViews.swift`).
/// « Restaurer les achats » is on screen in every tier (App Review requires it).
///
/// iOS: pushed from the Settings landing. tvOS: the body of the `.pro`
/// settings detail (inside `tvDetailView`'s scroll view and back button),
/// over the tier's material.
/// RULE: never shown at launch, never re-offered on its own (spec R9).
struct ProScreen: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(EarlyAdopterService.self) private var earlyAdopter
    @Environment(ProStore.self) private var proStore
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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

    private func panel(_ metrics: ProPageMetrics) -> some View {
        ProTierPanel(tier: tier, since: since, metrics: metrics, onRestore: restore)
    }

    // MARK: - iOS

    #if !os(tvOS)
    private var isCompact: Bool { horizontalSizeClass != .regular }

    /// The purchase bar of a compact width: a free user, a price to show, and
    /// no « Demander à acheter » request pending.
    private var barProduct: ProductSnapshot? {
        guard isCompact, tier == .free, !proStore.isPending else { return nil }
        return proStore.product
    }

    private var iOSBody: some View {
        let metrics = ProPageMetrics.iOS(compact: isCompact)
        return ScrollView {
            // Side by side when both fit (iPad landscape), the panel beside
            // the heading and the table; stacked otherwise, the table first,
            // so what the purchase contains is what the user sees.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                        ProCompareHeading(tier: tier, metrics: metrics)
                        ProComparisonTable(tier: tier, metrics: metrics)
                    }
                    .frame(minWidth: 460, idealWidth: 460, maxWidth: .infinity)
                    panel(metrics)
                        .frame(width: 340)
                }
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    ProCompareHeading(tier: tier, metrics: metrics)
                    ProComparisonTable(tier: tier, metrics: metrics)
                    panel(metrics)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing5)
            .padding(.vertical, CinemaSpacing.spacing4)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if let product = barProduct {
                ProPurchaseBar(product: product)
            }
        }
        .navigationTitle(loc.localized("pro.tier.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    /// The heading and the table, the panel beside them, on one screen. The
    /// row is ONE focus section the width of the page: the table holds
    /// nothing focusable, so a press down from the back button (top-leading)
    /// must be handed to the panel's buttons on the right.
    private var tvBody: some View {
        let metrics = ProPageMetrics.tv
        // The panel starts level with the heading: under the table it ran off
        // the bottom of the screen.
        return HStack(alignment: .top, spacing: CinemaTVLayout.proPanelGap) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                ProCompareHeading(tier: tier, metrics: metrics)
                ProComparisonTable(tier: tier, metrics: metrics)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            panel(metrics)
                .frame(width: CinemaTVLayout.proPanelWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .environment(\.colorScheme, .dark)
    }
    #endif
}
