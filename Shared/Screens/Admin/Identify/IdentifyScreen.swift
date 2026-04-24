#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Standalone Identify flow — pushed from the admin 3-dot menu on
/// `MediaDetailScreen` and on poster cards in library grids. Three-step
/// wizard (form → results → confirm) modelled on Jellyfin iOS's "Identifier"
/// screens. Inside the same `NavigationStack`, so the parent's back stack
/// still works and the user returns to where they came from on success.
///
/// Step navigation is a local `@State`; the toolbar back button is
/// overridden so it decrements the step, only dismissing when the user is
/// already on the form pane. Keeps the three steps as a single logical
/// "Identifier" destination rather than three stacked pushes the user has
/// to unwind one at a time.
struct IdentifyScreen: View {
    @State private var model: IdentifyFlowModel
    @State private var step: Step = .form
    @State private var pendingResult: RemoteSearchResult?

    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    init(item: BaseItemDto) {
        _model = State(wrappedValue: IdentifyFlowModel(item: item))
    }

    enum Step { case form, results, confirm }

    var body: some View {
        Group {
            if !model.isSupportedKind {
                unsupportedNotice
            } else {
                switch step {
                case .form:
                    ScrollView {
                        IdentifyFormView(model: model) {
                            Task {
                                await model.runSearch(using: appState.apiClient)
                                // Always transition — empty results render a
                                // "no match" state rather than trapping the
                                // user on the form with no visible feedback.
                                if model.errorMessage == nil {
                                    withAnimation { step = .results }
                                }
                            }
                        }
                        .padding(.top, CinemaSpacing.spacing4)
                        .padding(.bottom, CinemaSpacing.spacing8)
                    }
                case .results:
                    ScrollView {
                        IdentifyResultsGridView(results: model.results) { result in
                            pendingResult = result
                            withAnimation { step = .confirm }
                        }
                        .padding(.top, CinemaSpacing.spacing4)
                        .padding(.bottom, CinemaSpacing.spacing8)
                    }
                case .confirm:
                    if let result = pendingResult {
                        confirmPane(result: result)
                    } else {
                        // Shouldn't happen (pendingResult is set before we
                        // transition to .confirm), but fall back to results
                        // rather than rendering an empty pane.
                        Color.clear.onAppear { step = .results }
                    }
                }
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.identify.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    handleBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(CinemaColor.onSurface)
                }
                .accessibilityLabel(loc.localized("action.back"))
            }
        }
        .task {
            await model.loadPathIfNeeded(
                using: appState.apiClient,
                userId: appState.currentUserId ?? ""
            )
        }
    }

    // MARK: - Confirm pane with sticky OK footer

    @ViewBuilder
    private func confirmPane(result: RemoteSearchResult) -> some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                IdentifyConfirmView(
                    result: result,
                    replaceAllImages: $model.replaceAllImages,
                    isApplying: model.isApplying,
                    onConfirm: { Task { await applyAndDismiss(result) } }
                )
                .padding(.top, CinemaSpacing.spacing4)
                .padding(.bottom, 120)
            }

            // Sticky OK footer — matches the visual weight of Jellyfin iOS's
            // blue primary button anchored at the bottom of the screen.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(CinemaColor.outlineVariant.opacity(0.3))
                    .frame(height: 1)
                CinemaButton(
                    title: loc.localized("action.ok"),
                    style: .accent,
                    isLoading: model.isApplying
                ) {
                    Task { await applyAndDismiss(result) }
                }
                .disabled(model.isApplying)
                .padding(.horizontal, CinemaSpacing.spacing4)
                .padding(.top, CinemaSpacing.spacing3)
                .padding(.bottom, CinemaSpacing.spacing4)
            }
            .background(.ultraThinMaterial)
        }
    }

    private func applyAndDismiss(_ result: RemoteSearchResult) async {
        let ok = await model.apply(result, using: appState.apiClient)
        if ok {
            toasts.success(loc.localized("admin.identify.apply.success"))
            dismiss()
        } else if let err = model.errorMessage {
            toasts.error(err)
        }
    }

    private func handleBack() {
        switch step {
        case .form:
            dismiss()
        case .results:
            withAnimation { step = .form }
        case .confirm:
            withAnimation { step = .results }
        }
    }

    // MARK: - Unsupported notice

    private var unsupportedNotice: some View {
        VStack(spacing: CinemaSpacing.spacing4) {
            Image(systemName: "info.circle")
                .font(.system(size: 44))
                .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.7))
            Text(loc.localized("admin.identify.unsupported"))
                .font(CinemaFont.body)
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CinemaSpacing.spacing6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
