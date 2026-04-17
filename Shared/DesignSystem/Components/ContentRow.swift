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
                    ForEach(data, id: id, content: itemView)
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
