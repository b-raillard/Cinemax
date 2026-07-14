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

    #if os(tvOS)
    @Environment(\.motionEffectsEnabled) private var motionEffects
    private enum FocusTarget: Hashable {
        case device(String)
        case current
    }
    @FocusState private var focusedItem: FocusTarget?
    #endif

    private var currentDeviceId: String { KeychainService.getOrCreateDeviceID() }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                #if os(tvOS)
                // `.navigationTitle` renders no chrome on a tvOS push — paint
                // the title ourselves (same treatment as the parent screen).
                Text(loc.localized("privacy.activeSessions"))
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .padding(.bottom, CinemaSpacing.spacing4)
                #endif

                // The loading / empty branches carry `.focusable()` on tvOS: if
                // the pushed screen has zero focusable views, focus stays on the
                // covered Privacy root and a Menu press hits its
                // `.onExitCommand`, tearing down the whole cover instead of
                // popping back.
                if isLoading {
                    LoadingStateView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, CinemaSpacing.spacing10)
                        #if os(tvOS)
                        .focusable()
                        .focusEffectDisabled()
                        #endif
                } else if otherDevices.isEmpty {
                    EmptyStateView(
                        systemImage: "laptopcomputer.slash",
                        title: loc.localized("privacy.sessions.empty")
                    )
                    #if os(tvOS)
                    .focusable()
                    .focusEffectDisabled()
                    #endif
                } else {
                    ForEach(otherDevices, id: \.id) { device in
                        deviceRow(device)
                    }
                }

                if let current = devices.first(where: { $0.id == currentDeviceId }) {
                    currentDeviceCard(current)
                }
            }
            #if os(tvOS)
            .padding(.horizontal, CinemaSpacing.spacing10)
            .padding(.vertical, CinemaSpacing.spacing6)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            #else
            .padding(CinemaSpacing.spacing4)
            #endif
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
        #if os(tvOS)
        // Whole-row button (one focusable unit per row): select opens the
        // sign-out confirmation; the capsule is a visual affordance only.
        Button {
            pendingSignOut = device
        } label: {
            deviceRowContent(device, isRevoking: isRevoking)
                .padding(CinemaSpacing.spacing4)
                .frame(maxWidth: .infinity, minHeight: 80)
                .tvSettingsFocusable(
                    isFocused: focusedItem == .device(device.id ?? ""),
                    accent: themeManager.accent,
                    animated: motionEffects,
                    colorScheme: themeManager.darkModeEnabled ? .dark : .light
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .device(device.id ?? ""))
        .disabled(isRevoking)
        #else
        deviceRowContent(device, isRevoking: isRevoking)
            .padding(CinemaSpacing.spacing4)
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        #endif
    }

    @ViewBuilder
    private func deviceRowContent(_ device: DeviceInfoDto, isRevoking: Bool) -> some View {
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
                #if os(tvOS)
                signOutCapsule
                #else
                Button {
                    pendingSignOut = device
                } label: {
                    signOutCapsule
                }
                .buttonStyle(.plain)
                #endif
            }
        }
    }

    private var signOutCapsule: some View {
        Text(loc.localized("privacy.sessions.signOut"))
            .font(CinemaFont.label(.medium))
            .foregroundStyle(CinemaColor.error)
            .padding(.horizontal, CinemaSpacing.spacing3)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(
                Capsule().fill(CinemaColor.error.opacity(0.12))
            )
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
        #if os(tvOS)
        // Focusable (but inert) so focus can rest in this screen even when it
        // is the only card — see the Menu-press note on the loading state.
        .frame(maxWidth: .infinity, minHeight: 80)
        .tvSettingsFocusable(
            isFocused: focusedItem == .current,
            accent: themeManager.accent,
            animated: motionEffects,
            colorScheme: themeManager.darkModeEnabled ? .dark : .light
        )
        .focusable()
        .focusEffectDisabled()
        .focused($focusedItem, equals: .current)
        #else
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        #endif
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
