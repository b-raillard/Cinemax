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

    private static let ringWidth: CGFloat = 3

    func body(content: Content) -> some View {
        content
            .overlay {
                if let ring = look.ring {
                    // Flush against the logo's edge, its corners concentric:
                    // a 2 pt gap and a same-radius ring read as a loose frame
                    // (recette 2026-10-14, I-01).
                    RoundedRectangle(cornerRadius: cornerRadius + Self.ringWidth)
                        .strokeBorder(ring, lineWidth: Self.ringWidth)
                        .padding(-Self.ringWidth)
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

/// The inks of a tier's material (`ProTierMaterial`): the metallic name, the
/// eyebrow, the secondary text of the Pro page's panel. The material is dark in both
/// modes, so none of these follow light / dark.
@MainActor
struct ProTierInks {
    let tier: ProTier
    let accent: Color

    var accentLight: Color { accent.mix(with: CinemaColor.metalLight, by: 0.35) }
    var accentDeep: Color { accent.mix(with: CinemaColor.metalShade, by: 0.55) }

    /// The tone the edge, the glow and the halo take.
    var tint: Color { tier == .founder ? CinemaColor.founderGoldLight : accent }

    var nameStyle: AnyShapeStyle {
        switch tier {
        case .founder:
            AnyShapeStyle(LinearGradient(colors: [CinemaColor.founderGoldPale, CinemaColor.founderGoldLight, CinemaColor.founderGold],
                                         startPoint: .top, endPoint: .bottom))
        case .pro:
            AnyShapeStyle(LinearGradient(colors: [accentLight, accent, accentDeep], startPoint: .top, endPoint: .bottom))
        case .free:
            AnyShapeStyle(LinearGradient(colors: [CinemaColor.metalLight,
                                                  CinemaColor.metalLight.mix(with: CinemaColor.metalShade, by: 0.18),
                                                  CinemaColor.metalLight.mix(with: CinemaColor.metalShade, by: 0.42)],
                                         startPoint: .top, endPoint: .bottom))
        }
    }

    var wordmarkInk: Color { tier == .founder ? CinemaColor.founderGoldMark : accentLight }

    var secondaryInk: Color {
        tier == .founder ? CinemaColor.onFounderCard.opacity(0.8) : CinemaColor.onTitaniumVariant
    }
}

/// A tier's material, the same in light and dark mode: a near-black ground
/// carrying the tier's colour, brushed hairlines, a faint corner light, and
/// the colour itself kept for the metallic name and the emblem — gold for a
/// founder, the accent for Pro, neutral graphite for free. The founder's quiet
/// recipe (recette 2026-10-13), worn edge to edge behind the Apple TV « Votre
/// niveau » page and by the Pro page's purchase panel on every platform
/// (design C, 2026-10-24). The earlier bright metal read as a wall of yellow,
/// a muddy grey and two smudges.
struct ProTierMaterial: View {
    let tier: ProTier
    let accent: Color
    /// The glow's reach: a card's corner, or most of a TV screen.
    var glowRadius: CGFloat = 320

    private var tint: Color {
        switch tier {
        case .founder: CinemaColor.founderGoldLight
        case .pro: accent
        case .free: CinemaColor.metalLight
        }
    }

    private var glowOpacity: Double {
        switch tier {
        case .founder: 0.16
        case .pro: 0.14
        case .free: 0.05
        }
    }

    /// Near-black stops carrying `color`, lightest top-leading.
    private func darkGround(_ color: Color, _ amounts: [Double]) -> LinearGradient {
        LinearGradient(colors: amounts.map { color.mix(with: CinemaColor.metalShade, by: $0) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var ground: LinearGradient {
        switch tier {
        case .founder:
            darkGround(CinemaColor.founderGoldDeep, [0.35, 0.6, 0.8])
        case .pro:
            darkGround(accent, [0.78, 0.86, 0.93])
        case .free:
            LinearGradient(colors: [CinemaColor.titaniumPlain, CinemaColor.titaniumDeep, CinemaColor.titaniumDeep.mix(with: CinemaColor.metalShade, by: 0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var body: some View {
        ZStack {
            ground
            // Brushed metal: hairlines every 3 pt.
            Canvas { context, size in
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                 with: .color(CinemaColor.metalLight.opacity(0.035)))
                    x += 3
                }
            }
            // The light in the top-trailing corner.
            RadialGradient(colors: [tint.opacity(glowOpacity), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: glowRadius)
            // The faintest sheen — what tells metal from paint.
            LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                   .init(color: CinemaColor.metalLight.opacity(0.05), location: 0.46),
                                   .init(color: .clear, location: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .accessibilityHidden(true)
    }
}

extension ProTier {
    /// « Tout est inclus, pour toujours » / « Merci de soutenir JellyGlass » /
    /// « Lecture complète, sans limite ».
    @MainActor func cardLine(_ loc: LocalizationManager) -> String {
        switch self {
        case .founder: loc.localized("pro.card.line.founder")
        case .pro: loc.localized("pro.card.line.pro")
        case .free: loc.localized("pro.card.line.free")
        }
    }
}
