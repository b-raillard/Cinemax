import SwiftUI
import CinemaxKit

/// Circular avatar for Jellyfin users: primary image when available, accent
/// gradient + initial as the fallback.
///
/// The gradient is rendered unconditionally underneath the image — when the
/// image 404s (user has no primary), `CinemaLazyImage.fallbackBackground = .clear`
/// lets the gradient show through, which also covers the initial async window
/// before `primaryImageTag` has been fetched.
///
/// Used by `UserSwitchSheet`, the Settings profile header, and the Admin
/// `AdminUsersScreen` grid — three identical implementations collapsed here.
struct UserAvatar: View {
    let userId: String?
    let name: String?
    let primaryImageTag: String?
    let size: CGFloat

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager

    init(userId: String?, name: String?, primaryImageTag: String?, size: CGFloat) {
        self.userId = userId
        self.name = name
        self.primaryImageTag = primaryImageTag
        self.size = size
    }

    var body: some View {
        let initial = String((name ?? "?").prefix(1)).uppercased()

        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [themeManager.accentContainer, themeManager.accent.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initial)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay {
            if let id = userId {
                CinemaLazyImage(
                    url: appState.imageBuilder.userImageURL(
                        userId: id,
                        tag: primaryImageTag,
                        maxWidth: min(400, Int(size * 2))
                    ),
                    fallbackIcon: nil,
                    fallbackBackground: .clear
                )
                .clipShape(Circle())
            }
        }
    }
}
