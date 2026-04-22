import SwiftUI
import CinemaxKit

struct LoginScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel = LoginViewModel()
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
    }

    // MARK: - tvOS / iPad Layout

    private var tvOSLayout: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            backgroundGlow

            VStack(spacing: 0) {
                // Header
                Text(loc.localized("login.header"))
                    .font(CinemaFont.headline(.medium))
                    .tracking(4)
                    .foregroundStyle(CinemaColor.onSurface)
                    .padding(.top, 64)

                Spacer()

                // Login card
                VStack(spacing: CinemaSpacing.spacing8) {
                    // Decorative accent line
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, themeManager.accent, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 2)
                        .opacity(0.5)

                    // Title
                    VStack(spacing: CinemaSpacing.spacing2) {
                        Text(loc.localized("login.title"))
                            .font(.system(size: CinemaScale.pt(40), weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(CinemaColor.onSurface)

                        Text(loc.localized("login.subtitle"))
                            .font(CinemaFont.body)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Fields
                    VStack(spacing: CinemaSpacing.spacing4) {
                        GlassTextField(
                            label: loc.localized("login.username"),
                            text: $viewModel.username,
                            placeholder: loc.localized("login.usernamePlaceholder"),
                            icon: "person"
                        )

                        GlassTextField(
                            label: loc.localized("login.password"),
                            text: $viewModel.password,
                            placeholder: loc.localized("login.passwordPlaceholder"),
                            icon: "lock",
                            isSecure: true
                        )

                        if let error = viewModel.errorMessage {
                            errorBanner(error)
                        }
                    }

                    // Login button
                    CinemaButton(
                        title: loc.localized("login.button"),
                        style: .accent,
                        isLoading: viewModel.isAuthenticating
                    ) {
                        Task { await viewModel.authenticate(using: appState) }
                    }
                    .disabled(viewModel.isAuthenticating)
                }
                .padding(CinemaSpacing.spacing10)
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
                .frame(maxWidth: 600)

                Spacer()

                // Footer
                if let serverInfo = appState.serverInfo {
                    serverFooter(serverInfo)
                        .padding(.bottom, CinemaSpacing.spacing6)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing20)

            // Success toast
            if viewModel.showSuccess {
                successToast(loc.localized("login.serverConnected"))
            }
        }
    }

    // MARK: - Mobile Layout

    /// Structure is copied from `ServerSetupScreen.mobileLayout` verbatim so both setup
    /// screens share one visual rhythm. Only the strings, the icon, the field list, and
    /// the action area differ.
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
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(themeManager.accent)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 20)
                    .accessibilityHidden(true)

                    Text(loc.localized("login.header"))
                        .font(CinemaFont.label(.small))
                        .tracking(3)
                        .foregroundStyle(CinemaColor.onSurface)

                    Text(loc.localized("login.mobileTitle"))
                        .font(.system(size: CinemaScale.pt(28), weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(.white)

                    Text(loc.localized("login.mobileSubtitle"))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .padding(.bottom, CinemaSpacing.spacing8)

                // Input card — `.frame(maxWidth:)` caps the form width explicitly, since the
                // `.padding(.horizontal, spacing4)` pattern used by `ServerSetupScreen` gets
                // silently dropped on this tree under iOS 26. Capping the width (and letting
                // the VStack center it) gives the same visual result without relying on
                // padding that isn't taking effect.
                VStack(spacing: CinemaSpacing.spacing4) {
                    GlassTextField(
                        label: loc.localized("login.username"),
                        text: $viewModel.username,
                        placeholder: loc.localized("login.usernamePlaceholder"),
                        icon: "person"
                    )
                    #if os(iOS)
                    .keyboardType(.asciiCapable)
                    #endif

                    GlassTextField(
                        label: loc.localized("login.password"),
                        text: $viewModel.password,
                        placeholder: loc.localized("login.passwordPlaceholder"),
                        icon: "lock",
                        isSecure: true
                    )

                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                }
                .padding(CinemaSpacing.spacing4)
                .glassPanel(cornerRadius: CinemaRadius.large)
                .frame(maxWidth: formMaxWidth)

                Spacer()

                // Actions
                VStack(spacing: CinemaSpacing.spacing3) {
                    CinemaButton(
                        title: loc.localized("login.buttonMobile"),
                        style: .accent,
                        icon: "chevron.right",
                        isLoading: viewModel.isAuthenticating
                    ) {
                        Task { await viewModel.authenticate(using: appState) }
                    }
                    .disabled(viewModel.isAuthenticating)

                    helperLink(icon: "arrow.backward", title: loc.localized("login.changeServer")) {
                        appState.disconnectServer()
                    }
                    .padding(.top, CinemaSpacing.spacing2)
                }
                .frame(maxWidth: formMaxWidth)
                .padding(.bottom, CinemaSpacing.spacing6)
            }

            // Success toast
            if viewModel.showSuccess {
                successToast(loc.localized("login.authenticated"))
            }
        }
    }

    /// Mobile form/button max width — matches the visual inset of ServerSetupScreen's
    /// `.padding(.horizontal, spacing4)` (22pt each side) on a standard 390–440pt iPhone.
    private var formMaxWidth: CGFloat { 350 }

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

    // MARK: - Shared Components

    private var backgroundGlow: some View {
        ZStack {
            Circle()
                .fill(themeManager.accentContainer.opacity(0.15))
                .frame(width: 500, height: 500)
                .blur(radius: 120)
                .offset(x: -200, y: -300)

            Circle()
                .fill(themeManager.accent.opacity(0.1))
                .frame(width: 400, height: 400)
                .blur(radius: 120)
                .offset(x: 200, y: 300)
        }
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

    private func serverFooter(_ info: ServerInfo) -> some View {
        HStack(spacing: 12) {
            Text(loc.localized("login.server", info.name))
            Circle()
                .fill(themeManager.accentDim)
                .frame(width: 5, height: 5)
            Text(loc.localized("login.version", info.version))
        }
        .font(CinemaFont.label(.small))
        .tracking(1)
        .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.4))
        .textCase(.uppercase)
    }

    private func successToast(_ message: String) -> some View {
        VStack {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(themeManager.accentContainer)
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(themeManager.onAccent)
                }
                Text(message)
                    .font(.system(size: CinemaScale.pt(15), weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurface)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .glassPanel(cornerRadius: CinemaRadius.full)
            .shadow(color: .black.opacity(0.3), radius: 20)
            .padding(.top, 48)

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(duration: 0.5), value: viewModel.showSuccess)
    }
}
