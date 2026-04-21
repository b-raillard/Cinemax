import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - View

struct SearchScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var searchFieldFocused: Bool
    #endif
    @State private var viewModel = SearchViewModel()

    // Surprise Me state — two buttons (movie + series) in the empty state.
    @State private var surpriseDestination: SurpriseDestination?
    @State private var isPickingSurpriseMovie = false
    @State private var isPickingSurpriseSeries = false

    private struct SurpriseDestination: Identifiable, Hashable {
        let id: String
        let itemType: BaseItemKind
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        AdaptiveLayout.posterGridColumns(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            #if os(tvOS)
            // tvOS path is wrapped in a ScrollView + ScrollViewReader so we can
            // force the page back to the top whenever it reappears (e.g., user
            // pops back from a result detail). This is what surfaces the tvOS
            // top tab bar — it stays hidden when content overlaps its area.
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("search.top")
                    VStack(spacing: 0) {
                        searchField
                        resultContent
                    }
                    .frame(maxWidth: .infinity, minHeight: 720, maxHeight: .infinity)
                }
                .scrollClipDisabled()
                .onAppear {
                    proxy.scrollTo("search.top", anchor: .top)
                }
            }
            #else
            VStack(spacing: 0) {
                searchField
                listeningLabel
                resultContent
            }
            #endif
        }
        .navigationDestination(item: $surpriseDestination) { dest in
            MediaDetailScreen(itemId: dest.id, itemType: dest.itemType)
        }
        #if os(iOS)
        .background {
            // ⌘F focuses the search field. Hidden button → keyboard-only affordance
            // (the shortcut fires even though the button is off-screen).
            Button("") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .navigationTitle(loc.localized("search.title"))
        .alert(loc.localized("search.permissionRequired"), isPresented: Bindable(viewModel).showPermissionAlert) {
            Button(loc.localized("search.openSettings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: {
            Text(viewModel.permissionAlertMessage)
        }
        .onDisappear {
            // Stop any active recognition session when leaving the screen
            if viewModel.isListening {
                viewModel.stopListening()
            }
        }
        #endif
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .font(.system(size: searchIconSize))
                .accessibilityHidden(true)

            TextField(loc.localized("search.placeholder"), text: Bindable(viewModel).searchText)
                #if os(iOS)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                #endif
                .font(.system(size: searchFontSize))
                .foregroundStyle(CinemaColor.onSurface)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: viewModel.searchText) {
                    viewModel.search(using: appState)
                }

            // Microphone button — iOS only
            #if os(iOS)
            VoiceSearchButton(
                isListening: viewModel.isListening,
                iconSize: searchIconSize,
                onTap: { viewModel.toggleListening(using: appState) }
            )
            #endif

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    viewModel.results = []
                    viewModel.hasSearched = false
                    #if os(iOS)
                    if viewModel.isListening {
                        viewModel.stopListening()
                    }
                    #endif
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.localized("accessibility.clearSearch"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CinemaColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        .padding(.horizontal, gridPadding)
        .padding(.vertical, CinemaSpacing.spacing3)
    }

    // MARK: - Listening Label (iOS only)

    #if os(iOS)
    @ViewBuilder
    private var listeningLabel: some View {
        if viewModel.isListening {
            Text(loc.localized("search.listening"))
                .font(CinemaFont.label(.large))
                .foregroundStyle(themeManager.accent)
                .padding(.bottom, CinemaSpacing.spacing1)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    #endif

    // MARK: - Results

    @ViewBuilder
    private var resultContent: some View {
        if viewModel.isSearching {
            Spacer()
            LoadingStateView()
            Spacer()
        } else if viewModel.results.isEmpty && viewModel.hasSearched {
            Spacer()
            VStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaColor.outlineVariant)
                    .accessibilityHidden(true)
                Text(loc.localized("search.noResults"))
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            Spacer()
        } else if viewModel.results.isEmpty {
            Spacer()
            VStack(spacing: CinemaSpacing.spacing4) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaColor.outlineVariant)
                    .accessibilityHidden(true)
                Text(loc.localized("search.searchLibrary"))
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)

                // "Not sure what to watch?" → two pills for a random movie or series.
                surpriseMePills
            }
            Spacer()
        } else {
            SearchResultsGrid(
                results: viewModel.results,
                imageBuilder: appState.imageBuilder,
                columns: columns,
                gridPadding: gridPadding,
                gridSpacing: gridSpacing,
                headerTitle: loc.localized("search.topMatches")
            )
        }
    }

    // MARK: - Surprise Me

    private var surpriseMePills: some View {
        VStack(spacing: CinemaSpacing.spacing2) {
            Text(loc.localized("search.surpriseMePrompt"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)

            HStack(spacing: CinemaSpacing.spacing3) {
                surprisePill(
                    label: loc.localized("search.surprise.movie"),
                    icon: "film.fill",
                    isLoading: isPickingSurpriseMovie
                ) {
                    await performSurprise(type: .movie)
                }
                surprisePill(
                    label: loc.localized("search.surprise.series"),
                    icon: "tv.fill",
                    isLoading: isPickingSurpriseSeries
                ) {
                    await performSurprise(type: .series)
                }
            }
        }
        .padding(.top, CinemaSpacing.spacing4)
    }

    @ViewBuilder
    private func surprisePill(label: String, icon: String, isLoading: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: CinemaSpacing.spacing2) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: surpriseIconSize, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: surpriseLabelSize, weight: .semibold))
            }
            .foregroundStyle(themeManager.onAccent)
            .padding(.horizontal, CinemaSpacing.spacing4)
            .padding(.vertical, CinemaSpacing.spacing3)
            .background(themeManager.accentContainer)
            .clipShape(Capsule())
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .accent))
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(isLoading)
        .accessibilityLabel(label)
    }

    private func performSurprise(type: BaseItemKind) async {
        if type == .movie { isPickingSurpriseMovie = true }
        else { isPickingSurpriseSeries = true }
        defer {
            if type == .movie { isPickingSurpriseMovie = false }
            else { isPickingSurpriseSeries = false }
        }

        let item: BaseItemDto?
        switch type {
        case .movie:  item = await viewModel.fetchRandomMovie(using: appState)
        case .series: item = await viewModel.fetchRandomSeries(using: appState)
        default:      item = nil
        }

        guard let item, let id = item.id else {
            toasts.error(
                loc.localized("toast.surprise.failed"),
                message: loc.localized("toast.surprise.emptyLibrary")
            )
            return
        }
        surpriseDestination = SurpriseDestination(id: id, itemType: item.type ?? type)
    }

    private var surpriseIconSize: CGFloat {
        #if os(tvOS)
        24
        #else
        16
        #endif
    }

    private var surpriseLabelSize: CGFloat {
        #if os(tvOS)
        22
        #else
        15
        #endif
    }

    // MARK: - Sizing

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        AdaptiveLayout.horizontalPadding(for: AdaptiveLayout.form(horizontalSizeClass: sizeClass))
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        32
        #else
        16
        #endif
    }

    private var searchFontSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(24)
        #else
        CinemaScale.pt(17)
        #endif
    }

    private var searchIconSize: CGFloat {
        #if os(tvOS)
        CinemaScale.pt(22)
        #else
        CinemaScale.pt(17)
        #endif
    }
}

