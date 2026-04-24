#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Network admin panel. Editing network config from a phone is inherently
/// risky — wrong ports or LAN subnets can make the server unreachable until
/// an admin touches the machine directly. So the screen is deliberately
/// conservative:
///
/// - Pragmatic editable subset: ports, HTTPS enable/require, base URL,
///   published URLs (CSV), LAN subnets (CSV), and a few common toggles
///   (auto-discovery, UPnP, remote access, IPv4/v6)
/// - Advanced/dangerous fields (cert paths, reverse-proxy lists, virtual
///   interfaces) are shown read-only; admins edit those from the web panel
///   or config file
/// - Save surfaces a one-time confirmation dialog reminding the user they
///   could be locking themselves out — even if the web admin already does
///   the same, the risk compounds on a mobile client that can't recover
///   via console access
struct AdminNetworkScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var viewModel = AdminNetworkViewModel()

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.edited == nil,
            errorMessage: viewModel.errorMessage,
            isEmpty: false,
            onRetry: { Task { await viewModel.load(using: appState.apiClient) } }
        ) {
            if viewModel.edited != nil {
                AdminFormScreen(
                    isDirty: viewModel.isDirty,
                    isSaving: viewModel.isSaving,
                    onSave: {
                        // Intercept: confirm before sending anything that could
                        // brick the connection. The AdminFormScreen save button
                        // passes through to our confirmation dialog.
                        viewModel.showSaveWarning = true
                    }
                ) {
                    warningBanner
                    portsSection
                    urlsSection
                    lanSection
                    featuresSection
                    advancedReadOnlySection
                }
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.network.title"))
        .navigationBarTitleDisplayMode(.large)
        .task {
            if viewModel.edited == nil {
                await viewModel.load(using: appState.apiClient)
            }
        }
        .confirmationDialog(
            loc.localized("admin.network.saveWarning.title"),
            isPresented: $viewModel.showSaveWarning,
            titleVisibility: .visible
        ) {
            Button(loc.localized("admin.network.saveWarning.confirm"), role: .destructive) {
                Task {
                    let ok = await viewModel.save(using: appState.apiClient)
                    if ok {
                        toasts.success(loc.localized("admin.network.save.success"))
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.localized("admin.network.saveWarning.message"))
        }
    }

    // MARK: - Sections

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: CinemaScale.pt(18)))
                .foregroundStyle(.orange)
            Text(loc.localized("admin.network.warning"))
                .font(CinemaFont.label(.small))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
            Spacer()
        }
        .padding(CinemaSpacing.spacing4)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
    }

    private var portsSection: some View {
        AdminSectionGroup(
            loc.localized("admin.network.ports.title"),
            footer: loc.localized("admin.network.ports.footer")
        ) {
            intRow(
                icon: "number",
                label: loc.localized("admin.network.internalHTTP"),
                binding: intBinding(\.internalHTTPPort)
            )
            iOSSettingsDivider
            intRow(
                icon: "lock",
                label: loc.localized("admin.network.internalHTTPS"),
                binding: intBinding(\.internalHTTPSPort)
            )
            iOSSettingsDivider
            intRow(
                icon: "globe",
                label: loc.localized("admin.network.publicHTTP"),
                binding: intBinding(\.publicHTTPPort)
            )
            iOSSettingsDivider
            intRow(
                icon: "lock.shield",
                label: loc.localized("admin.network.publicHTTPS"),
                binding: intBinding(\.publicHTTPSPort)
            )
        }
    }

    private var urlsSection: some View {
        AdminSectionGroup(
            loc.localized("admin.network.urls.title"),
            footer: loc.localized("admin.network.urls.footer")
        ) {
            textRow(
                icon: "link",
                label: loc.localized("admin.network.baseURL"),
                binding: stringBinding(\.baseURL),
                placeholder: "/jellyfin"
            )
        }
    }

    private var lanSection: some View {
        AdminSectionGroup(
            loc.localized("admin.network.lan.title"),
            footer: loc.localized("admin.network.lan.footer")
        ) {
            textRow(
                icon: "house",
                label: loc.localized("admin.network.lanSubnets"),
                binding: csvBinding(\.localNetworkSubnets),
                placeholder: "192.168.1.0/24, 10.0.0.0/8"
            )
        }
    }

    private var featuresSection: some View {
        AdminSectionGroup(loc.localized("admin.network.features.title")) {
            toggleRow(
                icon: "sparkle.magnifyingglass",
                label: loc.localized("admin.network.autoDiscovery"),
                binding: boolBinding(\.isAutoDiscovery)
            )
            iOSSettingsDivider
            toggleRow(
                icon: "antenna.radiowaves.left.and.right",
                label: loc.localized("admin.network.upnp"),
                binding: boolBinding(\.enableUPnP)
            )
            iOSSettingsDivider
            toggleRow(
                icon: "network",
                label: loc.localized("admin.network.remoteAccess"),
                binding: boolBinding(\.enableRemoteAccess)
            )
            iOSSettingsDivider
            toggleRow(
                icon: "lock.fill",
                label: loc.localized("admin.network.requireHTTPS"),
                binding: boolBinding(\.requireHTTPS)
            )
        }
    }

    @ViewBuilder
    private var advancedReadOnlySection: some View {
        if let edited = viewModel.edited {
            AdminSectionGroup(
                loc.localized("admin.network.advanced.title"),
                footer: loc.localized("admin.network.advanced.footer")
            ) {
                readOnlyRow(
                    label: loc.localized("admin.network.certPath"),
                    value: edited.certificatePath ?? "—"
                )
                iOSSettingsDivider
                readOnlyRow(
                    label: loc.localized("admin.network.knownProxies"),
                    value: (edited.knownProxies ?? []).joined(separator: ", ").orEmDash
                )
                iOSSettingsDivider
                readOnlyRow(
                    label: loc.localized("admin.network.remoteIPFilter"),
                    value: (edited.remoteIPFilter ?? []).joined(separator: ", ").orEmDash
                )
                iOSSettingsDivider
                readOnlyRow(
                    label: loc.localized("admin.network.virtualInterfaces"),
                    value: (edited.virtualInterfaceNames ?? []).joined(separator: ", ").orEmDash
                )
            }
        }
    }

    // MARK: - Row builders

    @ViewBuilder
    private func intRow(icon: String, label: String, binding: Binding<String>) -> some View {
        iOSSettingsRow {
            HStack {
                iOSRowIcon(systemName: icon, color: themeManager.accent)
                Text(label)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                TextField("0", text: binding)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .font(.system(size: CinemaScale.pt(15), design: .monospaced))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .frame(width: 100)
            }
        }
    }

    @ViewBuilder
    private func textRow(icon: String, label: String, binding: Binding<String>, placeholder: String) -> some View {
        iOSSettingsRow {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                HStack(spacing: CinemaSpacing.spacing2) {
                    iOSRowIcon(systemName: icon, color: themeManager.accent)
                    Text(label)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Spacer()
                }
                TextField(placeholder, text: binding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: CinemaScale.pt(14), design: .monospaced))
                    .padding(CinemaSpacing.spacing3)
                    .background(CinemaColor.surfaceContainerHighest.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))
            }
        }
    }

    @ViewBuilder
    private func toggleRow(icon: String, label: String, binding: Binding<Bool>) -> some View {
        iOSSettingsRow {
            HStack {
                iOSRowIcon(systemName: icon, color: themeManager.accent)
                Text(label)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Button { binding.wrappedValue.toggle() } label: {
                    CinemaToggleIndicator(isOn: binding.wrappedValue, accent: themeManager.accent, animated: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func readOnlyRow(label: String, value: String) -> some View {
        iOSSettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Text(value)
                    .font(.system(size: CinemaScale.pt(13), design: .monospaced))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Bindings

    private func boolBinding(_ keyPath: WritableKeyPath<NetworkConfiguration, Bool?>) -> Binding<Bool> {
        Binding(
            get: { viewModel.edited?[keyPath: keyPath] ?? false },
            set: { viewModel.edited?[keyPath: keyPath] = $0 }
        )
    }

    /// Int? ↔ String binding for numeric TextFields. Parses only digits;
    /// keeps existing value when the typed string is non-numeric (e.g. mid-paste).
    private func intBinding(_ keyPath: WritableKeyPath<NetworkConfiguration, Int?>) -> Binding<String> {
        Binding(
            get: { viewModel.edited?[keyPath: keyPath].map(String.init) ?? "" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                viewModel.edited?[keyPath: keyPath] = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    private func stringBinding(_ keyPath: WritableKeyPath<NetworkConfiguration, String?>) -> Binding<String> {
        Binding(
            get: { viewModel.edited?[keyPath: keyPath] ?? "" },
            set: { viewModel.edited?[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    /// CSV <-> [String] binding — splits on commas, trims whitespace, drops
    /// empty entries. Round-trip-safe for the common case; users typing a
    /// trailing comma see it accepted until they commit the field.
    private func csvBinding(_ keyPath: WritableKeyPath<NetworkConfiguration, [String]?>) -> Binding<String> {
        Binding(
            get: { (viewModel.edited?[keyPath: keyPath] ?? []).joined(separator: ", ") },
            set: { newValue in
                let entries = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                viewModel.edited?[keyPath: keyPath] = entries.isEmpty ? nil : entries
            }
        )
    }
}

private extension String {
    var orEmDash: String { isEmpty ? "—" : self }
}
#endif
