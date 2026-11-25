import SwiftUI
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Profile")

/// The signed-in user's own account: avatar, name, server and password. Its
/// playback language preferences moved to Réglages → Lecture on 2026-11-24
/// (`PlaybackLanguageSection`).
///
/// Nothing here is admin: `AdminAPI.updateUserPassword` is an admin resetting
/// somebody ELSE's password and carries no proof of identity. This screen uses
/// `AuthAPI.changeOwnPassword`, which sends the current password, and is
/// therefore reachable by any signed-in user.
struct ProfileScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @Environment(ThemeManager.self) private var themeManager
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    @State private var model = ProfileModel()
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    var body: some View {
        content
        #if os(iOS)
            .navigationTitle(loc.localized("profile.title"))
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                header
                passwordSection
                Spacer(minLength: CinemaSpacing.spacing8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, pagePadding)
            .padding(.top, CinemaSpacing.spacing5)
        }
        // tvOS: no `.scrollClipDisabled()` — nothing here grows on focus, and
        // with the clip off the rows scrolled under the cover's header (the
        // design-system cover RULE). The title lives in that header.
        .background(CinemaColor.surface.ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: CinemaSpacing.spacing4) {
            UserAvatar(
                userId: appState.currentUserId,
                name: appState.currentUser?.name,
                primaryImageTag: appState.currentUser?.primaryImageTag,
                size: avatarSize
            )
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                Text(appState.currentUser?.name ?? "")
                    .font(CinemaFont.headline(.medium))
                    .foregroundStyle(CinemaColor.onSurface)
                if let server = appState.serverInfo?.name {
                    Text(server)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Password

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            sectionHeader(loc.localized("profile.password.section"))

            GlassTextField(
                label: loc.localized("profile.password.current"),
                text: $currentPassword,
                icon: "lock",
                isSecure: true
            )
            GlassTextField(
                label: loc.localized("profile.password.new"),
                text: $newPassword,
                icon: "lock.rotation",
                isSecure: true
            )
            GlassTextField(
                label: loc.localized("profile.password.confirm"),
                text: $confirmPassword,
                icon: "checkmark.shield",
                isSecure: true
            )

            CinemaButton(
                title: loc.localized("profile.password.change"),
                style: .accent,
                isLoading: model.isChangingPassword
            ) {
                Task { await changePassword() }
            }
            .frame(maxWidth: ctaWidth)
            .disabled(!canSubmitPassword)
            .opacity(canSubmitPassword ? 1 : 0.5)
        }
    }

    /// Every field filled. The match and the emptiness are checked at submit
    /// time so the user is TOLD what is wrong, rather than facing a button that
    /// is dead for a reason nothing on screen explains.
    private var canSubmitPassword: Bool {
        !model.isChangingPassword
            && !currentPassword.isEmpty
            && !newPassword.isEmpty
            && !confirmPassword.isEmpty
    }

    private func changePassword() async {
        guard newPassword == confirmPassword else {
            toast.error(loc.localized("profile.password.mismatch"))
            return
        }
        let outcome = await model.changePassword(
            current: currentPassword, new: newPassword, using: appState
        )
        switch outcome {
        case .success:
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            toast.success(loc.localized("profile.password.changed"))
        case .refused:
            toast.error(loc.localized("profile.password.rejected"))
        case .failed(let error):
            toast.error(loc.userFacingMessage(for: error))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(CinemaFont.label(.large))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .textCase(.uppercase)
            .tracking(1.2)
            .accessibilityAddTraits(.isHeader)
    }

    private var pagePadding: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pagePadding
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var avatarSize: CGFloat {
        #if os(tvOS)
        140
        #else
        64
        #endif
    }

    private var ctaWidth: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.ctaWidth
        #else
        .infinity
        #endif
    }
}

@MainActor
@Observable
final class ProfileModel {
    private(set) var isChangingPassword = false

    enum PasswordOutcome {
        case success
        /// The server rejected the change — in practice, a wrong current
        /// password. Kept apart from a transport failure so the message can say
        /// which it was.
        case refused
        case failed(any Error)
    }

    func changePassword(current: String, new: String, using appState: AppState) async -> PasswordOutcome {
        guard let userId = appState.currentUserId else { return .refused }
        isChangingPassword = true
        defer { isChangingPassword = false }
        do {
            try await appState.apiClient.changeOwnPassword(
                userId: userId, currentPassword: current, newPassword: new
            )
            return .success
        } catch {
            // Never log the error's description here: the payload carried the
            // password, and a server that echoes its request would put it in
            // the system log.
            logger.error("Password change failed")
            // The client maps the server's refusal to its own case, so this
            // layer never has to read a status code.
            if case JellyfinError.invalidCredentials = error { return .refused }
            return .failed(error)
        }
    }
}
