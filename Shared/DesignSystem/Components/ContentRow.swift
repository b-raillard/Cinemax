import SwiftUI

/// Horizontally-scrollable titled row. Data-driven so the internal `ForEach` is
/// guaranteed — `LazyHStack` only defers instantiation when its child is a
/// `ForEach` that carries identity. An unconstrained `@ViewBuilder` closure
/// would let a caller pass a tuple of N views, which SwiftUI would construct
/// eagerly and defeat the laziness.
///
/// The header is the plain `title` (+ optional "View All") unless the caller
/// passes a `header:` of its own — Home's « Parce que vous avez vu » row puts
/// the seed's poster and name there, because one line of
/// « Parce que vous avez vu {titre} » truncated the very title it names.
struct ContentRow<Data: RandomAccessCollection, ItemID: Hashable, ItemView: View, Header: View>: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    let title: String
    var showViewAll: Bool = false
    var onViewAll: (() -> Void)? = nil
    /// A season row's display face (`SeasonalTypography.titleFont`); `nil` = the headline.
    var titleFont: Font?
    let data: Data
    let id: KeyPath<Data.Element, ItemID>
    @ViewBuilder let itemView: (Data.Element) -> ItemView
    /// Replaces the title row when set; `title` is then unused.
    var header: Header?

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Group {
                if let header {
                    header
                } else {
                    titleRow
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

    private var titleRow: some View {
        HStack {
            Text(title)
                .font(titleFont ?? CinemaFont.headline(.large))
                // A season's display face runs wider than the system
                // headline: « Frissons d'Halloween » truncated on iPhone.
                .minimumScaleFactor(titleFont == nil ? 1 : 0.7)
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

extension ContentRow where Header == EmptyView {
    /// The common case: a plain title row.
    init(
        title: String,
        showViewAll: Bool = false,
        onViewAll: (() -> Void)? = nil,
        titleFont: Font? = nil,
        data: Data,
        id: KeyPath<Data.Element, ItemID>,
        @ViewBuilder itemView: @escaping (Data.Element) -> ItemView
    ) {
        self.title = title
        self.showViewAll = showViewAll
        self.onViewAll = onViewAll
        self.titleFont = titleFont
        self.data = data
        self.id = id
        self.itemView = itemView
        self.header = nil
    }
}

extension ContentRow {
    /// A row whose header is the caller's own view (it gets the row's
    /// horizontal padding, nothing else).
    init(
        data: Data,
        id: KeyPath<Data.Element, ItemID>,
        @ViewBuilder header: () -> Header,
        @ViewBuilder itemView: @escaping (Data.Element) -> ItemView
    ) {
        self.title = ""
        self.data = data
        self.id = id
        self.itemView = itemView
        self.header = header()
    }
}
