import SwiftUI

/// « Votre niveau », visually (design D, chosen 2026-10-12): the Settings
/// logo wears the tier — a gold ring and a star medal for a founder, the
/// accent and a check for Pro, nothing for free — and a chip under the title
/// says it in words and opens the Pro page, whose head is the membership card
/// (design B). Nothing takes a row of the Settings list.
///
/// Gold is the founder's material (`CinemaColor.founderGold*`): rare, and not
/// something money buys any more. Pro takes the user's accent.
@MainActor
struct ProTierLook {
    let tier: ProTier
    let themeManager: ThemeManager

    /// SF Symbol of the medal; `nil` = no medal (free).
    var glyph: String? {
        switch tier {
        case .founder: "star.fill"
        case .pro: "checkmark"
        case .free: nil
        }
    }

    var ring: Color? {
        switch tier {
        case .founder: CinemaColor.founderGoldRing
        case .pro: themeManager.accent
        case .free: nil
        }
    }

    var medalFill: LinearGradient {
        switch tier {
        case .founder:
            LinearGradient(colors: [CinemaColor.founderGold, CinemaColor.founderGoldLight], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .pro, .free:
            LinearGradient(colors: [themeManager.accentContainer, themeManager.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var medalInk: Color {
        tier == .founder ? CinemaColor.onFounderGold : themeManager.onAccentContainer
    }

    var chipInk: Color {
        tier == .founder ? CinemaColor.founderGoldInk : themeManager.accent
    }

    var chipFill: Color {
        switch tier {
        case .founder: CinemaColor.founderGold.opacity(0.22)
        case .pro: themeManager.accent.opacity(0.16)
        case .free: CinemaColor.surfaceContainerHigh
        }
    }

    var glow: Color {
        switch tier {
        case .founder: CinemaColor.founderGoldRing.opacity(0.55)
        case .pro: themeManager.accent.opacity(0.4)
        case .free: .clear
        }
    }
}

extension ProTier {
    /// « Fondateur » / « Pro » / « Gratuit ».
    @MainActor func name(_ loc: LocalizationManager) -> String {
        switch self {
        case .founder: loc.localized("pro.tier.founder")
        case .pro: loc.localized("pro.tier.pro")
        case .free: loc.localized("pro.tier.free")
        }
    }
}

/// The tier worn by the Settings logo: a ring and, unless free, a medal on
/// its bottom-trailing corner. Decoration only (`accessibilityHidden`) — the
/// chip under the title says the same thing in words.
private struct ProTierLogoDecoration: ViewModifier {
    let look: ProTierLook
    let cornerRadius: CGFloat
    let medalSize: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if let ring = look.ring {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(ring, lineWidth: 3)
                        .padding(-5)
                        .shadow(color: look.glow, radius: 16)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let glyph = look.glyph {
                    Image(systemName: glyph)
                        .font(.system(size: medalSize * 0.46, weight: .black))
                        .foregroundStyle(look.medalInk)
                        .frame(width: medalSize, height: medalSize)
                        .background(look.medalFill, in: Circle())
                        .padding(4)
                        .background(CinemaColor.surface, in: Circle())
                        .offset(x: medalSize * 0.35, y: medalSize * 0.35)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// The Settings logo wearing `look.tier` (see `ProTierLogoDecoration`).
    /// `medalSize` is in raw points: the medal belongs to the logo, which does
    /// not follow the type scale either.
    func proTierLogo(_ look: ProTierLook?, cornerRadius: CGFloat, medalSize: CGFloat) -> some View {
        modifier(ProTierLogoOptional(look: look, cornerRadius: cornerRadius, medalSize: medalSize))
    }
}

private struct ProTierLogoOptional: ViewModifier {
    let look: ProTierLook?
    let cornerRadius: CGFloat
    let medalSize: CGFloat

    func body(content: Content) -> some View {
        if let look {
            content.modifier(ProTierLogoDecoration(look: look, cornerRadius: cornerRadius, medalSize: medalSize))
        } else {
            content
        }
    }
}

/// « ★ Fondateur · tout est inclus › » — the chip under the Settings title.
/// The ONE door to the Pro page (it no longer takes a row of the list).
struct ProTierChip: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    let tier: ProTier
    let action: () -> Void

    private var look: ProTierLook { ProTierLook(tier: tier, themeManager: themeManager) }

    private var text: String {
        switch tier {
        case .founder: loc.localized("pro.chip.founder")
        case .pro: loc.localized("pro.chip.pro")
        case .free: loc.localized("pro.chip.free")
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CinemaSpacing.spacing1 + 2) {
                if let glyph = look.glyph {
                    Image(systemName: glyph)
                        .font(.system(size: CinemaScale.pt(12), weight: .black))
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(CinemaFont.dynamicLabel(.large))
                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(11), weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(look.chipInk)
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaSpacing.spacing1 + 3)
            .background(look.chipFill, in: Capsule())
            .contentShape(Capsule())
        }
        #if os(tvOS)
        .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
        .focusEffectDisabled()
        .hoverEffectDisabled()
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(loc.localized("pro.chip.accessibility", tier.name(loc)))
    }
}

/// The membership card — the head of the Pro page, in the « titanium »
/// material chosen on 2026-10-13 (design A of the card study): brushed
/// graphite with an accent edge, glow and metallic name for Pro; brushed gold
/// for a founder; a dark card with an accent edge and halos for free (it had
/// no colour at all). Materials: the same in light and dark mode.
struct ProMembershipCard: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    let tier: ProTier
    /// « Membre depuis juin 2026 » — `nil` when the date is not known (a
    /// Debug-forced tier, no App Store answer yet).
    let since: String?

    private var accent: Color { themeManager.accent }
    private var accentLight: Color { accent.mix(with: CinemaColor.metalLight, by: 0.35) }
    private var accentDeep: Color { accent.mix(with: CinemaColor.metalShade, by: 0.55) }

    private var line: String {
        switch tier {
        case .founder: loc.localized("pro.card.line.founder")
        case .pro: loc.localized("pro.card.line.pro")
        case .free: loc.localized("pro.card.line.free")
        }
    }

    // MARK: Material

    /// The tone the edge, the glow and the halo take.
    private var tint: Color { tier == .founder ? CinemaColor.founderGoldLight : accent }

    private var ground: LinearGradient {
        switch tier {
        case .founder:
            LinearGradient(colors: [CinemaColor.founderGoldDeep, CinemaColor.founderGold, CinemaColor.founderGoldShade],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .pro:
            LinearGradient(stops: [.init(color: CinemaColor.titaniumEdge, location: 0),
                                   .init(color: CinemaColor.titaniumMid, location: 0.48),
                                   .init(color: CinemaColor.titaniumDeep, location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .free:
            LinearGradient(colors: [CinemaColor.titaniumPlain, CinemaColor.titaniumPlain], startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private var material: some View {
        ZStack {
            ground
            // Brushed metal: hairlines every 3 pt. Free stays smooth.
            if tier != .free {
                Canvas { context, size in
                    var x: CGFloat = 0
                    while x < size.width {
                        context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                     with: .color(CinemaColor.metalLight.opacity(0.035)))
                        x += 3
                    }
                }
            }
            // The glow in the top-trailing corner (and, for free, a second
            // halo bottom-leading — the colour the free card was missing).
            RadialGradient(colors: [tint.opacity(tier == .free ? 0.32 : 0.38), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 260)
            if tier == .free {
                RadialGradient(colors: [accent.opacity(0.18), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: 220)
            } else {
                // The sheen across the metal.
                LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                       .init(color: CinemaColor.metalLight.opacity(0.18), location: 0.46),
                                       .init(color: CinemaColor.metalLight.opacity(0.02), location: 0.56),
                                       .init(color: .clear, location: 0.7)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    // MARK: Inks

    private var nameStyle: AnyShapeStyle {
        switch tier {
        case .founder:
            AnyShapeStyle(LinearGradient(colors: [CinemaColor.founderGoldPale, CinemaColor.founderGoldLight, CinemaColor.founderGold],
                                         startPoint: .top, endPoint: .bottom))
        case .pro:
            AnyShapeStyle(LinearGradient(colors: [accentLight, accent, accentDeep], startPoint: .top, endPoint: .bottom))
        case .free:
            AnyShapeStyle(CinemaColor.onTitanium)
        }
    }

    private var wordmarkInk: Color { tier == .founder ? CinemaColor.founderGoldMark : accentLight }

    private var secondaryInk: Color {
        tier == .founder ? CinemaColor.onFounderCard.opacity(0.8) : CinemaColor.onTitaniumVariant
    }

    private var emblemFill: AnyShapeStyle {
        switch tier {
        case .founder:
            AnyShapeStyle(LinearGradient(colors: [CinemaColor.founderGoldPale, CinemaColor.founderGoldLight], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .pro:
            AnyShapeStyle(LinearGradient(colors: [accentLight, accent], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .free:
            AnyShapeStyle(accent.opacity(0.2))
        }
    }

    private var emblemInk: Color {
        switch tier {
        case .founder: CinemaColor.founderGoldDeep
        case .pro: CinemaColor.onMetalEmblem
        case .free: accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(loc.localized("pro.card.wordmark"))
                    .font(CinemaFont.dynamicLabel(.medium))
                    .fontWeight(.black)
                    .tracking(3)
                    .foregroundStyle(wordmarkInk)
                Spacer()
                Image(systemName: ProTierLook(tier: tier, themeManager: themeManager).glyph ?? "play.fill")
                    .font(.system(size: CinemaScale.pt(18), weight: .black))
                    .foregroundStyle(emblemInk)
                    .frame(width: 38, height: 38)
                    .background(emblemFill, in: Circle())
                    .shadow(color: tier == .free ? .clear : tint.opacity(0.6), radius: 9)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: CinemaSpacing.spacing4)
            Text(tier.name(loc))
                .font(CinemaFont.dynamicSystem(32, weight: .black, relativeTo: .title1))
                .foregroundStyle(nameStyle)
            Text(line)
                .font(CinemaFont.dynamicLabel(.medium))
                .foregroundStyle(secondaryInk)
                .padding(.top, 2)
            if let since {
                Text(since)
                    .font(CinemaFont.dynamicLabel(.small))
                    .fontWeight(.bold)
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(secondaryInk)
                    .padding(.top, CinemaSpacing.spacing3)
            }
        }
        .padding(CinemaSpacing.spacing4)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(material)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.extraLarge))
        // The edge: an accent (gold) filet, and a light top bevel on metal.
        .overlay {
            RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                .strokeBorder(tint.opacity(tier == .free ? 0.55 : 0.75), lineWidth: tier == .free ? 2 : 1.5)
        }
        .shadow(color: tier == .free ? .clear : tint.opacity(0.28), radius: 20, y: 10)
        .accessibilityElement(children: .combine)
    }
}
