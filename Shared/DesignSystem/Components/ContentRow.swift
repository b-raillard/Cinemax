import SwiftUI

/// Horizontally-scrollable titled row. Data-driven so the internal `ForEach` is
/// guaranteed — `LazyHStack` only defers instantiation when its child is a
/// `ForEach` that carries identity. An unconstrained `@ViewBuilder` closure
/// would let a caller pass a tuple of N views, which SwiftUI would construct
/// eagerly and defeat the laziness.
struct ContentRow<Data: RandomAccessCollection, ItemID: Hashable, ItemView: View>: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    let title: String
    var showViewAll: Bool = false
    var onViewAll: (() -> Void)? = nil
    let data: Data
    let id: KeyPath<Data.Element, ItemID>
    @ViewBuilder let itemView: (Data.Element) -> ItemView

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
                                .font(.system(size: CinemaScale.pt(12), weight: .semibold))
                        }
                        .foregroundStyle(themeManager.accent)
                        #if os(tvOS)
                        // Needs a shape of its own to carry the focus stroke —
                        // bare text was the one focusable control on Home left
                        // with the system's own chrome.
                        .padding(.horizontal, CinemaSpacing.spacing3)
                        .padding(.vertical, CinemaSpacing.spacing2)
                        .background(CinemaColor.surfaceContainerHigh, in: Capsule())
                        #endif
                    }
                    #if os(tvOS)
                    .buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))
                    .focusEffectDisabled()
                    .hoverEffectDisabled()
                    #else
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal, horizontalPadding)

            // Scrollable content
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                    ForEach(data, id: id, content: itemView)
                }
                .padding(.horizontal, horizontalPadding)
                #if os(tvOS)
                .padding(.vertical, CinemaSpacing.spacing2)
                #endif
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    /// A rail is one page element among others, so its header and its first
    /// card must line up with the hero title, the grid and the top bar above
    /// them. tvOS pages sit at `pagePadding` (112 pt) while this row was fixed
    /// at 32 pt, which is why every rail on Home and the detail fiche read as
    /// visibly indented out of the page's own column.
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        CinemaTVLayout.pagePadding
        #else
        CinemaSpacing.spacing6
        #endif
    }
}
