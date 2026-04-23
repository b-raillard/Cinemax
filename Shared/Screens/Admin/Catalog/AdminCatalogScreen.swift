#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Plugin catalog. Lists packages advertised by the server's configured
/// repositories, grouped by category with a search filter. Tapping a row
/// opens a detail sheet with the overview + latest-version installer.
///
/// Installation completes server-side — the server then requires a restart
/// to activate the plugin. We surface that with a "restart required" toast.
struct AdminCatalogScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var viewModel = AdminCatalogViewModel()

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.packages.isEmpty,
            errorMessage: viewModel.errorMessage,
            isEmpty: viewModel.isEmpty,
            emptyIcon: "globe.badge.chevron.backward",
            emptyTitle: loc.localized("admin.catalog.empty.title"),
            emptySubtitle: loc.localized("admin.catalog.empty.subtitle"),
            onRetry: { Task { await viewModel.load(using: appState.apiClient) } }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    ForEach(viewModel.groupedByCategory, id: \.category) { group in
                        AdminSectionGroup(group.category) {
                            ForEach(Array(group.packages.enumerated()), id: \.element.guid) { index, package in
                                Button { viewModel.selectedPackage = package } label: {
                                    packageRow(package)
                                }
                                .buttonStyle(.plain)
                                if index < group.packages.count - 1 {
                                    iOSSettingsDivider
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.top, CinemaSpacing.spacing4)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.catalog.title"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $viewModel.searchText, prompt: loc.localized("admin.catalog.searchPrompt"))
        .refreshable { await viewModel.load(using: appState.apiClient) }
        .task {
            if viewModel.packages.isEmpty {
                await viewModel.load(using: appState.apiClient)
            }
        }
        .sheet(item: Binding(
            get: { viewModel.selectedPackage.map { IdentifiablePackage(package: $0) } },
            set: { viewModel.selectedPackage = $0?.package }
        )) { wrapper in
            detailSheet(for: wrapper.package)
        }
    }

    @ViewBuilder
    private func packageRow(_ package: PackageInfo) -> some View {
        iOSSettingsRow {
            HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                iOSRowIcon(systemName: "puzzlepiece.extension", color: themeManager.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(package.name ?? "—")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)

                    if let description = package.description, !description.isEmpty {
                        Text(description)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .lineLimit(2)
                    }

                    if let owner = package.owner, !owner.isEmpty {
                        Text(owner)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant.opacity(0.7))
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(CinemaColor.outlineVariant)
            }
        }
    }

    private func detailSheet(for package: PackageInfo) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                        Text(package.name ?? "—")
                            .font(CinemaFont.headline(.small))
                            .foregroundStyle(CinemaColor.onSurface)

                        if let owner = package.owner {
                            Text(owner)
                                .font(CinemaFont.label(.medium))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }

                        if let latest = package.versions?.first?.version {
                            Text(String(format: loc.localized("admin.catalog.latestVersion"), latest))
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                                .padding(.top, CinemaSpacing.spacing1)
                        }
                    }

                    if let overview = package.overview ?? package.description {
                        Text(overview)
                            .font(CinemaFont.body)
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    CinemaButton(
                        title: loc.localized("admin.catalog.install"),
                        style: .primary,
                        isLoading: viewModel.isInstalling
                    ) {
                        Task {
                            let ok = await viewModel.installSelected(using: appState.apiClient)
                            if ok {
                                toasts.success(loc.localized("admin.catalog.install.success"))
                                viewModel.selectedPackage = nil
                            } else if let err = viewModel.errorMessage {
                                toasts.error(err)
                            }
                        }
                    }
                    .disabled(viewModel.isInstalling || (package.versions ?? []).isEmpty)
                    .padding(.top, CinemaSpacing.spacing3)

                    Text(loc.localized("admin.catalog.install.restartHint"))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.top, CinemaSpacing.spacing2)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(loc.localized("admin.catalog.detailTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) { viewModel.selectedPackage = nil }
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// `.sheet(item:)` needs Identifiable — `PackageInfo` isn't. Wrap it in a
// small adapter keyed on `guid` (or name fallback) so the sheet binding
// can drive it.
private struct IdentifiablePackage: Identifiable {
    let package: PackageInfo
    var id: String { package.guid ?? package.name ?? UUID().uuidString }
}
#endif
