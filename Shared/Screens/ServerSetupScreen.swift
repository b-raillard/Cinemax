import SwiftUI
import CinemaxKit

@MainActor @Observable
final class ServerSetupViewModel {
    var serverURL: String = ""
    var isConnecting = false
    var errorMessage: String?
    var serverInfo: ServerInfo?

    func connect(using appState: AppState) async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter a server address."
            return
        }

        // Prepend https:// if no scheme
        var urlString = trimmed
        if !urlString.contains("://") {
            urlString = "https://\(urlString)"
        }

        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL format."
            return
        }

        isConnecting = true
        errorMessage = nil

        do {
            let info = try await appState.apiClient.connectToServer(url: url)
            try appState.keychain.saveServerURL(url)
            serverInfo = info
            appState.serverURL = url
            appState.serverInfo = info
            appState.hasServer = true
        } catch {
            errorMessage = "Unable to connect: \(error.localizedDescription)"
        }

        isConnecting = false
    }
}

struct ServerSetupScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel = ServerSetupViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        #if os(tvOS)
        tvOSLayout
        #else
        if sizeClass == .regular {
            tvOSLayout
        } else {
            mobileLayout
        }
        #endif
    }

    // MARK: - tvOS / iPad Layout

    private var tvOSLayout: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            // Ambient background glow
            backgroundGlow

            VStack(spacing: 0) {
                // Header
                Text(loc.localized("server.header"))
                    .font(.system(size: 28, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(CinemaColor.onSurface)
                    .padding(.top, 64)

                Spacer()

                // Title
                VStack(spacing: CinemaSpacing.spacing3) {
                    Text(loc.localized("server.title"))
                        .font(CinemaFont.display(.medium))
                        .foregroundStyle(CinemaColor.onSurface)
                        .tracking(-1)

                    Text(loc.localized("server.subtitle"))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                }
                .padding(.bottom, CinemaSpacing.spacing8)

                // Glass input panel
                VStack(spacing: CinemaSpacing.spacing6) {
                    GlassTextField(
                        label: loc.localized("server.urlLabel"),
                        text: $viewModel.serverURL,
                        placeholder: loc.localized("server.placeholder"),
                        icon: "server.rack"
                    )
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif

                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }

                    CinemaButton(
                        title: loc.localized("server.connect"),
                        style: .accent,
                        icon: "chevron.right",
                        isLoading: viewModel.isConnecting
                    ) {
                        Task { await viewModel.connect(using: appState) }
                    }
                    .disabled(viewModel.isConnecting)
                }
                .padding(CinemaSpacing.spacing6)
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
                .frame(maxWidth: 600)

                Spacer()

                // Helper links
                HStack(spacing: CinemaSpacing.spacing6) {
                    helperLink(icon: "questionmark.circle", title: loc.localized("server.howToFind"))
                    Divider()
                        .frame(height: 20)
                        .overlay(CinemaColor.outlineVariant.opacity(0.3))
                    helperLink(icon: "network", title: loc.localized("server.networkSettings"))
                }
                .padding(.bottom, CinemaSpacing.spacing6)

                // Status pill
                statusPill
                    .padding(.bottom, CinemaSpacing.spacing6)
            }
            .padding(.horizontal, CinemaSpacing.spacing20)
        }
    }

    // MARK: - Mobile Layout

    private var mobileLayout: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            backgroundGlow

            VStack(spacing: 0) {
                Spacer()

                // Header
                VStack(spacing: CinemaSpacing.spacing3) {
                    // Icon
                    ZStack {
                        RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                            .fill(CinemaColor.surfaceContainerHigh)
                            .frame(width: 80, height: 80)
                        Image(systemName: "server.rack")
                            .font(.system(size: 36))
                            .foregroundStyle(themeManager.accent)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 20)

                    Text(loc.localized("server.header"))
                        .font(.system(size: 14, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(CinemaColor.onSurface)

                    Text(loc.localized("server.mobileTitle"))
                        .font(.system(size: 28, weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(.white)

                    Text(loc.localized("server.mobileSubtitle"))
                        .font(.system(size: 14))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .padding(.bottom, CinemaSpacing.spacing8)

                // Input card
                VStack(spacing: CinemaSpacing.spacing4) {
                    GlassTextField(
                        label: loc.localized("server.addressLabel"),
                        text: $viewModel.serverURL,
                        placeholder: loc.localized("server.placeholder"),
                        icon: "link"
                    )
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif

                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                }
                .padding(CinemaSpacing.spacing4)
                .glassPanel(cornerRadius: CinemaRadius.large)
                .padding(.horizontal, CinemaSpacing.spacing4)

                Spacer()

                // Actions
                VStack(spacing: CinemaSpacing.spacing3) {
                    CinemaButton(
                        title: loc.localized("server.connect"),
                        style: .accent,
                        icon: "chevron.right",
                        isLoading: viewModel.isConnecting
                    ) {
                        Task { await viewModel.connect(using: appState) }
                    }
                    .disabled(viewModel.isConnecting)

                    Button {
                        // Help action
                    } label: {
                        Text(loc.localized("server.needHelp"))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.bottom, CinemaSpacing.spacing6)
            }
        }
    }

    // MARK: - Shared Components

    private var backgroundGlow: some View {
        ZStack {
            Circle()
                .fill(themeManager.accent.opacity(0.15))
                .frame(width: 400, height: 400)
                .blur(radius: 120)
                .offset(x: 150, y: -200)

            Circle()
                .fill(CinemaColor.primary.opacity(0.05))
                .frame(width: 300, height: 300)
                .blur(radius: 100)
                .offset(x: -150, y: 200)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(CinemaColor.error)
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CinemaColor.error)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.medium)
                .fill(CinemaColor.errorContainer.opacity(0.2))
        )
    }

    private func helperLink(icon: String, title: String) -> some View {
        Button {
            // Placeholder
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .buttonStyle(.plain)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isConnecting ? themeManager.accent : CinemaColor.error)
                .frame(width: 6, height: 6)
            Text(viewModel.isConnecting ? loc.localized("server.connecting") : loc.localized("server.offline"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(CinemaColor.surfaceContainerLow.opacity(0.4))
        )
    }
}
