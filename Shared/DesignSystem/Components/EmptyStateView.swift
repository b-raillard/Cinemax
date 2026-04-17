import SwiftUI

/// Standard empty state: SF Symbol + title + optional subtitle + optional action button.
///
/// Use when a collection is legitimately empty — no library items, no filtered matches,
/// no resume entries — as opposed to `ErrorStateView` which signals a request failure.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: systemImage)
                .font(.system(size: CinemaScale.pt(56), weight: .regular))
                .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.7))
                .accessibilityHidden(true)

            Text(title)
                .font(CinemaFont.headline(.small))
                .foregroundStyle(CinemaColor.onSurface)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, CinemaSpacing.spacing6)
            }

            if let actionTitle, let onAction {
                CinemaButton(title: actionTitle, style: .ghost) {
                    onAction()
                }
                .frame(width: 200)
                .padding(.top, CinemaSpacing.spacing2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CinemaSpacing.spacing10)
    }
}
