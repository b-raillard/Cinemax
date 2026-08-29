#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Gallery of the artwork the metadata providers offer for one image slot.
///
/// This is the piece "Identifier" was being mistaken for. Identify fixes *which
/// film this is* and then lets the providers re-pick artwork by their own
/// ranking — the poster shown in its result list is only a disambiguation
/// preview and is never applied. Choosing a specific image is a separate job,
/// and until now the app could only do it by pasting a URL by hand, which is
/// why a poster the user could see in Jellyfin's web UI was unreachable here.
///
/// The server fetches the bytes (`downloadRemoteImage`), so nothing is proxied
/// through the phone; the tiles below load the providers' own thumbnails
/// directly, which need no Jellyfin auth.
struct MetadataRemoteImagePicker: View {
    @Bindable var viewModel: MetadataEditorViewModel

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    /// Tiles track the slot's own shape, so a poster grid and a backdrop grid
    /// both read as what they are. Mirrors `MetadataImagesTab.imageSlot`.
    private var aspect: CGFloat {
        switch viewModel.pendingImageType {
        case .primary, .disc: 2.0 / 3.0
        case .backdrop, .art, .thumb: 16.0 / 9.0
        case .logo: 2.5
        case .banner: 5.0
        default: 1.0
        }
    }

    /// Retry re-keys the `.task` below rather than spawning its own `Task`, so
    /// a retry in flight is cancelled with the sheet like the initial load.
    @State private var reloadToken = 0

    /// Wide slots get fewer, bigger tiles; portrait posters fit three across.
    private var columnWidth: CGFloat {
        aspect >= 2.0 ? 260 : (aspect > 1 ? 200 : 110)
    }

    var body: some View {
        NavigationStack {
            content
                .background(CinemaColor.surface.ignoresSafeArea())
                .navigationTitle(loc.localized("admin.metadata.images.browse.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(loc.localized("action.cancel")) {
                            viewModel.showBrowseImagesSheet = false
                        }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                    // The URL entry stays reachable — it is the only way in for
                    // artwork no provider lists (a personal scan, a fan poster).
                    ToolbarItem(placement: .primaryAction) {
                        Button(loc.localized("admin.metadata.images.browse.byURL")) {
                            viewModel.showBrowseImagesSheet = false
                            viewModel.showAddImageSheet = true
                        }
                        .tint(themeManager.accent)
                    }
                }
        }
        .task(id: "\(viewModel.pendingImageType.rawValue)-\(reloadToken)") {
            await viewModel.loadRemoteImages(
                using: appState.apiClient,
                preferredLanguage: loc.languageCode,
                loc: loc
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoadingRemoteImages {
            LoadingStateView()
        } else if let error = viewModel.remoteImagesError {
            ErrorStateView(message: error, retryTitle: loc.localized("action.retry")) {
                reloadToken += 1
            }
        } else if viewModel.remoteImages.isEmpty {
            // Reachable and ordinary: a provider that has the film may still
            // hold no artwork of this particular type.
            EmptyStateView(
                systemImage: "photo.on.rectangle.angled",
                title: loc.localized("admin.metadata.images.browse.empty.title"),
                subtitle: loc.localized("admin.metadata.images.browse.empty.subtitle")
            )
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: columnWidth), spacing: CinemaSpacing.spacing3)],
                spacing: CinemaSpacing.spacing4
            ) {
                ForEach(viewModel.remoteImages) { candidate in
                    tile(candidate)
                }
            }
            .padding(CinemaSpacing.spacing4)
        }
    }

    private func tile(_ candidate: RemoteImageCandidate) -> some View {
        let isApplying = viewModel.applyingImageURL == candidate.url

        return Button {
            apply(candidate)
        } label: {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        CinemaLazyImage(
                            url: URL(string: candidate.previewURL),
                            fallbackIcon: "photo"
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))
                    // The filled image overflows its box whenever the artwork's
                    // ratio differs from the slot's; without this the overflow
                    // stays hit-testable and neighbouring tiles steal the tap.
                    .contentShape(Rectangle())
                    .overlay {
                        if isApplying {
                            ZStack {
                                RoundedRectangle(cornerRadius: CinemaRadius.small)
                                    .fill(CinemaColor.surface.opacity(0.6))
                                ProgressView().tint(themeManager.accent)
                            }
                        }
                    }

                captions(candidate)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.applyingImageURL != nil)
        .accessibilityLabel(accessibilityLabel(candidate))
    }

    @ViewBuilder
    private func captions(_ candidate: RemoteImageCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: CinemaSpacing.spacing1) {
                Text(candidate.providerName ?? loc.localized("admin.metadata.images.browse.unknownProvider"))
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(1)

                if let rating = candidate.communityRating {
                    Text(String(format: "★ %.1f", rating))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(themeManager.accent)
                }
            }

            Text(secondaryCaption(candidate))
                .font(CinemaFont.label(.small))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .lineLimit(1)
        }
    }

    /// Language first — it is what the user is actually choosing between when
    /// several posters carry the same art with different burned-in titles.
    private func secondaryCaption(_ candidate: RemoteImageCandidate) -> String {
        let language = candidate.isTextless
            ? loc.localized("admin.metadata.images.browse.textless")
            : (candidate.language ?? "").uppercased()
        guard let resolution = candidate.resolutionLabel else { return language }
        return language.isEmpty ? resolution : "\(language) · \(resolution)"
    }

    private func accessibilityLabel(_ candidate: RemoteImageCandidate) -> String {
        [candidate.providerName, secondaryCaption(candidate)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func apply(_ candidate: RemoteImageCandidate) {
        Task {
            let ok = await viewModel.applyRemoteImage(
                candidate,
                using: appState.apiClient,
                userId: appState.currentUserId ?? "",
                loc: loc
            )
            if ok {
                Haptics.success()
                toasts.success(loc.localized("admin.metadata.images.browse.applied"))
                viewModel.showBrowseImagesSheet = false
            } else if let error = viewModel.errorMessage {
                Haptics.error()
                toasts.error(error)
            }
        }
    }
}
#endif
