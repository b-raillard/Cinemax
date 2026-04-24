#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Admin Devices list. Mirrors Jellyfin web's Devices panel: every
/// registered client with its user, app, and last-seen timestamp. Swipe to
/// revoke. The current device is intentionally non-revocable — revoking our
/// own session would log the app out from under the user.
struct AdminDevicesScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var viewModel = AdminDevicesViewModel()

    private var currentDeviceId: String {
        KeychainService.getOrCreateDeviceID()
    }

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.devices.isEmpty,
            errorMessage: viewModel.errorMessage,
            isEmpty: viewModel.isEmpty,
            emptyIcon: "laptopcomputer.slash",
            emptyTitle: loc.localized("admin.devices.empty.title"),
            emptySubtitle: loc.localized("admin.devices.empty.subtitle"),
            onRetry: { Task { await viewModel.load(using: appState.apiClient) } }
        ) {
            List {
                ForEach(viewModel.devices, id: \.id) { device in
                    deviceRow(device)
                        .listRowBackground(CinemaColor.surfaceContainerHigh)
                        .listRowSeparatorTint(CinemaColor.outlineVariant.opacity(0.3))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if device.id != currentDeviceId {
                                Button(role: .destructive) {
                                    viewModel.pendingRevoke = device
                                } label: {
                                    Label(loc.localized("admin.devices.revoke"), systemImage: "xmark.circle.fill")
                                }
                            }
                        }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CinemaColor.surface)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.devices.title"))
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await viewModel.load(using: appState.apiClient) }
        .task {
            if viewModel.devices.isEmpty {
                await viewModel.load(using: appState.apiClient)
            }
        }
        .confirmationDialog(
            loc.localized("admin.devices.revoke.title"),
            isPresented: Binding(
                get: { viewModel.pendingRevoke != nil },
                set: { if !$0 { viewModel.pendingRevoke = nil } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.pendingRevoke
        ) { device in
            Button(loc.localized("admin.devices.revoke"), role: .destructive) {
                Task {
                    let ok = await viewModel.revoke(device, using: appState.apiClient)
                    if ok {
                        toasts.success(loc.localized("admin.devices.revoke.success"))
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                    viewModel.pendingRevoke = nil
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {
                viewModel.pendingRevoke = nil
            }
        } message: { device in
            Text(String(
                format: loc.localized("admin.devices.revoke.message"),
                device.customName ?? device.name ?? "—"
            ))
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: DeviceInfoDto) -> some View {
        let isCurrent = device.id == currentDeviceId
        HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
            iOSRowIcon(
                systemName: iconName(for: device),
                color: isCurrent ? themeManager.accent : CinemaColor.onSurfaceVariant
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: CinemaSpacing.spacing2) {
                    Text(device.customName ?? device.name ?? "—")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    if isCurrent {
                        Text(loc.localized("admin.devices.thisDevice"))
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(themeManager.accent))
                    }
                }

                if let user = device.lastUserName {
                    Text(user)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }

                Text(subtitleLine(for: device))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, CinemaSpacing.spacing2)
    }

    private func iconName(for device: DeviceInfoDto) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("apple tv") || name.contains("tv") { return "appletv" }
        if name.contains("mac") { return "laptopcomputer" }
        if name.contains("android") { return "smartphone" }
        return "display"
    }

    private func subtitleLine(for device: DeviceInfoDto) -> String {
        var parts: [String] = []
        if let app = device.appName {
            if let version = device.appVersion {
                parts.append("\(app) \(version)")
            } else {
                parts.append(app)
            }
        }
        if let date = device.dateLastActivity {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append(formatter.localizedString(for: date, relativeTo: Date()))
        }
        return parts.joined(separator: " • ")
    }
}
#endif
