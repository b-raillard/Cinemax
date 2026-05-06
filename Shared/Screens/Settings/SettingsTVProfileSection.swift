import SwiftUI
import CinemaxKit
import JellyfinAPI

#if os(tvOS)

// MARK: - tvOS Profile Section

extension SettingsScreen {

    var currentUserId: String {
        appState.currentUserId ?? ""
    }

    var displayUsers: [UserDto] {
        let users: [UserDto]
        if serverUsers.isEmpty {
            if let session = appState.keychain.getUserSession() {
                users = [UserDto(id: session.userID, name: session.username)]
            } else {
                users = []
            }
        } else {
            users = serverUsers
        }
        return users.sorted { a, _ in a.id == currentUserId }
    }

    var tvProfileSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvSectionLabel(loc.localized("settings.profiles"))

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: CinemaSpacing.spacing3),
                    GridItem(.flexible(), spacing: CinemaSpacing.spacing3),
                    GridItem(.flexible(), spacing: CinemaSpacing.spacing3)
                ],
                spacing: CinemaSpacing.spacing3
            ) {
                ForEach(displayUsers, id: \.id) { user in
                    tvProfileBlock(user: user)
                }

                tvSwitchAccountBlock
            }
        }
    }

    func tvProfileBlock(user: UserDto) -> some View {
        let userId = user.id ?? ""
        let isCurrentUser = userId == currentUserId
        let hasImage = user.primaryImageTag != nil
        let isFocused = focusedItem == .profile(userId)

        return Button {
            if !isCurrentUser { showUserSwitch = true }
        } label: {
            VStack(spacing: CinemaSpacing.spacing2) {
                Group {
                    if hasImage, appState.serverURL != nil {
                        let imageURL = appState.imageBuilder
                            .userImageURL(userId: userId, tag: user.primaryImageTag, maxWidth: 96)
                        // Initial serves as placeholder (while loading) and
                        // fallback (on 404); CinemaLazyImage draws above it
                        // once the image resolves (fallbackBackground is clear
                        // so the initial shows through on transient states).
                        tvUserInitial(name: user.name ?? "?", size: 36)
                            .overlay {
                                CinemaLazyImage(
                                    url: imageURL,
                                    fallbackIcon: nil,
                                    fallbackBackground: .clear
                                )
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    } else {
                        tvUserInitial(name: user.name ?? "?", size: 36)
                    }
                }
                .opacity(isCurrentUser ? 1.0 : 0.55)

                Text(user.name ?? "User")
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .lineLimit(1)

                if isCurrentUser {
                    Text(loc.localized("settings.active"))
                        .font(.system(size: CinemaScale.pt(13), weight: .bold))
                        .foregroundStyle(CinemaColor.success)
                } else {
                    Text(user.policy?.isAdministrator == true ? loc.localized("settings.admin") : loc.localized("settings.user"))
                        .font(.system(size: CinemaScale.pt(13), weight: .medium))
                        .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(.vertical, CinemaSpacing.spacing3)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .profile(userId))
    }

    var tvSwitchAccountBlock: some View {
        let isFocused = focusedItem == .switchAccount

        return Button {
            showUserSwitch = true
        } label: {
            VStack(spacing: CinemaSpacing.spacing2) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .frame(width: 36, height: 36)

                Text(loc.localized("settings.switchAccount"))
                    .font(.system(size: CinemaScale.pt(17), weight: .semibold))
                    .foregroundStyle(isFocused ? CinemaColor.onSurface : CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(.vertical, CinemaSpacing.spacing3)
            .tvSettingsFocusable(isFocused: isFocused, accent: themeManager.accent, colorScheme: themeManager.darkModeEnabled ? .dark : .light)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedItem, equals: .switchAccount)
    }

    func tvUserInitial(name: String, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [themeManager.accentContainer, themeManager.accent.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

#endif
