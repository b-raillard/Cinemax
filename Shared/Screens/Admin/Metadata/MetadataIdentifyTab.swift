#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Identify tab — hosts the shared `IdentifyFormView` + `IdentifyResultsGridView`
/// inside the Metadata Editor. Apply confirmation is rendered as a sheet here
/// instead of a pushed step (the outer editor has its own tab navigation, and
/// stacking step transitions inside a tab gets disorienting).
///
/// Both this tab and the standalone `IdentifyScreen` drive the same
/// `IdentifyFlowModel`, so form fields / search results / provider-id
/// behaviour stay in lock-step.
struct MetadataIdentifyTab: View {
    @Bindable var viewModel: MetadataEditorViewModel

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        if !viewModel.identify.isSupportedKind {
            unsupportedKindNotice
        } else {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                IdentifyFormView(model: viewModel.identify) {
                    Task { await viewModel.runIdentifySearch(using: appState.apiClient) }
                }

                if !viewModel.identify.results.isEmpty {
                    IdentifyResultsGridView(results: viewModel.identify.results) { result in
                        viewModel.pendingIdentifyApply = result
                    }
                }
            }
            .task {
                await viewModel.identify.loadPathIfNeeded(
                    using: appState.apiClient,
                    userId: appState.currentUserId ?? ""
                )
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
            Text(loc.localized("admin.identify.unsupported"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .padding(CinemaSpacing.spacing4)
        .background(CinemaColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        .padding(.horizontal, CinemaSpacing.spacing3)
    }

    // MARK: - Apply confirmation sheet

    private var applyBinding: Binding<IdentifiableResult?> {
        Binding(
            get: { viewModel.pendingIdentifyApply.map { IdentifiableResult(result: $0) } },
            set: { viewModel.pendingIdentifyApply = $0?.result }
        )
    }

    private func applyConfirmSheet(for result: RemoteSearchResult) -> some View {
        NavigationStack {
            ScrollView {
                IdentifyConfirmView(
                    result: result,
                    replaceAllImages: $viewModel.identify.replaceAllImages,
                    isApplying: viewModel.identify.isApplying,
                    onConfirm: {}
                )
                .padding(.top, CinemaSpacing.spacing4)

                CinemaButton(
                    title: loc.localized("action.ok"),
                    style: .accent,
                    isLoading: viewModel.identify.isApplying
                ) {
                    Task {
                        let ok = await viewModel.applyIdentifyResult(
                            using: appState.apiClient,
                            userId: appState.currentUserId ?? ""
                        )
                        if ok {
                            toasts.success(loc.localized("admin.identify.apply.success"))
                        } else if let err = viewModel.errorMessage {
                            toasts.error(err)
                        }
                    }
                }
                .disabled(viewModel.identify.isApplying)
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.top, CinemaSpacing.spacing4)
                .padding(.bottom, CinemaSpacing.spacing6)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(loc.localized("admin.identify.applyConfirm.title"))
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
        .presentationDetents([.medium, .large])
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
