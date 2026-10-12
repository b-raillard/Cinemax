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
        case .founder: CinemaColor.founderGoldLight
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

    var cardFill: LinearGradient {
        switch tier {
        case .founder:
            LinearGradient(
                stops: [
                    .init(color: CinemaColor.founderGoldDeep, location: 0),
                    .init(color: CinemaColor.founderGold, location: 0.46),
                    .init(color: CinemaColor.founderGoldLight, location: 0.74),
                    .init(color: CinemaColor.founderGold, location: 1)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .pro:
            LinearGradient(colors: [themeManager.accentContainer, themeManager.accentContainer, themeManager.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .free:
            LinearGradient(colors: [CinemaColor.surfaceContainerHigh, CinemaColor.surfaceContainerHigh], startPoint: .top, endPoint: .bottom)
        }
    }

    var cardInk: Color {
        switch tier {
        case .founder: CinemaColor.onFounderCard
        case .pro: themeManager.onAccentContainer
        case .free: CinemaColor.onSurface
        }
    }

    var cardSecondaryInk: Color {
        tier == .free ? CinemaColor.onSurfaceVariant : cardInk.opacity(0.82)
    }

    var glow: Color {
        switch tier {
        case .founder: CinemaColor.founderGoldLight.opacity(0.45)
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

/// The membership card (design B) — the head of the Pro page. Founder: a
/// gold foil; Pro: the accent; free: a plain surface.
struct ProMembershipCard: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    let tier: ProTier
    /// « Membre depuis juin 2026 » — `nil` when the date is not known (a
    /// Debug-forced tier, no App Store answer yet).
    let since: String?

    private var look: ProTierLook { ProTierLook(tier: tier, themeManager: themeManager) }

    private var emblemInk: Color {
        switch tier {
        case .founder: CinemaColor.onFounderGold
        case .pro: themeManager.accentContainer
        case .free: CinemaColor.onSurfaceVariant
        }
    }

    private var line: String {
        switch tier {
        case .founder: loc.localized("pro.card.line.founder")
        case .pro: loc.localized("pro.card.line.pro")
        case .free: loc.localized("pro.card.line.free")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(loc.localized("pro.card.wordmark"))
                    .font(CinemaFont.dynamicLabel(.medium))
                    .fontWeight(.black)
                    .tracking(3)
                    .foregroundStyle(look.cardSecondaryInk)
                Spacer()
                Image(systemName: look.glyph ?? "play.fill")
                    .font(.system(size: CinemaScale.pt(18), weight: .black))
                    // On the card the emblem disc is the card's ink, so the
                    // glyph takes the card's own deep tone (a white check
                    // on the white disc vanished on the Pro card).
                    .foregroundStyle(emblemInk)
                    .frame(width: 38, height: 38)
                    .background(tier == .free ? AnyShapeStyle(CinemaColor.surfaceContainerHighest) : AnyShapeStyle(look.cardInk.opacity(0.92)), in: Circle())
                    .accessibilityHidden(true)
            }
            Spacer(minLength: CinemaSpacing.spacing4)
            Text(tier.name(loc))
                .font(CinemaFont.dynamicSystem(32, weight: .black, relativeTo: .title1))
                .foregroundStyle(look.cardInk)
            Text(line)
                .font(CinemaFont.dynamicLabel(.medium))
                .foregroundStyle(look.cardSecondaryInk)
                .padding(.top, 2)
            if let since {
                Text(since)
                    .font(CinemaFont.dynamicLabel(.small))
                    .fontWeight(.bold)
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(look.cardSecondaryInk)
                    .padding(.top, CinemaSpacing.spacing3)
            }
        }
        .padding(CinemaSpacing.spacing4)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(look.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.extraLarge))
        .shadow(color: look.glow.opacity(0.6), radius: 24, y: 10)
        .accessibilityElement(children: .combine)
    }
}
