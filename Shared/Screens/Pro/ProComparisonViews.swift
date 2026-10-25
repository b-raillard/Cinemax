import SwiftUI

/// Design C of the Pro page (chosen by the product owner 2026-10-24, canvas
/// « Page JellyGlass Pro — 3 pistes »): a Gratuit / Pro table that shows, at a
/// glance, what playback keeps for free
/// and what the purchase adds — then a purchase panel. The same two pieces on
/// iPhone, iPad and Apple TV; only `ProPageMetrics` differs.

/// The sizes of the Pro page, per platform. iPhone / iPad type follows
/// Dynamic Type; the Apple TV's goes through `CinemaScale`.
struct ProPageMetrics {
    var columnWidth: CGFloat
    var rowMinHeight: CGFloat
    var rowPadding: CGFloat
    var gap: CGFloat
    var iconBox: CGFloat
    var radius: CGFloat
    var eyebrowFont: Font
    var titleFont: Font
    var subtitleFont: Font
    var headerFont: Font
    var pillFont: Font
    var groupFont: Font
    var rowTitleFont: Font
    var rowDetailFont: Font
    var iconFont: Font
    var markFont: Font
    var lockFont: Font
    var panelPadding: CGFloat
    var panelSpacing: CGFloat
    var panelRadius: CGFloat
    var panelTitleFont: Font
    var panelLineFont: Font
    var priceFont: Font
    var priceNoteFont: Font
    var perkFont: Font
    var legalFont: Font

    #if os(tvOS)
    /// Design E (chosen 2026-10-25): rows big enough to read from the couch,
    /// in a window that scrolls with focus (`ProComparisonTable.tvBody`).
    static let tv = Self(
        columnWidth: CinemaTVLayout.proCompareColumnWidth,
        rowMinHeight: 100, rowPadding: 12, gap: 22, iconBox: 52, radius: 22,
        eyebrowFont: .system(size: CinemaScale.pt(13), weight: .black),
        titleFont: .system(size: CinemaScale.pt(36), weight: .black),
        subtitleFont: .system(size: CinemaScale.pt(16), weight: .regular),
        headerFont: .system(size: CinemaScale.pt(19), weight: .heavy),
        pillFont: .system(size: CinemaScale.pt(10), weight: .black),
        groupFont: .system(size: CinemaScale.pt(14), weight: .black),
        rowTitleFont: .system(size: CinemaScale.pt(22), weight: .bold),
        rowDetailFont: .system(size: CinemaScale.pt(16), weight: .regular),
        iconFont: .system(size: CinemaScale.pt(20), weight: .semibold),
        markFont: .system(size: CinemaScale.pt(24), weight: .bold),
        lockFont: .system(size: CinemaScale.pt(19), weight: .semibold),
        panelPadding: 36, panelSpacing: 12, panelRadius: 36,
        panelTitleFont: .system(size: CinemaScale.pt(36), weight: .black),
        panelLineFont: .system(size: CinemaScale.pt(17), weight: .bold),
        priceFont: .system(size: CinemaScale.pt(44), weight: .black),
        priceNoteFont: .system(size: CinemaScale.pt(16), weight: .bold),
        perkFont: .system(size: CinemaScale.pt(15), weight: .semibold),
        legalFont: .system(size: CinemaScale.pt(11), weight: .regular)
    )
    #else
    static func iOS(compact: Bool) -> Self {
        Self(
            columnWidth: compact ? 58 : 118,
            rowMinHeight: 46, rowPadding: 7, gap: 10, iconBox: 28, radius: 14,
            eyebrowFont: CinemaFont.dynamicSystem(11, weight: .black, relativeTo: .caption2),
            titleFont: CinemaFont.dynamicSystem(compact ? 30 : 34, weight: .black, relativeTo: .largeTitle),
            subtitleFont: CinemaFont.dynamicSystem(15, weight: .regular, relativeTo: .subheadline),
            headerFont: CinemaFont.dynamicSystem(14, weight: .heavy, relativeTo: .subheadline),
            pillFont: CinemaFont.dynamicSystem(9, weight: .black, relativeTo: .caption2),
            groupFont: CinemaFont.dynamicSystem(10.5, weight: .black, relativeTo: .caption2),
            rowTitleFont: CinemaFont.dynamicSystem(14.5, weight: .bold, relativeTo: .subheadline),
            rowDetailFont: CinemaFont.dynamicSystem(12, weight: .regular, relativeTo: .footnote),
            iconFont: CinemaFont.dynamicSystem(13, weight: .semibold, relativeTo: .footnote),
            markFont: CinemaFont.dynamicSystem(16, weight: .bold, relativeTo: .body),
            lockFont: CinemaFont.dynamicSystem(12, weight: .semibold, relativeTo: .footnote),
            panelPadding: 22, panelSpacing: 9, panelRadius: 24,
            panelTitleFont: CinemaFont.dynamicSystem(32, weight: .black, relativeTo: .title1),
            panelLineFont: CinemaFont.dynamicSystem(14, weight: .bold, relativeTo: .subheadline),
            priceFont: CinemaFont.dynamicSystem(38, weight: .black, relativeTo: .title1),
            priceNoteFont: CinemaFont.dynamicSystem(13, weight: .bold, relativeTo: .footnote),
            perkFont: CinemaFont.dynamicSystem(13, weight: .semibold, relativeTo: .footnote),
            legalFont: CinemaFont.dynamicSystem(13, weight: .semibold, relativeTo: .footnote)
        )
    }
    #endif
}

