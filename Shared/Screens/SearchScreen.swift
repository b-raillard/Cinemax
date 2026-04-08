import SwiftUI
import CinemaxKit
import JellyfinAPI

// MARK: - View

struct SearchScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var viewModel = SearchViewModel()

    // Pulsing animation state for the listening indicator
    @State private var isPulsing = false

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

            VStack(spacing: 0) {
                searchField
                #if os(iOS)
                listeningLabel
                #endif
                resultContent
            }
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
                Text(loc.localized("search.noResults"))
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            Spacer()
        } else if viewModel.results.isEmpty {
            Spacer()
            VStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaColor.outlineVariant)
                Text(loc.localized("search.searchLibrary"))
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            Spacer()
        } else {
            resultsGrid
        }
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                Text(loc.localized("search.topMatches"))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .padding(.horizontal, gridPadding)

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
