#if os(iOS)
import SwiftUI
import CinemaxKit

/// Placeholder surfaced for admin entries slated for later phases (P2/P3).
/// Keeps the landing page navigable without crashing on unimplemented routes.
/// Replaced by the real screen in the phase that delivers it.
struct AdminComingSoonScreen: View {
    let title: String
    let symbol: String

    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            VStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: symbol)
                    .font(.system(size: CinemaScale.pt(48)))
                    .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.6))

                Text(loc.localized("admin.comingSoon.title"))
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurface)

                Text(loc.localized("admin.comingSoon.subtitle"))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, CinemaSpacing.spacing6)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}
#endif
