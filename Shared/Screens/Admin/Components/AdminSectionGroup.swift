#if os(iOS)
import SwiftUI
import CinemaxKit

/// iOS grouped-list section: uppercase header + glass-panel rows block.
/// Mirrors the pattern used throughout `SettingsScreen+iOS` but reusable
/// without importing that file's private helpers.
///
/// Callers own divider placement within `content` (use `iOSSettingsDivider`
/// from `SettingsRowHelpers`) — this keeps mixed-row sections (toggle + custom
/// row + chevron) flexible.
@MainActor
struct AdminSectionGroup<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            if let title {
                iOSSettingsSectionHeader(title)
            }

            VStack(spacing: 0) {
                content
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)

            if let footer {
                Text(footer)
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.horizontal, CinemaSpacing.spacing3)
                    .padding(.top, CinemaSpacing.spacing1)
            }
        }
    }
}
#endif
