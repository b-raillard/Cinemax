import SwiftUI

/// A title the library lacks, drawn as a dashed outline instead of artwork.
/// The caller owns the action (iOS `Button` + `.plain`, tvOS `Button` +
/// `CinemaTVCardButtonStyle`) — the card is only the look, focus ring included.
///
/// The dashed stroke is the ONE documented exception to « No 1px borders »
/// (Shared/DesignSystem/CLAUDE.md): never reuse it elsewhere.
struct MissingTitleCard: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    let title: String
    let subtitle: String?
    let badge: SeerrBadge
    var aspectRatio: CGFloat = 2 / 3

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                VStack(spacing: CinemaSpacing.spacing2) {
                    Spacer(minLength: 0)
                    Text(title)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .minimumScaleFactor(0.8)
                    if let subtitle {
                        Text(subtitle)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(badgeLabel)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(badge == .request ? themeManager.accent : CinemaColor.onSurfaceMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(CinemaSpacing.spacing3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: CinemaRadius.large)
                    .strokeBorder(CinemaColor.onSurfaceMuted, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
            .contentShape(Rectangle())
            .cinemaFocus()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(loc.localized("seerr.missing.a11y", title, badgeLabel))
    }

    private var badgeLabel: String {
        switch badge {
        case .request: loc.localized("seerr.badge.request")
        case .pending: loc.localized("seerr.badge.pending")
        case .processing: loc.localized("seerr.badge.processing")
        case .declined: loc.localized("seerr.badge.declined")
        }
    }
}

#if DEBUG
#Preview("MissingTitleCard — four badges") {
    HStack(spacing: CinemaSpacing.spacing3) {
        MissingTitleCard(title: "Un film pas encore là", subtitle: "2024", badge: .request)
        MissingTitleCard(title: "Court", subtitle: nil, badge: .pending)
        MissingTitleCard(title: "Un titre très long qui passe sur plusieurs lignes", subtitle: "2023", badge: .processing)
        MissingTitleCard(title: "Refusé", subtitle: "2021", badge: .declined)
    }
    .padding(CinemaSpacing.spacing4)
    .background(CinemaColor.surfaceContainerLowest)
    .environment(ThemeManager())
    .environment(LocalizationManager())
}
#endif