// MARK: - Voice Search Button (iOS only)

#if os(iOS)
/// Microphone pill with a pulsing accent ring while listening. Owns its own
/// pulsing state so the parent doesn't need to track animation flags.
private struct VoiceSearchButton: View {
    let isListening: Bool
    let iconSize: CGFloat
    let onTap: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var isPulsing = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isListening {
                    Circle()
                        .fill(themeManager.accent.opacity(0.25))
                        .frame(width: isPulsing ? 36 : 28, height: isPulsing ? 36 : 28)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: isPulsing
                        )
                }

                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(isListening ? themeManager.accent : CinemaColor.onSurfaceVariant)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening
            ? loc.localized("accessibility.stopVoiceSearch")
            : loc.localized("accessibility.voiceSearch"))
        .onChange(of: isListening) { _, newValue in
            isPulsing = newValue
        }
    }
}
#endif

// MARK: - Results Grid

/// LazyVGrid of search results. Kept as a standalone `View` so SwiftUI's
/// diff can skip re-rendering the grid when parent state (surprise-me flags,
/// pulsing, etc.) changes but the results array itself hasn't.
private struct SearchResultsGrid: View {
    let results: [BaseItemDto]
    let imageBuilder: ImageURLBuilder
    let columns: [GridItem]
    let gridPadding: CGFloat
    let gridSpacing: CGFloat
    let headerTitle: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                Text(headerTitle)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.horizontal, gridPadding)
                    .accessibilityAddTraits(.isHeader)

                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(results, id: \.id) { item in
                        SearchResultCard(item: item, imageBuilder: imageBuilder)
                    }
                }
                .padding(.horizontal, gridPadding)

                Spacer(minLength: 80)
            }
        }
    }
}

private struct SearchResultCard: View {
    let item: BaseItemDto
    let imageBuilder: ImageURLBuilder

    var body: some View {
        let subtitle = Self.subtitle(for: item)

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(itemId: id, itemType: item.type ?? .movie)
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map {
                    imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300)
                },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(
            [item.name, subtitle.isEmpty ? nil : subtitle]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private static func subtitle(for item: BaseItemDto) -> String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if item.type == .episode, let seriesName = item.seriesName {
            parts.append(seriesName)
        } else if let type = item.type {
            parts.append(type.rawValue)
        }
        return parts.joined(separator: " · ")
    }
}