/// The tier's colour on the page: gold for a founder, the accent otherwise.
@MainActor
struct ProPageInk {
    let tier: ProTier
    let themeManager: ThemeManager

    /// Text and marks in the Pro column (founder gold reads on both modes).
    var ink: Color { tier == .founder ? CinemaColor.founderGoldInk : themeManager.accent }
    /// The Pro column's tint.
    var tint: Color { tier == .founder ? CinemaColor.founderGold : themeManager.accent }
}

/// « Ce que Pro ajoute » + the line under it — the page's head on every
/// platform.
struct ProCompareHeading: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    let tier: ProTier
    let metrics: ProPageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap / 2) {
            // Not on the Apple TV: the panel beside it already wears the same
            // eyebrow, and the page must hold on one screen with seven sold
            // rows (« Reprendre ici », 2026-10-24).
            #if !os(tvOS)
            Text(loc.localized("pro.compare.eyebrow"))
                .font(metrics.eyebrowFont)
                .tracking(3)
                .textCase(.uppercase)
                .foregroundStyle(ProPageInk(tier: tier, themeManager: themeManager).ink)
            #endif
            Text(loc.localized("pro.compare.title"))
                .font(metrics.titleFont)
                .tracking(-0.6)
                .foregroundStyle(CinemaColor.onSurface)
                .accessibilityAddTraits(.isHeader)
            // Not on the Apple TV either: « Toujours gratuit » says it, and the
            // table's window needs the height (design E, 2026-10-25).
            #if !os(tvOS)
            Text(loc.localized("pro.compare.subtitle"))
                .font(metrics.subtitleFont)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }
}

