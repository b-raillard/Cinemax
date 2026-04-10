import SwiftUI

struct ContentRow<Content: View>: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    let title: String
    var showViewAll: Bool = false
    var onViewAll: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            // Header
            HStack {
                Text(title)
                    .font(CinemaFont.headline(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                if showViewAll {
                    Button {
                        onViewAll?()
                    } label: {
                        HStack(spacing: 4) {
                            Text(loc.localized("action.viewAll"))
                                .font(CinemaFont.label(.large))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(themeManager.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, CinemaSpacing.spacing6)

            // Scrollable content
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                    content()
                }
                .padding(.horizontal, CinemaSpacing.spacing6)
                #if os(tvOS)
                .padding(.vertical, CinemaSpacing.spacing2)
                #endif
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }
}
