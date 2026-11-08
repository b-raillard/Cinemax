import SwiftUI

/// A title the library lacks: a dashed outline over Seerr's poster, dimmed so
/// the text stays readable (product decision 2026-11-08) — the dash says « not
/// here yet », the poster says what it is. No poster ⇒ the bare outline.
/// The caller owns the action (iOS `Button` + `.plain`, tvOS `Button` +
/// `CinemaTVCardButtonStyle`) — the card is only the look, focus ring included.
///
/// The dashed stroke is the ONE documented exception to « No 1px borders »
/// (Shared/DesignSystem/CLAUDE.md): never reuse it elsewhere.
struct MissingTitleCard: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let subtitle: String?
    let badge: SeerrBadge
    var aspectRatio: CGFloat = 2 / 3
    /// Seerr's poster (`SeerrSession.posterURL`); nil draws the outline alone.
    var posterURL: URL?

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let posterURL {
                    CinemaLazyImage(url: posterURL, fallbackIcon: nil, fallbackBackground: .clear)
                        .overlay(CinemaColor.surfaceContainerLowest.opacity(0.62))
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                VStack(spacing: CinemaSpacing.spacing2) {
                    Spacer(minLength: 0)
                    Text(title)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 4)
                        .minimumScaleFactor(0.8)
                    // At accessibility sizes the badge must stay visible: the year goes.
                    if let subtitle, !dynamicTypeSize.isAccessibilitySize {
                        Text(subtitle)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(badgeLabel)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(badge == .request ? themeManager.accent : secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
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

    /// Muted reads too faint over a poster: the lighter variant there.
    private var secondaryText: Color {
        posterURL == nil ? CinemaColor.onSurfaceMuted : CinemaColor.onSurfaceVariant
    }

    private var badgeLabel: String { badge.label(loc) }
}

/// A missing title as the tappable card of a list mixing films and series —
/// the search and the actor page. Reads the request presenter itself, so its
/// badge flips once a request is sent even inside an `.equatable()` parent;
/// optional, like the fiche's cards: a host without it draws Seerr's badge.
struct MissingTitleButton: View {
    let missing: SeerrMissingTitle
    let onRequest: (SeerrMissingTitle) -> Void

    @Environment(SeerrRequestPresenter.self) private var presenter: SeerrRequestPresenter?
    @Environment(SeerrSession.self) private var seerr: SeerrSession?
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Button {
            onRequest(missing)
        } label: {
            MissingTitleCard(
                title: missing.title.title,
                subtitle: subtitle,
                badge: presenter?.badge(for: missing.id, default: missing.badge) ?? missing.badge,
                posterURL: seerr?.posterURL(missing.title.posterPath)
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }

    /// « 2021 · Film », like the library cards beside it.
    private var subtitle: String {
        let kind = loc.localized(missing.title.kind == .movie ? "seerr.request.kind.movie" : "seerr.request.kind.series")
        guard let year = missing.title.year else { return kind }
        return "\(year) · \(kind)"
    }
}

extension SeerrBadge {
    /// « Demander », « En attente », « En préparation », « Refusée ».
    @MainActor
    func label(_ loc: LocalizationManager) -> String {
        switch self {
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

#Preview("MissingTitleCard — accessibility5") {
    MissingTitleCard(title: "Un titre très long qui passe sur plusieurs lignes", subtitle: "2023", badge: .request)
        .frame(width: 160)
        .padding(CinemaSpacing.spacing4)
        .background(CinemaColor.surfaceContainerLowest)
        .dynamicTypeSize(.accessibility5)
        .environment(ThemeManager())
        .environment(LocalizationManager())
}
#endif