/// The Gratuit / Pro table. Every row is an `HStack` of three cells, each
/// filling the row's height, so the Pro column's tint is one continuous band
/// (rounded at its two ends) with nothing laid over it.
struct ProComparisonTable: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    let tier: ProTier
    let metrics: ProPageMetrics
    /// Apple TV: Right from a line (the purchase panel beside the table).
    var onMoveRight: (() -> Void)?

    #if os(tvOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The focused line, as its index in the table (free lines first).
    @FocusState private var focusedLine: Int?
    /// Lines left under the window's bottom edge: the fade says so.
    @State private var moreBelow = true
    #endif

    private var palette: ProPageInk { ProPageInk(tier: tier, themeManager: themeManager) }
    private var features: [ProFeatureCatalogue.Feature] { ProFeatureCatalogue.features }

    /// One line of the table: the free rows, then the sold features.
    private struct Line {
        let icon: String
        let titleKey: String
        let detailKey: String
        let freeIncluded: Bool
    }

    private var freeLines: [Line] {
        ProFeatureCatalogue.alwaysFree.map {
            Line(icon: $0.icon, titleKey: $0.titleKey, detailKey: $0.shownRowKey, freeIncluded: true)
        }
    }

    private var proLines: [Line] {
        features.map {
            Line(icon: $0.icon, titleKey: $0.shownTitleKey, detailKey: $0.shownRowKey, freeIncluded: false)
        }
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        VStack(spacing: 0) {
            headerRow
            rows
        }
        #endif
    }

    private var rows: some View {
        let free = freeLines
        let sold = proLines
        return VStack(spacing: 0) {
            groupRow(loc.localized("pro.compare.alwaysFree"), color: CinemaColor.onSurfaceMuted)
            ForEach(free.indices, id: \.self) { index in
                line(free[index], index: index, isLast: false)
            }
            groupRow(loc.localized("pro.list.withPro"), color: palette.ink)
            ForEach(sold.indices, id: \.self) { index in
                line(sold[index], index: free.count + index, isLast: index == sold.count - 1)
            }
        }
    }

    #if os(tvOS)
    /// Design E: the header stays put, the lines scroll in a window under it
    /// as focus moves, and a fade at the window's foot — as long as lines are
    /// left below — says there is more. The fade is a MASK, not a gradient
    /// to a colour: the page's ground is the tier's material.
    private var tvBody: some View {
        let count = freeLines.count + proLines.count
        let fade = CinemaTVLayout.proTableFadeHeight
        return VStack(alignment: .leading, spacing: 0) {
            headerRow
            ScrollView(.vertical, showsIndicators: false) {
                rows
                    // Room for the focused line's stroke at the window's edges.
                    .padding(.vertical, CinemaTVFocus.strokeWidth)
            }
            // Focus scrolling keeps the focused line above the fade.
            .safeAreaPadding(.bottom, moreBelow ? fade * 0.6 : 0)
            .frame(height: CinemaTVLayout.proTableWindowHeight)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 4
            } action: { _, isMore in
                moreBelow = isMore
            }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: moreBelow ? fade : 0)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: moreBelow)
            }
            Text(browseHint(count: count))
                .font(metrics.groupFont)
                .foregroundStyle(CinemaColor.onSurfaceMuted)
                .padding(.top, CinemaSpacing.spacing2)
                .accessibilityHidden(true)
        }
    }

    /// « 3 / 9 · Haut et Bas pour parcourir » while a line holds focus.
    private func browseHint(count: Int) -> String {
        let hint = loc.localized("pro.tv.browse")
        guard let focusedLine else { return hint }
        return "\(loc.localized("pro.tv.position", focusedLine + 1, count)) · \(hint)"
    }
    #endif

    // MARK: Rows

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity)
            columnHeader(loc.localized("pro.tier.free"), isYours: tier == .free, isPro: false)
            columnHeader(loc.localized("pro.tier.pro"), isYours: tier != .free, isPro: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { separator }
        // The rows say both columns' answers; the header adds nothing to read.
        .accessibilityHidden(true)
    }

    private func columnHeader(_ name: String, isYours: Bool, isPro: Bool) -> some View {
        VStack(spacing: 4) {
            Text(name)
                .font(metrics.headerFont)
                .foregroundStyle(isPro ? palette.ink : CinemaColor.onSurfaceVariant)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if isYours { youPill }
        }
        .padding(.vertical, metrics.rowPadding + 4)
        .frame(width: metrics.columnWidth)
        .frame(maxHeight: .infinity)
        .background(isPro ? palette.tint.opacity(0.18) : .clear,
                    in: UnevenRoundedRectangle(topLeadingRadius: metrics.radius, topTrailingRadius: metrics.radius))
    }

    private var youPill: some View {
        let colors: (fill: Color, text: Color) = switch tier {
        case .free: (CinemaColor.onSurface, CinemaColor.surface)
        case .pro: (themeManager.accentContainer, themeManager.onAccentContainer)
        case .founder: (CinemaColor.founderGold, CinemaColor.onFounderGold)
        }
        return Text(loc.localized("pro.compare.you"))
            .font(metrics.pillFont)
            .tracking(0.8)
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(colors.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(colors.fill, in: Capsule())
    }

    private func groupRow(_ label: String, color: Color) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(metrics.groupFont)
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, metrics.rowPadding + 6)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            Color.clear.frame(width: metrics.columnWidth)
            palette.tint.opacity(0.10).frame(width: metrics.columnWidth)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { separator }
    }

    private func line(_ line: Line, index: Int, isLast: Bool) -> some View {
        let icon = line.icon
        let freeIncluded = line.freeIncluded
        let title = loc.localized(line.titleKey)
        let detail = loc.localized(line.detailKey)
        let row = HStack(spacing: 0) {
            HStack(spacing: metrics.gap) {
                Image(systemName: icon)
                    .font(metrics.iconFont)
                    .foregroundStyle(CinemaColor.onSurface)
                    .frame(width: metrics.iconBox, height: metrics.iconBox)
                    .background(CinemaColor.onSurface.opacity(0.07), in: RoundedRectangle(cornerRadius: metrics.iconBox * 0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(metrics.rowTitleFont)
                        .foregroundStyle(CinemaColor.onSurface)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(metrics.rowDetailFont)
                        .foregroundStyle(CinemaColor.onSurfaceMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, metrics.rowPadding)
            .padding(.trailing, metrics.gap)

            mark(included: freeIncluded, isPro: false)
                .frame(width: metrics.columnWidth)
                .frame(maxHeight: .infinity)
            mark(included: true, isPro: true)
                .frame(width: metrics.columnWidth)
                .frame(maxHeight: .infinity)
                .background(palette.tint.opacity(0.10),
                            in: UnevenRoundedRectangle(bottomLeadingRadius: isLast ? metrics.radius : 0,
                                                       bottomTrailingRadius: isLast ? metrics.radius : 0))
        }
        .frame(minHeight: metrics.rowMinHeight)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { if !isLast { separator } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            title, detail,
            loc.localized("pro.compare.column.accessibility", loc.localized("pro.tier.free"),
                          loc.localized(freeIncluded ? "pro.compare.included" : "pro.compare.notIncluded")),
            loc.localized("pro.compare.column.accessibility", loc.localized("pro.tier.pro"),
                          loc.localized("pro.compare.included"))
        ].joined(separator: ". "))
        #if os(tvOS)
        // Row-level focus (`CinemaTVFocus`): accent stroke + brightness, no growth.
        let isFocused = focusedLine == index
        return row
            .brightness(isFocused ? CinemaTVFocus.rowBrightness : 0)
            .overlay {
                RoundedRectangle(cornerRadius: metrics.radius)
                    .strokeBorder(themeManager.accent.opacity(isFocused ? CinemaTVFocus.strokeOpacity : 0),
                                  lineWidth: CinemaTVFocus.strokeWidth)
            }
            .focusable()
            .focused($focusedLine, equals: index)
            .onMoveCommand { direction in
                if direction == .right { onMoveRight?() }
            }
            .focusEffectDisabled()
            .hoverEffectDisabled()
            .animation(reduceMotion ? nil : .easeOut(duration: CinemaTVFocus.rowDuration), value: isFocused)
        #else
        return row
        #endif
    }

    @ViewBuilder
    private func mark(included: Bool, isPro: Bool) -> some View {
        if included {
            Image(systemName: "checkmark")
                .font(metrics.markFont)
                .foregroundStyle(isPro ? palette.ink : CinemaColor.onSurfaceVariant)
        } else {
            Image(systemName: "lock.fill")
                .font(metrics.lockFont)
                .foregroundStyle(CinemaColor.onSurfaceMuted.opacity(0.7))
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(CinemaColor.onSurface.opacity(0.07))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The purchase panel — the tier's material (dark in both modes, like the
/// membership card it replaces): for a free user « Débloquez tout », the
/// price and « Débloquer »; for a founder or Pro, their tier and since when.
/// Then the three promises, « Restaurer les achats » (on screen in every
/// tier — App Review) and the legal links.
struct ProTierPanel: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var pageScheme
    @Environment(ProStore.self) private var proStore

    let tier: ProTier
    let since: String?
    let metrics: ProPageMetrics
    let onRestore: () -> Void

    private var inks: ProTierInks { ProTierInks(tier: tier, accent: themeManager.accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.panelSpacing) {
            Text(loc.localized(tier == .free ? "pro.compare.eyebrow" : "pro.tier.title"))
                .font(metrics.eyebrowFont)
                .tracking(3)
                .textCase(.uppercase)
                .foregroundStyle(inks.wordmarkInk)
            Text(tier == .free ? loc.localized("pro.panel.title.free") : tier.name(loc))
                .font(metrics.panelTitleFont)
                .tracking(-0.8)
                .foregroundStyle(inks.nameStyle)
                .accessibilityAddTraits(.isHeader)
            Text(tier == .free ? loc.localized("pro.panel.line.free") : tier.cardLine(loc))
                .font(metrics.panelLineFont)
                .foregroundStyle(CinemaColor.onTitanium)
                .fixedSize(horizontal: false, vertical: true)
            if let since {
                Text(since)
                    .font(metrics.eyebrowFont)
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(inks.secondaryInk)
            }
            Rectangle()
                .fill(CinemaColor.metalLight.opacity(0.10))
                .frame(height: 1)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            if tier == .free {
                ProPurchaseBlock(alignment: .leading, style: .panel(price: metrics.priceFont, note: metrics.priceNoteFont))
            }
            VStack(alignment: .leading, spacing: metrics.panelSpacing * 0.6) {
                perk("pro.perk.noSubscription")
                perk("pro.perk.family")
                perk("pro.perk.devices")
            }
            CinemaButton(title: loc.localized("pro.restore"), style: .ghost, isLoading: proStore.isRestoring, action: onRestore)
                .fixedSize(horizontal: false, vertical: true)
            legal
        }
        .padding(metrics.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ProTierMaterial(tier: tier, accent: themeManager.accent, glowRadius: 420))
        .clipShape(RoundedRectangle(cornerRadius: metrics.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.panelRadius)
                .strokeBorder(tier == .free ? inks.accent.opacity(0.40) : inks.tint.opacity(0.45), lineWidth: 1)
        }
        // On a light iPhone page a neutral shadow lifts the dark panel; no
        // coloured halo (product owner, 2026-10-24).
        .shadow(color: pageScheme == .light ? CinemaColor.metalShade.opacity(0.18) : .clear, radius: 18, y: 6)
        .environment(\.colorScheme, .dark)
    }

    private func perk(_ key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(metrics.perkFont)
                .foregroundStyle(inks.wordmarkInk)
                .accessibilityHidden(true)
            Text(loc.localized(key))
                .font(metrics.perkFont)
                .foregroundStyle(CinemaColor.onTitanium)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var legal: some View {
        #if os(tvOS)
        Text(loc.localized("pro.tv.legal"))
            .font(metrics.legalFont)
            .foregroundStyle(CinemaColor.onTitaniumVariant)
            .fixedSize(horizontal: false, vertical: true)
        #else
        HStack(spacing: CinemaSpacing.spacing4) {
            if let terms = ProScreen.termsURL {
                Link(loc.localized("pro.terms"), destination: terms)
            }
            if let privacy = ProScreen.privacyURL {
                Link(loc.localized("pro.privacy"), destination: privacy)
            }
        }
        .font(metrics.legalFont)
        .tint(inks.wordmarkInk)
        .frame(maxWidth: .infinity)
        #endif
    }
}

#if os(iOS)
/// The iPhone's purchase bar (compact width, free tier): the price and
/// « Débloquer » stay in reach while the table scrolls under them.
struct ProPurchaseBar: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(ProStore.self) private var proStore

    let product: ProductSnapshot

    var body: some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.localized("pro.compare.eyebrow"))
                    .font(CinemaFont.dynamicSystem(14, weight: .heavy, relativeTo: .subheadline))
                    .foregroundStyle(CinemaColor.onSurface)
                Text("\(product.displayPrice) · \(loc.localized("pro.price.once"))")
                    .font(CinemaFont.dynamicLabel(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await proStore.purchase() }
            } label: {
                Group {
                    if proStore.isPurchasing {
                        ProgressView().tint(themeManager.onAccentContainer)
                    } else {
                        Text(loc.localized("pro.buy.short"))
                            .font(CinemaFont.dynamicSystem(15, weight: .heavy, relativeTo: .subheadline))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(themeManager.onAccentContainer)
                .padding(.horizontal, CinemaSpacing.spacing5)
                .frame(minHeight: 44)
                .background(themeManager.accentContainer, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(proStore.isPurchasing)
        }
        .padding(.leading, CinemaSpacing.spacing4)
        .padding(.trailing, CinemaSpacing.spacing2)
        .padding(.vertical, CinemaSpacing.spacing2)
        .glassPanel(cornerRadius: 22)
        .padding(.horizontal, CinemaSpacing.spacing4)
        .padding(.bottom, CinemaSpacing.spacing2)
    }
}
#endif
