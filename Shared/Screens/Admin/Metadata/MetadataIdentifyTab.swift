#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Identify tab — search TMDB / IMDB / TVDB (whatever the server has
/// configured) for a matching title and apply its metadata to the item.
/// Only `.movie` and `.series` items are supported; other kinds show a
/// friendly notice rather than a broken search form.
///
/// "Replace all images" is a separate toggle — applying metadata is
/// usually what admins want (titles, overview, dates), and overwriting
/// hand-picked artwork is an explicit opt-in.
struct MetadataIdentifyTab: View {
    @Bindable var viewModel: MetadataEditorViewModel

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    private var isSupportedKind: Bool {
        switch viewModel.item.type {
        case .movie, .series: true
        default: false
        }
    }

    var body: some View {
        if !isSupportedKind {
            unsupportedKindNotice
        } else {
            Group {
                AdminSectionGroup(loc.localized("admin.metadata.identify.searchTitle")) {
                    iOSSettingsRow {
                        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                            GlassTextField(
                                label: loc.localized("admin.metadata.identify.name"),
                                text: $viewModel.identifyName,
                                placeholder: ""
                            )
                            GlassTextField(
                                label: loc.localized("admin.metadata.identify.year"),
                                text: $viewModel.identifyYear,
                                placeholder: "2024"
                            )

                            CinemaButton(
                                title: loc.localized("admin.metadata.identify.search"),
                                style: .primary,
                                isLoading: viewModel.isSearchingIdentify
                            ) {
                                Task { await viewModel.runIdentifySearch(using: appState.apiClient) }
                            }
                            .disabled(viewModel.identifyName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                if let err = viewModel.errorMessage {
                    Text(err)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.error)
                        .padding(.horizontal, CinemaSpacing.spacing3)
                }

                if !viewModel.identifyResults.isEmpty {
                    resultsSection
                }
            }
            .sheet(item: applyBinding) { wrapper in
                applyConfirmSheet(for: wrapper.result)
            }
        }
    }

    // MARK: - Unsupported notice

    private var unsupportedKindNotice: some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
            Image(systemName: "info.circle")
                .font(.system(size: CinemaScale.pt(18)))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
            Text(loc.localized("admin.metadata.identify.unsupported"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .padding(CinemaSpacing.spacing4)
        .background(CinemaColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        .padding(.horizontal, CinemaSpacing.spacing3)
    }

    // MARK: - Results

    private var resultsSection: some View {
        AdminSectionGroup(loc.localized("admin.metadata.identify.results")) {
            ForEach(Array(viewModel.identifyResults.enumerated()), id: \.offset) { index, result in
                Button {
                    viewModel.pendingIdentifyApply = result
                } label: {
                    resultRow(result)
                }
                .buttonStyle(.plain)
                if index < viewModel.identifyResults.count - 1 {
                    iOSSettingsDivider
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ result: RemoteSearchResult) -> some View {
        iOSSettingsRow {
            HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                if let urlString = result.imageURL, let url = URL(string: urlString) {
                    Color.clear
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(width: 60)
                        .overlay { CinemaLazyImage(url: url, fallbackIcon: "photo") }
                        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: CinemaRadius.small)
                        .fill(CinemaColor.surfaceContainerHigh)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(width: 60)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: CinemaSpacing.spacing2) {
                        Text(result.name ?? "—")
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                            .lineLimit(1)
                        if let year = result.productionYear {
                            Text("(\(String(year)))")
                                .font(CinemaFont.label(.medium))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                    }

                    if let provider = result.searchProviderName {
                        Text(provider)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(themeManager.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(themeManager.accent.opacity(0.15)))
                    }

                    if let overview = result.overview, !overview.isEmpty {
                        Text(overview)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 2)
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(13), weight: .semibold))
                    .foregroundStyle(CinemaColor.outlineVariant)
            }
        }
    }

    // MARK: - Apply confirmation

    private var applyBinding: Binding<IdentifiableResult?> {
        Binding(
            get: { viewModel.pendingIdentifyApply.map { IdentifiableResult(result: $0) } },
            set: { viewModel.pendingIdentifyApply = $0?.result }
        )
    }

    private func applyConfirmSheet(for result: RemoteSearchResult) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    Text(String(
                        format: loc.localized("admin.metadata.identify.applyConfirm.message"),
                        result.name ?? ""
                    ))
                    .font(CinemaFont.body)
                    .foregroundStyle(CinemaColor.onSurface)

                    iOSSettingsRow {
                        HStack {
                            Text(loc.localized("admin.metadata.identify.replaceImages"))
                                .font(CinemaFont.label(.large))
                                .foregroundStyle(CinemaColor.onSurface)
                            Spacer()
                            Button { viewModel.identifyReplaceAllImages.toggle() } label: {
                                CinemaToggleIndicator(
                                    isOn: viewModel.identifyReplaceAllImages,
                                    accent: themeManager.accent,
                                    animated: true
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(CinemaColor.surfaceContainerHigh)
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))

                    Text(loc.localized("admin.metadata.identify.replaceImages.hint"))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)

                    CinemaButton(
                        title: loc.localized("admin.metadata.identify.apply"),
                        style: .primary
                    ) {
                        Task {
                            let ok = await viewModel.applyIdentifyResult(
                                using: appState.apiClient,
                                userId: appState.currentUserId ?? ""
                            )
                            if ok {
                                toasts.success(loc.localized("admin.metadata.identify.apply.success"))
                            } else if let err = viewModel.errorMessage {
                                toasts.error(err)
                            }
                        }
                    }
                    .padding(.top, CinemaSpacing.spacing3)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(loc.localized("admin.metadata.identify.applyConfirm.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) {
                        viewModel.pendingIdentifyApply = nil
                    }
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// `.sheet(item:)` wrapper — `RemoteSearchResult` is a class, not Identifiable.
private struct IdentifiableResult: Identifiable {
    let result: RemoteSearchResult
    var id: String {
        let provider = result.searchProviderName ?? "—"
        let name = result.name ?? "—"
        let year = result.productionYear.map(String.init) ?? "—"
        return "\(provider)|\(name)|\(year)|\(result.providerIDs?.values.sorted().joined(separator: ",") ?? "")"
    }
}
#endif
