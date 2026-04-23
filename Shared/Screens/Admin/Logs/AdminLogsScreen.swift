#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Server log browser. Lists log files newest-first with a read-only viewer
/// on tap. No share sheet, no save-to-files — logs can contain usernames,
/// IPs, and occasionally tokens the server decides to print, so the only
/// export path is an explicit system-level long-press copy if a user
/// really needs to paste something into a support ticket. Rendering is
/// `.privacySensitive()` to benefit from system redaction during screen
/// capture and mirroring.
struct AdminLogsScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    @State private var viewModel = AdminLogsViewModel()

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.files.isEmpty,
            errorMessage: viewModel.errorMessage,
            isEmpty: viewModel.isEmpty,
            emptyIcon: "doc.text",
            emptyTitle: loc.localized("admin.logs.empty.title"),
            emptySubtitle: loc.localized("admin.logs.empty.subtitle"),
            onRetry: { Task { await viewModel.load(using: appState.apiClient) } }
        ) {
            ScrollView(showsIndicators: false) {
                AdminSectionGroup {
                    ForEach(Array(viewModel.files.enumerated()), id: \.element.name) { index, file in
                        NavigationLink {
                            AdminLogViewerScreen(fileName: file.name ?? "")
                        } label: {
                            logRow(file)
                        }
                        .buttonStyle(.plain)
                        if index < viewModel.files.count - 1 {
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
        .navigationTitle(loc.localized("admin.logs.title"))
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await viewModel.load(using: appState.apiClient) }
        .task {
            if viewModel.files.isEmpty {
                await viewModel.load(using: appState.apiClient)
            }
        }
    }

    @ViewBuilder
    private func logRow(_ file: LogFile) -> some View {
        iOSSettingsRow {
            HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                iOSRowIcon(systemName: "doc.text", color: themeManager.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name ?? "—")
                        .font(.system(size: CinemaScale.pt(14), design: .monospaced))
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: CinemaSpacing.spacing2) {
                        if let size = file.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                        if let date = file.dateModified {
                            Text("•")
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                            let formatter = RelativeDateTimeFormatter()
                            Text(formatter.localizedString(for: date, relativeTo: Date()))
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(CinemaColor.outlineVariant)
            }
        }
    }
}

/// Log file viewer. Loads on appear, shows a truncation footer if the
/// server-reported file exceeds `maxBytes`. Content is selectable (so users
/// can long-press a specific line for a support ticket) but otherwise has
/// no export affordance.
struct AdminLogViewerScreen: View {
    let fileName: String

    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc

    @State private var viewModel: AdminLogViewerViewModel

    init(fileName: String) {
        self.fileName = fileName
        _viewModel = State(wrappedValue: AdminLogViewerViewModel(fileName: fileName))
    }

    var body: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()

            if viewModel.isLoading {
                LoadingStateView()
            } else if let err = viewModel.errorMessage {
                ErrorStateView(
                    message: err,
                    retryTitle: loc.localized("action.retry"),
                    onRetry: { Task { await viewModel.load(using: appState.apiClient) } }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                        if viewModel.isTruncated {
                            truncationBanner
                        }

                        Text(viewModel.contents)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CinemaColor.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .privacySensitive()
                    }
                    .padding(CinemaSpacing.spacing3)
                }
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(using: appState.apiClient) }
    }

    private var truncationBanner: some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing2) {
            Image(systemName: "scissors")
                .font(.system(size: CinemaScale.pt(14)))
                .foregroundStyle(.orange)
            Text(String(
                format: loc.localized("admin.logs.truncated"),
                ByteCountFormatter.string(fromByteCount: Int64(AdminLogViewerViewModel.maxBytes), countStyle: .file),
                ByteCountFormatter.string(fromByteCount: Int64(viewModel.originalSize), countStyle: .file)
            ))
            .font(CinemaFont.label(.small))
            .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .padding(CinemaSpacing.spacing3)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
    }
}
#endif
