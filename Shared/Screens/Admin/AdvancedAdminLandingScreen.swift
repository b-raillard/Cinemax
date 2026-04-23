#if os(iOS)
import SwiftUI
import CinemaxKit

/// "Advanced admin" settings category — the long-tail operational entries.
/// P1 ships Users / Devices / Activity as real screens. The rest are
/// navigable coming-soon stubs so users can see the full menu shape from day
/// one and we catch routing bugs early.
struct AdvancedAdminLandingScreen: View {
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
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
                        icon: "clock.arrow.circlepath",
                        tint: themeManager.accent,
                        label: loc.localized("admin.activity.title"),
                        subtitle: loc.localized("admin.activity.subtitle"),
                        destination: AdminActivityScreen()
                    )
                }

                AdminSectionGroup(loc.localized("admin.landing.section.extensions")) {
                    adminNavRow(
                        icon: "play.square",
                        tint: themeManager.accent,
                        label: loc.localized("admin.playback.title"),
                        subtitle: nil,
                        destination: AdminPlaybackScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "puzzlepiece.extension",
                        tint: themeManager.accent,
                        label: loc.localized("admin.plugins.title"),
                        subtitle: nil,
                        destination: AdminPluginsScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "globe",
                        tint: themeManager.accent,
                        label: loc.localized("admin.catalog.title"),
                        subtitle: nil,
                        destination: AdminCatalogScreen()
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "calendar.badge.clock",
                        tint: themeManager.accent,
                        label: loc.localized("admin.tasks.title"),
                        subtitle: nil,
                        destination: AdminScheduledTasksScreen()
                    )
                }

                AdminSectionGroup(loc.localized("admin.landing.section.advanced")) {
                    adminNavRow(
                        icon: "network",
                        tint: themeManager.accent,
                        label: loc.localized("admin.network.title"),
                        subtitle: nil,
                        destination: AdminComingSoonScreen(
                            title: loc.localized("admin.network.title"),
                            symbol: "network"
                        )
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "doc.text.magnifyingglass",
                        tint: themeManager.accent,
                        label: loc.localized("admin.logs.title"),
                        subtitle: nil,
                        destination: AdminComingSoonScreen(
                            title: loc.localized("admin.logs.title"),
                            symbol: "doc.text.magnifyingglass"
                        )
                    )
                    iOSSettingsDivider
                    adminNavRow(
                        icon: "key",
                        tint: themeManager.accent,
                        label: loc.localized("admin.apiKeys.title"),
                        subtitle: nil,
                        destination: AdminComingSoonScreen(
                            title: loc.localized("admin.apiKeys.title"),
                            symbol: "key"
                        )
                    )
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.top, CinemaSpacing.spacing4)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.advanced.title"))
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Shared row helper

/// Nav row used by both admin landings. Takes a destination view (not a
/// closure) because `NavigationLink(destination:)` handles push — aligning
/// with the existing `navigationRow` helper but routing through NavigationLink
/// instead of a button + `@State Bool` modal flag.
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
