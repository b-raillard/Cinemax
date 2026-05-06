import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - Connected Devices

/// Active sessions list shown from Privacy & Security. Lists every device the
/// user is signed in on, with a per-row "sign out" action. The user's own
/// device is highlighted at the bottom and the revoke action is hidden for it
/// (server enforces self-protection too — revoking the current session would
/// log this device out).
struct ConnectedDevicesList: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var devices: [DeviceInfoDto] = []
    @State private var isLoading = true
    @State private var pendingSignOut: DeviceInfoDto?
    @State private var revokingDeviceId: String?

    private var currentDeviceId: String { KeychainService.getOrCreateDeviceID() }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                if isLoading {
                    LoadingStateView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, CinemaSpacing.spacing10)
                } else if otherDevices.isEmpty {
                    EmptyStateView(
                        systemImage: "laptopcomputer.slash",
                        title: loc.localized("privacy.sessions.empty")
                    )
                } else {
                    ForEach(otherDevices, id: \.id) { device in
                        deviceRow(device)
                    }
                }

                if let current = devices.first(where: { $0.id == currentDeviceId }) {
                    currentDeviceCard(current)
                }
            }
            .padding(CinemaSpacing.spacing4)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("privacy.activeSessions"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .alert(
            loc.localized("privacy.sessions.signOut"),
            isPresented: Binding(
                get: { pendingSignOut != nil },
                set: { if !$0 { pendingSignOut = nil } }
            )
        ) {
            Button(loc.localized("privacy.sessions.signOut"), role: .destructive) {
                if let target = pendingSignOut { Task { await revoke(target) } }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {
                pendingSignOut = nil
            }
        } message: {
            Text(loc.localized("privacy.sessions.signOutConfirm"))
        }
    }

    private var otherDevices: [DeviceInfoDto] {
        devices.filter { $0.id != currentDeviceId }
    }

    @ViewBuilder
    private func deviceRow(_ device: DeviceInfoDto) -> some View {
        let isRevoking = revokingDeviceId == device.id
        HStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: iconName(for: device))
                .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                .foregroundStyle(themeManager.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name ?? device.appName ?? "Device")
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(1)

                Text(subtitle(for: device))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(1)
            }

            Spacer()

            if isRevoking {
                ProgressView()
                    .tint(CinemaColor.error)
            } else {
                Button {
                    pendingSignOut = device
                } label: {
                    Text(loc.localized("privacy.sessions.signOut"))
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.error)
                        .padding(.horizontal, CinemaSpacing.spacing3)
                        .padding(.vertical, CinemaSpacing.spacing2)
                        .background(
                            Capsule().fill(CinemaColor.error.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(CinemaSpacing.spacing4)
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    @ViewBuilder
    private func currentDeviceCard(_ device: DeviceInfoDto) -> some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            Image(systemName: iconName(for: device))
                .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                .foregroundStyle(themeManager.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name ?? device.appName ?? "Device")
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Text(loc.localized("privacy.sessions.current"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.success)
            }

            Spacer()
        }
        .padding(CinemaSpacing.spacing4)
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    private func subtitle(for device: DeviceInfoDto) -> String {
        var parts: [String] = []
        if let app = device.appName { parts.append(app) }
        if let user = device.lastUserName { parts.append(user) }
        if let when = device.dateLastActivity {
            parts.append(when.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func iconName(for device: DeviceInfoDto) -> String {
        let raw = (device.appName ?? device.name ?? "").lowercased()
        if raw.contains("apple tv") { return "tv" }
        if raw.contains("ipad") { return "ipad" }
        if raw.contains("iphone") { return "iphone" }
        if raw.contains("mac") { return "laptopcomputer" }
        if raw.contains("android") { return "candybarphone" }
        if raw.contains("web") || raw.contains("browser") || raw.contains("chrome") || raw.contains("safari") || raw.contains("firefox") { return "safari" }
        return "display"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await appState.apiClient.getDevices()
        } catch {
            devices = []
            toasts.error(loc.localized("toast.deviceListFailed"))
        }
    }

    private func revoke(_ device: DeviceInfoDto) async {
        guard let id = device.id else { return }
        pendingSignOut = nil
        revokingDeviceId = id
        defer { revokingDeviceId = nil }
        do {
            try await appState.apiClient.deleteDevice(id: id)
            devices.removeAll { $0.id == id }
            toasts.success(loc.localized("toast.deviceSignedOut"))
        } catch {
            toasts.error(loc.localized("toast.deviceSignOutFailed"))
        }
    }
}
