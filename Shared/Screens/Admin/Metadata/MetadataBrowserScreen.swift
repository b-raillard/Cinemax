#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Entry point for admin metadata editing from Settings.
/// Library picker first (users usually know which library an item is in),
/// then an items grid reusing `PosterCard` so admins find the item visually
/// instead of parsing long lists. Tap → `MetadataEditorScreen`.
struct MetadataBrowserScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    @State private var libraries: [BaseItemDto] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        AdminLoadStateContainer(
            isLoading: isLoading && libraries.isEmpty,
            errorMessage: errorMessage,
            isEmpty: !isLoading && libraries.isEmpty && errorMessage == nil,
            emptyIcon: "books.vertical",
            emptyTitle: loc.localized("admin.metadata.browser.empty.title"),
            emptySubtitle: loc.localized("admin.metadata.browser.empty.subtitle"),
            onRetry: { Task { await load() } }
        ) {
            ScrollView(showsIndicators: false) {
                AdminSectionGroup(loc.localized("admin.metadata.browser.pickLibrary")) {
                    ForEach(Array(libraries.enumerated()), id: \.element.id) { index, library in
                        NavigationLink {
                            MetadataLibraryItemsScreen(library: library)
                        } label: {
                            libraryRow(library)
                        }
                        .buttonStyle(.plain)
                        if index < libraries.count - 1 {
                            iOSSettingsDivider
                        }
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.top, CinemaSpacing.spacing4)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.metadata.title"))
        .navigationBarTitleDisplayMode(.large)
        .task { if libraries.isEmpty { await load() } }
    }

    @ViewBuilder
    private func libraryRow(_ library: BaseItemDto) -> some View {
        iOSSettingsRow {
            HStack(spacing: CinemaSpacing.spacing3) {
                iOSRowIcon(systemName: iconName(for: library), color: themeManager.accent)
                Text(library.name ?? "—")
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(CinemaColor.outlineVariant)
            }
        }
    }

    private func iconName(for library: BaseItemDto) -> String {
        switch library.collectionType?.rawValue.lowercased() ?? "" {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "books": return "book"
        case "boxsets": return "square.stack.3d.up"
        default: return "folder"
        }
    }

    private func load() async {
        isLoading = libraries.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            libraries = try await appState.apiClient.getMediaFolders()
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Second level: items grid for a single library with a search bar.
/// Reuses `PosterCard`-style aspect ratios — admins recognise items by art.
struct MetadataLibraryItemsScreen: View {
    let library: BaseItemDto

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var items: [BaseItemDto] = []
    @State private var searchText: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 5 : 3
        return Array(repeating: GridItem(.flexible(), spacing: CinemaSpacing.spacing2), count: count)
    }

    private var filteredItems: [BaseItemDto] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { ($0.name ?? "").lowercased().contains(query) }
    }

    var body: some View {
        AdminLoadStateContainer(
            isLoading: isLoading && items.isEmpty,
            errorMessage: errorMessage,
            isEmpty: !isLoading && items.isEmpty && errorMessage == nil,
            emptyIcon: "tray",
            emptyTitle: loc.localized("admin.metadata.browser.items.empty.title"),
            emptySubtitle: nil,
            onRetry: { Task { await load() } }
        ) {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: gridColumns, spacing: CinemaSpacing.spacing3) {
                    ForEach(filteredItems, id: \.id) { item in
                        NavigationLink {
                            MetadataEditorScreen(item: item)
                        } label: {
                            itemTile(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.top, CinemaSpacing.spacing3)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(library.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: loc.localized("admin.metadata.browser.items.searchPrompt"))
        .task { if items.isEmpty { await load() } }
    }

    @ViewBuilder
    private func itemTile(_ item: BaseItemDto) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    CinemaLazyImage(
                        url: appState.imageBuilder.imageURL(
                            itemId: item.id ?? "",
                            imageType: .primary,
                            maxWidth: 300
                        ),
                        fallbackIcon: "film"
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                .clipped()

            Text(item.name ?? "—")
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurface)
                .lineLimit(2, reservesSpace: true)

            if let year = item.productionYear {
                Text(String(year))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
        }
    }

    private func load() async {
        guard let parentId = library.id else { return }
        isLoading = items.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (fetched, _) = try await appState.apiClient.getItems(
                userId: appState.currentUserId ?? "",
                parentId: parentId,
                includeItemTypes: nil,
                sortBy: [.sortName],
                sortOrder: nil,
                genres: nil,
                years: nil,
                isFavorite: nil,
                filters: nil,
                limit: 500,
                startIndex: nil
            )
            items = fetched
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
