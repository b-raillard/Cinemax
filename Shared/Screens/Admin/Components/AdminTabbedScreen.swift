#if os(iOS)
import SwiftUI
import CinemaxKit

/// Horizontally-scrolling pill-tab bar matching the `LibrarySortFilterSheet`
/// segmented pattern. Used by the admin User detail (Profile / Access /
/// Parental / Password) and — in P3b — the Metadata editor tabs.
///
/// The bar is surfaced as a standalone subview so callers can compose it above
/// a form, a list, or mixed content — we don't impose a container shape.
@MainActor
struct AdminTabBar<Tab: Hashable>: View {
    struct Item: Identifiable {
        let id: Tab
        let label: String
    }

    let items: [Item]
    @Binding var selection: Tab

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.motionEffectsEnabled) private var motionEnabled

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CinemaSpacing.spacing2) {
                ForEach(items) { item in
                    tabButton(item)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing2)
        }
        .background(CinemaColor.surfaceContainerLowest)
    }

    @ViewBuilder
    private func tabButton(_ item: Item) -> some View {
        let isSelected = selection == item.id
        Button {
            withAnimation(motionEnabled ? .easeInOut(duration: 0.15) : nil) {
                selection = item.id
            }
        } label: {
            Text(item.label)
                .font(.system(size: CinemaScale.pt(15), weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(isSelected ? .white : CinemaColor.onSurfaceVariant)
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.vertical, CinemaSpacing.spacing2)
                .background {
                    if isSelected {
                        Capsule().fill(themeManager.accent)
                    } else {
                        Capsule().fill(CinemaColor.surfaceContainerHigh)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
#endif
