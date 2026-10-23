#if os(iOS)
import SwiftUI
import CinemaxKit

/// Settings → Administration — the ONE admin page (2026-10-22: it absorbed
/// « Admin avancée »). Four sections, in this order: Serveur, Utilisateurs,
/// Bibliothèque, Configuration. Every row carries a one-line subtitle saying
/// what the screen is for. A new admin screen goes into one of these sections,
/// never a second landing.
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
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "clock.arrow.circlepath",
                        tint: themeManager.accent,
                        label: loc.localized("admin.activity.title"),
                        subtitle: loc.localized("admin.activity.subtitle"),
                        destination: AdminActivityScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "calendar.badge.clock",
                        tint: themeManager.accent,
                        label: loc.localized("admin.tasks.title"),
                        subtitle: loc.localized("admin.tasks.subtitle"),
                        destination: AdminScheduledTasksScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "doc.text.magnifyingglass",
                        tint: themeManager.accent,
                        label: loc.localized("admin.logs.title"),
                        subtitle: loc.localized("admin.logs.subtitle"),
                        destination: AdminLogsScreen()
                    )
                }

                AdminSectionGroup(loc.localized("admin.landing.section.users")) {
                    adminNavRow(
                        icon: "person.2",
                        tint: themeManager.accent,
                        label: loc.localized("admin.users.title"),
                        subtitle: loc.localized("admin.users.subtitle"),
                        destination: AdminUsersScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "laptopcomputer.and.iphone",
                        tint: themeManager.accent,
                        label: loc.localized("admin.devices.title"),
                        subtitle: loc.localized("admin.devices.subtitle"),
                        destination: AdminDevicesScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "key",
                        tint: themeManager.accent,
                        label: loc.localized("admin.apiKeys.title"),
                        subtitle: loc.localized("admin.apiKeys.subtitle"),
                        destination: AdminApiKeysScreen()
                    )
                }

                AdminSectionGroup(loc.localized("admin.landing.section.library")) {
                    adminNavRow(
                        icon: "square.and.pencil",
                        tint: themeManager.accent,
                        label: loc.localized("admin.metadata.title"),
                        subtitle: loc.localized("admin.metadata.subtitle"),
                        destination: MetadataBrowserScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "shippingbox",
                        tint: themeManager.accent,
                        label: loc.localized("admin.catalog.title"),
                        subtitle: loc.localized("admin.catalog.subtitle"),
                        destination: AdminCatalogScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "puzzlepiece.extension",
                        tint: themeManager.accent,
                        label: loc.localized("admin.plugins.title"),
                        subtitle: loc.localized("admin.plugins.subtitle"),
                        destination: AdminPluginsScreen()
                    )
                }

                AdminSectionGroup(loc.localized("admin.landing.section.configuration")) {
                    adminNavRow(
                        icon: "play.square",
                        tint: themeManager.accent,
                        label: loc.localized("admin.playback.title"),
                        subtitle: loc.localized("admin.playback.subtitle"),
                        destination: AdminPlaybackScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "network",
                        tint: themeManager.accent,
                        label: loc.localized("admin.network.title"),
                        subtitle: loc.localized("admin.network.subtitle"),
                        destination: AdminNetworkScreen()
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

// MARK: - Row helper

/// Nav row of the admin landing. Takes a destination view (not a closure)
/// because `NavigationLink(destination:)` handles push — aligning with the
/// existing `navigationRow` helper but routing through NavigationLink instead
/// of a button + `@State Bool` modal flag.
@MainActor
@ViewBuilder
func adminNavRow<Destination: View>(
    icon: String,
    tint: Color,
    label: String,
    subtitle: String?,
    destination: Destination
) -> some View {
    NavigationLink(destination: destination) {
        iOSSettingsRow {
            HStack(alignment: .center, spacing: CinemaSpacing.spacing3) {
                iOSRowIcon(systemName: icon, color: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    if let subtitle {
                        Text(subtitle)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(15), weight: .semibold))
                    .foregroundStyle(CinemaColor.outlineVariant)
            }
        }
    }
    .buttonStyle(.plain)
}
#endif
