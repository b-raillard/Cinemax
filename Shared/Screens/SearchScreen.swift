import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - View

struct SearchScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @State private var viewModel = SearchViewModel()

    // Pulsing animation state for the listening indicator
    @State private var isPulsing = false

    // Surprise Me state — two buttons (movie + series) in the empty state.
    @State private var surpriseDestination: SurpriseDestination?
    @State private var isPickingSurpriseMovie = false
    @State private var isPickingSurpriseSeries = false

    private struct SurpriseDestination: Identifiable, Hashable {
        let id: String
        let itemType: BaseItemKind
    }

    private let columns: [GridItem] = {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 32), count: 6)
        #else
        Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
        #endif
    }()

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
            microphoneButton
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

    // MARK: - Microphone Button (iOS only)

    #if os(iOS)
    private var microphoneButton: some View {
        Button {
            viewModel.toggleListening(using: appState)
        } label: {
            ZStack {
                // Pulsing ring shown while listening
                if viewModel.isListening {
                    Circle()
                        .fill(themeManager.accent.opacity(0.25))
                        .frame(width: isPulsing ? 36 : 28, height: isPulsing ? 36 : 28)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: isPulsing
                        )
                }

                Image(systemName: "mic.fill")
                    .font(.system(size: searchIconSize))
                    .foregroundStyle(viewModel.isListening ? themeManager.accent : CinemaColor.onSurfaceVariant)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isListening
            ? loc.localized("accessibility.stopVoiceSearch")
            : loc.localized("accessibility.voiceSearch"))
        .onChange(of: viewModel.isListening) { _, newValue in
            isPulsing = newValue
        }
    }

    // MARK: - Listening Label (iOS only)

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
            resultsGrid
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

    private var resultsGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                Text(loc.localized("search.topMatches"))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.horizontal, gridPadding)
                    .accessibilityAddTraits(.isHeader)

                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(viewModel.results, id: \.id) { item in
                        resultCard(item)
                    }
                }
                .padding(.horizontal, gridPadding)

                Spacer(minLength: 80)
            }
        }
    }

    @ViewBuilder
    private func resultCard(_ item: BaseItemDto) -> some View {
        let subtitle: String = {
            var parts: [String] = []
            if let year = item.productionYear { parts.append(String(year)) }
            if item.type == .episode, let seriesName = item.seriesName {
                parts.append(seriesName)
            } else if let type = item.type {
                parts.append(type.rawValue)
            }
            return parts.joined(separator: " · ")
        }()

        NavigationLink {
            if let id = item.id {
                MediaDetailScreen(
                    itemId: id,
                    itemType: item.type ?? .movie
                )
            }
        } label: {
            PosterCard(
                title: item.name ?? "",
                imageURL: item.id.map { appState.imageBuilder.imageURL(itemId: $0, imageType: .primary, maxWidth: 300) },
                subtitle: subtitle
            )
        }
        #if os(tvOS)
        .buttonStyle(CinemaTVCardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: - Sizing

    private var gridPadding: CGFloat {
        #if os(tvOS)
        CinemaSpacing.spacing20
        #else
        CinemaSpacing.spacing3
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
