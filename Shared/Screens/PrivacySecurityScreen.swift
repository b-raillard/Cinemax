import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI
import Nuke

/// Settings → Account → Privacy & Security.
///
/// Presented as a sheet on both iOS and tvOS so the same code drives both
/// platforms. Contents:
///   - Parental controls: age cap routed through `apiClient.applyContentRatingLimit`
///     and the `privacyMaxContentAge` `@AppStorage` key.
///   - Connected devices: lists server-registered devices (non-admin users see
///     only their own). The current device is excluded from the "sign out"
///     control to avoid the user locking themselves out mid-session — for that
///     they should use Log Out.
///   - Clear Continue Watching: iterates the current resume list and calls
///     `markItemUnplayed`, which wipes progress on the server.
///   - Clear Image Cache: drops the Nuke disk cache (500 MB) without touching
///     the server.
struct PrivacySecurityScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.privacyMaxContentAge) private var maxContentAge: Int = SettingsKey.Default.privacyMaxContentAge

    @State private var showClearContinueWatchingAlert = false
    @State private var showClearImageCacheAlert = false
    @State private var isClearingContinueWatching = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    parentalControlsSection
                    connectedDevicesLink
                    maintenanceSection
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(loc.localized("settings.privacySecurity"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.done")) { dismiss() }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        .alert(loc.localized("privacy.clearContinueWatching"), isPresented: $showClearContinueWatchingAlert) {
            Button(loc.localized("action.clear"), role: .destructive) {
                Task { await clearContinueWatching() }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("privacy.clearContinueWatching.confirm"))
        }
        .alert(loc.localized("privacy.clearImageCache"), isPresented: $showClearImageCacheAlert) {
            Button(loc.localized("action.clear"), role: .destructive) {
                clearImageCache()
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("privacy.clearImageCache.confirm"))
        }
    }

    // MARK: - Parental Controls

    private var parentalControlsSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader(loc.localized("privacy.parentalControls"))

            VStack(spacing: 0) {
                ForEach(Array(ParentalAgeOption.allCases.enumerated()), id: \.element.id) { index, option in
                    ageRow(option)
                    if index < ParentalAgeOption.allCases.count - 1 {
                        rowDivider
                    }
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)

            Text(loc.localized("privacy.parentalControls.footer"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .padding(.horizontal, CinemaSpacing.spacing2)
                .padding(.top, CinemaSpacing.spacing1)
        }
    }

    @ViewBuilder
    private func ageRow(_ option: ParentalAgeOption) -> some View {
        let isSelected = maxContentAge == option.age
        Button {
            maxContentAge = option.age
            appState.apiClient.applyContentRatingLimit(maxAge: option.age)
            NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
        } label: {
            HStack {
                Text(loc.localized(option.localizationKey))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: CinemaScale.pt(16), weight: .bold))
                        .foregroundStyle(themeManager.accent)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Connected Devices entry

    private var connectedDevicesLink: some View {
        NavigationLink {
            ConnectedDevicesList()
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                rowIcon(systemName: "laptopcomputer.and.iphone", color: themeManager.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.localized("privacy.activeSessions"))
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Text(loc.localized("privacy.activeSessions.subtitle"))
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(15), weight: .semibold))
                    .foregroundStyle(CinemaColor.outlineVariant)
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Maintenance (destructive)

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            sectionHeader(loc.localized("privacy.maintenance"))

            VStack(spacing: 0) {
                destructiveRow(
                    icon: "play.slash",
                    label: loc.localized("privacy.clearContinueWatching"),
                    subtitle: loc.localized("privacy.clearContinueWatching.subtitle"),
                    isBusy: isClearingContinueWatching
                ) {
                    showClearContinueWatchingAlert = true
                }

                rowDivider

                destructiveRow(
                    icon: "photo.stack",
                    label: loc.localized("privacy.clearImageCache"),
                    subtitle: loc.localized("privacy.clearImageCache.subtitle"),
                    isBusy: false
                ) {
                    showClearImageCacheAlert = true
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
        }
    }

    @ViewBuilder
    private func destructiveRow(
        icon: String,
        label: String,
        subtitle: String,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CinemaSpacing.spacing3) {
                rowIcon(systemName: icon, color: CinemaColor.error)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.error)
                    Text(subtitle)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                if isBusy {
                    ProgressView()
                        .tint(CinemaColor.error)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    // MARK: - Shared row chrome

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(CinemaFont.label(.small))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .tracking(1.2)
            .padding(.horizontal, CinemaSpacing.spacing2)
    }

    @ViewBuilder
    private func rowIcon(systemName: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CinemaRadius.small)
                .fill(color.opacity(0.12))
                .frame(width: 32, height: 32)
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.trailing, CinemaSpacing.spacing2)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(CinemaColor.surfaceContainerHighest.opacity(0.6))
            .frame(height: 1)
            .padding(.leading, CinemaSpacing.spacing4 + 32 + CinemaSpacing.spacing2)
    }

    // MARK: - Actions

    private func clearContinueWatching() async {
        guard let userId = appState.currentUserId else { return }
        isClearingContinueWatching = true
        defer { isClearingContinueWatching = false }
        // The resume list is a small window (~10 items) and the mutation is
        // idempotent, so iterate sequentially. Track per-item failures so a
        // partial failure is visible instead of pretending everything cleared.
        let resume: [BaseItemDto]
        do {
            resume = try await appState.apiClient.getResumeItems(userId: userId, limit: 50)
        } catch {
            toasts.error(loc.localized("toast.continueWatchingClearFailed"))
            return
        }
        var failures = 0
        for item in resume {
            guard let id = item.id else { continue }
            do {
                try await appState.apiClient.markItemUnplayed(itemId: id, userId: userId)
            } catch {
                failures += 1
            }
        }
        NotificationCenter.default.post(name: .cinemaxShouldRefreshCatalogue, object: nil)
        if failures == 0 {
            toasts.success(loc.localized("toast.continueWatchingCleared"))
        } else {
            toasts.error(loc.localized("toast.continueWatchingClearPartial"))
        }
    }

    private func clearImageCache() {
        ImagePipeline.shared.cache.removeAll()
        toasts.success(loc.localized("toast.imageCacheCleared"))
    }
}

// MARK: - Age option

/// Selectable caps for the Parental Controls picker. Order matches the menu.
private enum ParentalAgeOption: Int, CaseIterable, Identifiable {
    case all  = 0
    case age10 = 10
    case age12 = 12
    case age14 = 14
    case age16 = 16
    case age18 = 18

    var id: Int { rawValue }
    var age: Int { rawValue }
    var localizationKey: String {
        switch self {
        case .all:   return "privacy.age.all"
        case .age10: return "privacy.age.over10"
        case .age12: return "privacy.age.over12"
        case .age14: return "privacy.age.over14"
        case .age16: return "privacy.age.over16"
        case .age18: return "privacy.age.over18"
        }
    }
}

// MARK: - Connected Devices

private struct ConnectedDevicesList: View {
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
