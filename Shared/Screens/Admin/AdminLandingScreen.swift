#if os(iOS)
import SwiftUI
import CinemaxKit

/// "Administration" settings category — the most-used admin entries.
/// Dashboard (active server state) and Metadata Manager (item editor).
/// Metadata Manager is a coming-soon stub in P1 (ships in P3b).
struct AdminLandingScreen: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                AdminSectionGroup(loc.localized("admin.landing.section.server")) {
                    adminNavRow(
                        icon: "square.grid.2x2",
                        tint: themeManager.accent,
                        label: loc.localized("admin.dashboard.title"),
                        subtitle: loc.localized("admin.dashboard.subtitle"),
                        destination: AdminDashboardScreen()
                    )
                }

                AdminSectionGroup(loc.localized("admin.landing.section.metadata")) {
                    adminNavRow(
                        icon: "square.and.pencil",
                        tint: themeManager.accent,
                        label: loc.localized("admin.metadata.title"),
                        subtitle: loc.localized("admin.metadata.subtitle"),
                        destination: MetadataBrowserScreen()
                    )
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.top, CinemaSpacing.spacing4)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.landing.title"))
        .navigationBarTitleDisplayMode(.large)
    }
}
#endif
