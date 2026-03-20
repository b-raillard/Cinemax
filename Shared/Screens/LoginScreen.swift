import SwiftUI
import CinemaxKit

@MainActor @Observable
final class LoginViewModel {
    var username: String = ""
    var password: String = ""
    var isAuthenticating = false
    var errorMessage: String?
    var showSuccess = false

    func authenticate(using appState: AppState) async {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter your username."
            return
        }

        isAuthenticating = true
        errorMessage = nil

        do {
            let session = try await appState.apiClient.authenticate(
                username: username,
                password: password
            )
            try appState.keychain.saveAccessToken(session.accessToken)
            try appState.keychain.saveUserSession(session)

            appState.accessToken = session.accessToken
            appState.currentUserId = session.userID

            showSuccess = true

            try? await Task.sleep(for: .seconds(1))

            appState.isAuthenticated = true
        } catch {
            errorMessage = "Authentication failed: \(error.localizedDescription)"
        }

        isAuthenticating = false
    }
}

struct LoginScreen: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = LoginViewModel()
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
            backgroundGlow

            VStack(spacing: 0) {
                // Header
                Text("JELLYFIN")
                    .font(.system(size: 28, weight: .bold))
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
                                colors: [.clear, CinemaColor.tertiary, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 2)
                        .opacity(0.5)

                    // Title
                    VStack(spacing: CinemaSpacing.spacing2) {
                        Text("USER LOGIN")
                            .font(.system(size: 40, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(CinemaColor.onSurface)

                        Text("Enter your credentials to access your library")
                            .font(.system(size: 18))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }

                    // Fields
                    VStack(spacing: CinemaSpacing.spacing4) {
                        GlassTextField(
                            label: "Username",
                            text: $viewModel.username,
                            placeholder: "Your Username",
                            icon: "person"
                        )

                        GlassTextField(
                            label: "Password",
                            text: $viewModel.password,
                            placeholder: "••••••••",
                            icon: "lock",
                            isSecure: true
                        )

                        if let error = viewModel.errorMessage {
                            errorBanner(error)
                        }
                    }

                    // Login button
                    CinemaButton(
                        title: "LOG IN",
                        style: .primary,
                        isLoading: viewModel.isAuthenticating
                    ) {
                        Task { await viewModel.authenticate(using: appState) }
                    }
                    .disabled(viewModel.isAuthenticating)

                    // Secondary actions
                    HStack(spacing: CinemaSpacing.spacing6) {
                        secondaryButton("Forgot Password?")
                        secondaryButton("Create Account")
                    }
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
                successToast("Server Connected!")
            }
        }
    }

    // MARK: - Mobile Layout

    private var mobileLayout: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            backgroundGlow

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 60)

                    // Logo
                    VStack(spacing: CinemaSpacing.spacing3) {
                        ZStack {
                            RoundedRectangle(cornerRadius: CinemaRadius.large)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: CinemaRadius.large)
                                        .stroke(.white.opacity(0.1), lineWidth: 1)
                                )
                                .frame(width: 80, height: 80)
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(CinemaColor.onSurface)
                        }

                        Text("JELLYFIN")
                            .font(.system(size: 32, weight: .black))
                            .tracking(-1)
                            .foregroundStyle(.white)

                        Text("Your Media, Simplified")
                            .font(.system(size: 12, weight: .medium))
                            .tracking(2)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .textCase(.uppercase)
                    }
                    .padding(.bottom, CinemaSpacing.spacing8)

                    // Form
                    VStack(spacing: CinemaSpacing.spacing4) {
                        Text("Login")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)

                        GlassTextField(
                            label: "",
                            text: $viewModel.username,
                            placeholder: "Username",
                            icon: "person"
                        )

                        GlassTextField(
                            label: "",
                            text: $viewModel.password,
                            placeholder: "Password",
                            icon: "lock",
                            isSecure: true
                        )

                        if let error = viewModel.errorMessage {
                            errorBanner(error)
                        }

                        CinemaButton(
                            title: "Login",
                            style: .accent,
                            icon: "chevron.right",
                            isLoading: viewModel.isAuthenticating
                        ) {
                            Task { await viewModel.authenticate(using: appState) }
                        }
                        .disabled(viewModel.isAuthenticating)

                        VStack(spacing: 12) {
                            secondaryButton("Forgot Password?")

                            HStack(spacing: 4) {
                                Text("Don't have a server?")
                                    .font(CinemaFont.label(.large))
                                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                                Button("Join Community") {}
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(CinemaColor.tertiary)
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, CinemaSpacing.spacing2)
                    }
                    .padding(.horizontal, CinemaSpacing.spacing4)

                    Spacer(minLength: 40)
                }
            }
            .scrollDismissesKeyboard(.interactively)

            // Bottom accent line
            VStack {
                Spacer()
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, CinemaColor.tertiary.opacity(0.3), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 2)
            }
            .ignoresSafeArea()

            // Success toast
            if viewModel.showSuccess {
                successToast("Authenticated!")
            }
        }
    }

    // MARK: - Shared Components

    private var backgroundGlow: some View {
        ZStack {
            Circle()
                .fill(CinemaColor.tertiaryContainer.opacity(0.15))
                .frame(width: 500, height: 500)
                .blur(radius: 120)
                .offset(x: -200, y: -300)

            Circle()
                .fill(CinemaColor.tertiary.opacity(0.1))
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

    private func secondaryButton(_ title: String) -> some View {
        Button {} label: {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .buttonStyle(.plain)
    }

    private func serverFooter(_ info: ServerInfo) -> some View {
        HStack(spacing: 12) {
            Text("Server: \(info.name)")
            Circle()
                .fill(CinemaColor.tertiaryDim)
                .frame(width: 5, height: 5)
            Text("Version \(info.version)")
        }
        .font(.system(size: 13, weight: .medium))
        .tracking(1)
        .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.4))
        .textCase(.uppercase)
    }

    private func successToast(_ message: String) -> some View {
        VStack {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(CinemaColor.tertiaryContainer)
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(CinemaColor.onTertiary)
                }
                Text(message)
                    .font(.system(size: 15, weight: .semibold))
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
