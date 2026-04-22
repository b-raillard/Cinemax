import SwiftUI
import CinemaxKit
#if canImport(UIKit)
import UIKit
#endif

struct ServerSetupScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @State private var viewModel = ServerSetupViewModel()
    @State private var showDiscoverySheet = false
    @State private var showHelpSheet = false
    @State private var easterEggTaps: Int = 0
    @AppStorage(SettingsKey.rainbowUnlocked) private var rainbowUnlocked: Bool = SettingsKey.Default.rainbowUnlocked
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
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
        #if os(tvOS)
        .fullScreenCover(isPresented: $showDiscoverySheet) {
            ServerDiscoverySheet { address in
                viewModel.serverURL = address
            }
        }
        .fullScreenCover(isPresented: $showHelpSheet) {
            ServerHelpSheet()
        }
        #else
        .sheet(isPresented: $showDiscoverySheet) {
            ServerDiscoverySheet { address in
                viewModel.serverURL = address
            }
        }
        .sheet(isPresented: $showHelpSheet) {
            ServerHelpSheet()
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
                    .font(CinemaFont.headline(.medium))
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
                        .font(CinemaFont.label(.large))
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

                    if isHTTPURL(viewModel.serverURL) {
                        httpWarningBanner
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
                    helperLink(icon: "wifi.router", title: loc.localized("server.findOnNetwork")) {
                        showDiscoverySheet = true
                    }
                    Divider()
                        .frame(height: 20)
                        .overlay(CinemaColor.outlineVariant.opacity(0.3))
                    helperLink(icon: "questionmark.circle", title: loc.localized("server.howToFind")) {
                        showHelpSheet = true
                    }
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
                    // Icon — secretly doubles as the accent-cycling easter egg.
                    Button {
                        triggerEasterEgg()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: CinemaRadius.extraLarge)
                                .fill(CinemaColor.surfaceContainerHigh)
                                .frame(width: 80, height: 80)
                            Image(systemName: "server.rack")
                                .font(.system(size: 36))
                                .foregroundStyle(themeManager.accent)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)

                    Text(loc.localized("server.header"))
                        .font(CinemaFont.label(.small))
                        .tracking(3)
                        .foregroundStyle(CinemaColor.onSurface)

                    Text(loc.localized("server.mobileTitle"))
                        .font(.system(size: CinemaScale.pt(28), weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(.white)

                    Text(loc.localized("server.mobileSubtitle"))
                        .font(CinemaFont.label(.small))
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

                    if isHTTPURL(viewModel.serverURL) {
                        httpWarningBanner
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

                    HStack(spacing: CinemaSpacing.spacing4) {
                        helperLink(icon: "wifi.router", title: loc.localized("server.findOnNetwork")) {
                            showDiscoverySheet = true
                        }
                        Divider()
                            .frame(height: 16)
                            .overlay(CinemaColor.outlineVariant.opacity(0.3))
                        helperLink(icon: "questionmark.circle", title: loc.localized("server.howToFind")) {
                            showHelpSheet = true
                        }
                    }
                    .padding(.top, CinemaSpacing.spacing2)
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

    /// True when the user has explicitly typed `http://` (not `https://`). We do NOT warn on
    /// scheme-less input because `ServerSetupViewModel.connect` defaults missing-scheme input
    /// to HTTPS. Trimming matches the VM's behavior so the warning tracks what will actually
    /// be dialed.
    private func isHTTPURL(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("http://")
    }

    private var httpWarningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(Color.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.localized("server.httpWarning.title"))
                    .font(CinemaFont.label(.medium).weight(.semibold))
                    .foregroundStyle(CinemaColor.onSurface)
                Text(loc.localized("server.httpWarning.message"))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.medium)
                .fill(Color.orange.opacity(0.15))
        )
        .accessibilityElement(children: .combine)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(CinemaColor.error)
            Text(message)
                .font(CinemaFont.label(.small))
                .foregroundStyle(CinemaColor.error)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CinemaRadius.medium)
                .fill(CinemaColor.errorContainer.opacity(0.2))
        )
    }

    private func triggerEasterEgg() {
        let result = AccentEasterEgg.tap(
            currentAccentKey: themeManager.accentColorKey,
            previousTapCount: easterEggTaps,
            rainbowAlreadyUnlocked: rainbowUnlocked
        )
        easterEggTaps += 1
        themeManager.accentColorKey = result.nextAccentKey
        if result.unlockedRainbow {
            rainbowUnlocked = true
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            toasts.success(
                loc.localized("easterEgg.rainbow.title"),
                message: loc.localized("easterEgg.rainbow.message")
            )
        } else {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        }
    }

    private func helperLink(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(CinemaFont.label(.medium))
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
                .font(CinemaFont.label(.small))
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
