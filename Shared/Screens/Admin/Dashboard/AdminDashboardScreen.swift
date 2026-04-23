#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Admin Dashboard — mirrors Jellyfin web's "Tableau de bord": a snapshot of
/// live server state (active playback sessions + server info). Task summary
/// lands in P2 alongside the Scheduled Tasks screen.
struct AdminDashboardScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel = AdminDashboardViewModel()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                sessionsCard
                serverInfoCard
            }
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.top, CinemaSpacing.spacing4)
            .padding(.bottom, CinemaSpacing.spacing8)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.dashboard.title"))
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await viewModel.load(using: appState.apiClient) }
        .task { await viewModel.load(using: appState.apiClient) }
    }

    // MARK: - Sessions

    private var sessionsCard: some View {
        AdminSectionGroup(loc.localized("admin.dashboard.activeSessions")) {
            if viewModel.isLoading && viewModel.activeSessions.isEmpty {
                LoadingStateView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CinemaSpacing.spacing6)
            } else if viewModel.activeSessions.isEmpty {
                Text(loc.localized("admin.dashboard.noActiveSessions"))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(CinemaSpacing.spacing4)
            } else {
                ForEach(Array(viewModel.activeSessions.enumerated()), id: \.element.safeId) { index, session in
                    sessionRow(session)
                    if index < viewModel.activeSessions.count - 1 {
                        iOSSettingsDivider
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionInfoDto) -> some View {
        iOSSettingsRow {
            HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                iOSRowIcon(
                    systemName: session.nowPlayingItem != nil ? "play.circle.fill" : "person.circle",
                    color: session.nowPlayingItem != nil ? themeManager.accent : CinemaColor.onSurfaceVariant
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.userName ?? session.deviceName ?? loc.localized("admin.dashboard.unknownUser"))
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)

                    if let item = session.nowPlayingItem {
                        Text(item.name ?? "")
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(1)
                    }

                    HStack(spacing: CinemaSpacing.spacing2) {
                        if let device = session.deviceName {
                            Text(device)
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                        if let client = session.client {
                            Text("• \(client)")
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                    }
                }

                Spacer()
            }
        }
    }

    // MARK: - Server Info

    private var serverInfoCard: some View {
        AdminSectionGroup(loc.localized("admin.dashboard.serverInfo")) {
            if viewModel.isLoading && viewModel.systemInfo == nil {
                LoadingStateView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CinemaSpacing.spacing6)
            } else if let info = viewModel.systemInfo {
                infoRow(loc.localized("admin.dashboard.serverName"), value: info.serverName ?? "—", isFirst: true)
                iOSSettingsDivider
                infoRow(loc.localized("admin.dashboard.serverVersion"), value: info.version ?? "—")
                iOSSettingsDivider
                infoRow(loc.localized("admin.dashboard.operatingSystem"), value: info.operatingSystemDisplayName ?? info.operatingSystem ?? "—")
                if let arch = info.systemArchitecture {
                    iOSSettingsDivider
                    infoRow(loc.localized("admin.dashboard.architecture"), value: arch)
                }
                if let localAddress = info.localAddress {
                    iOSSettingsDivider
                    infoRow(loc.localized("admin.dashboard.localAddress"), value: localAddress)
                }
                if info.hasPendingRestart == true {
                    iOSSettingsDivider
                    restartPendingRow
                }
            } else {
                Text(loc.localized("admin.dashboard.serverInfoUnavailable"))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(CinemaSpacing.spacing4)
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String, isFirst: Bool = false) -> some View {
        iOSSettingsRow {
            HStack {
                Text(label)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Text(value)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var restartPendingRow: some View {
        iOSSettingsRow {
            HStack {
                iOSRowIcon(systemName: "arrow.triangle.2.circlepath", color: .orange)
                Text(loc.localized("admin.dashboard.restartPending"))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(.orange)
                Spacer()
            }
        }
    }
}

// SessionInfoDto's own `id` is `String?`, but SwiftUI's `ForEach` needs a
// non-optional identifier — fall back to device id / generated uuid to keep
// the list stable across reloads when `id` happens to be nil.
private extension SessionInfoDto {
    var safeId: String {
        id ?? deviceID ?? UUID().uuidString
    }
}
#endif
