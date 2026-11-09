import SwiftUI

/// The header's trailing action (« Tout demander », …).
struct MissingHeaderAction {
    let label: String
    let perform: () -> Void
}

/// « Pas encore dans ta bibliothèque »: header (title, count, action) over a
/// row of caller-built cards. Renders NOTHING for `.hidden` and `.loaded([])`
/// — never an empty header — and skeletons while `.loading`.
struct MissingTitlesRow<Element: Identifiable & Equatable & Sendable, Card: View>: View {
    @Environment(ThemeManager.self) private var themeManager
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    let title: String
    let count: String?
    let section: MissingSection<Element>
    let headerAction: MissingHeaderAction?
    /// Matches the neighbouring rows (`CinemaTVLayout.posterCardWidth` on tvOS).
    let cardWidth: CGFloat
    @ViewBuilder let card: (Element) -> Card

    init(
        title: String,
        count: String?,
        section: MissingSection<Element>,
        headerAction: MissingHeaderAction?,
        cardWidth: CGFloat,
        @ViewBuilder card: @escaping (Element) -> Card
    ) {
        self.title = title
        self.count = count
        self.section = section
        self.headerAction = headerAction
        self.cardWidth = cardWidth
        self.card = card
    }

    private static var skeletonCount: Int {
        #if os(tvOS)
        5
        #else
        4
        #endif
    }

    var body: some View {
        switch section {
        case .hidden:
            EmptyView()
        case .loading:
            ContentRow(data: Array(0..<Self.skeletonCount), id: \.self) {
                header(count: nil, action: nil)
            } itemView: { _ in
                SkeletonBlock()
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(width: cardWidth)
                    .accessibilityHidden(true)
                    #if os(tvOS)
                    .focusable(false)
                    #endif
            }
        case .loaded(let elements):
            if !elements.isEmpty {
                ContentRow(data: rowItems(elements), id: \.id) {
                    header(count: count, action: headerAction)
                } itemView: { item in
                    switch item {
                    case .card(let element):
                        card(element).frame(width: cardWidth)
                    case .action(let action):
                        #if os(tvOS)
                        actionCard(action)
                        #else
                        EmptyView()
                        #endif
                    }
                }
            }
        }
    }

    private func header(count: String?, action: MissingHeaderAction?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CinemaSpacing.spacing2) {
            Text(title)
                .font(titleFont)
                .minimumScaleFactor(0.85)
                .foregroundStyle(CinemaColor.onSurface)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(count)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                    .lineLimit(1)
            }
            Spacer()
            #if !os(tvOS)
            if let action {
                Button(action: action.perform) {
                    Text(action.label)
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(themeManager.accent)
                }
                .buttonStyle(.plain)
            }
            #endif
        }
    }

    private enum RowItem: Identifiable {
        case card(Element)
        case action(MissingHeaderAction)

        var id: String {
            switch self {
            case .card(let element): "card-\(element.id)"
            case .action: "action"
            }
        }
    }

    /// tvOS: the action closes the row as a card (a header link is out of the
    /// focus beam of a short row — see ContentRow's « Tout voir »).
    private func rowItems(_ elements: [Element]) -> [RowItem] {
        var items = elements.map(RowItem.card)
        #if os(tvOS)
        if let headerAction { items.append(.action(headerAction)) }
        #endif
        return items
    }

    #if os(tvOS)
    private func actionCard(_ action: MissingHeaderAction) -> some View {
        Button(action: action.perform) {
            Text(action.label)
                .font(CinemaFont.label(.large))
                .multilineTextAlignment(.center)
                .foregroundStyle(themeManager.accent)
                .padding(CinemaSpacing.spacing3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(2 / 3, contentMode: .fit)
                .background(CinemaColor.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: CinemaRadius.large))
                .cinemaFocus()
        }
        .buttonStyle(CinemaTVCardButtonStyle())
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .frame(width: cardWidth)
        .accessibilityLabel(action.label)
    }
    #endif

    private var titleFont: Font {
        #if os(tvOS)
        CinemaFont.headline(.large)
        #else
        AdaptiveLayout.sectionTitleFont(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }
}

#if DEBUG
private struct PreviewMissing: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
}

#Preview("MissingTitlesRow — skeleton + loaded") {
    #if os(tvOS)
    let width = CinemaTVLayout.posterCardWidth
    #else
    let width: CGFloat = 130
    #endif
    let items = (1...6).map { PreviewMissing(id: $0, title: "Film \($0)") }
    return ScrollView {
        VStack(spacing: CinemaSpacing.spacing6) {
            MissingTitlesRow<PreviewMissing, MissingTitleCard>(
                title: "Pas encore dans ta bibliothèque", count: nil, section: .loading,
                headerAction: nil, cardWidth: width
            ) { _ in MissingTitleCard(title: "", subtitle: nil, badge: .request) }
            MissingTitlesRow(
                title: "Pas encore dans ta bibliothèque", count: "6", section: .loaded(items),
                headerAction: MissingHeaderAction(label: "Tout demander", perform: {}), cardWidth: width
            ) { item in
                MissingTitleCard(title: item.title, subtitle: "2024", badge: item.id % 2 == 0 ? .pending : .request)
            }
        }
    }
    .background(CinemaColor.surfaceContainerLowest)
    .environment(ThemeManager())
    .environment(LocalizationManager())
}
#endif
