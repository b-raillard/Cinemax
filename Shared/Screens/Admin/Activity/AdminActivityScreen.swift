#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Paginated activity log. Mirrors Jellyfin web's Activité panel. Infinite
/// scroll at 50/page — no in-memory cap since iOS lazy lists handle thousands
/// of rows gracefully; closing the screen drops everything anyway.
struct AdminActivityScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    @State private var viewModel = AdminActivityViewModel()
    @State private var expandedEntry: Int? = nil

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.entries.isEmpty,
            errorMessage: viewModel.errorMessage,
            isEmpty: viewModel.isEmpty,
            emptyIcon: "clock.badge.questionmark",
            emptyTitle: loc.localized("admin.activity.empty.title"),
            emptySubtitle: loc.localized("admin.activity.empty.subtitle"),
            onRetry: { Task { await viewModel.reload(using: appState.apiClient) } }
        ) {
            List {
                ForEach(viewModel.entries, id: \.id) { entry in
                    entryRow(entry)
                        .listRowBackground(CinemaColor.surfaceContainerHigh)
                        .listRowSeparatorTint(CinemaColor.outlineVariant.opacity(0.3))
                        .onAppear {
                            Task {
                                await viewModel.loadMoreIfNeeded(
                                    currentItem: entry,
                                    using: appState.apiClient
                                )
                            }
                        }
                }

                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(themeManager.accent)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CinemaColor.surface)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.activity.title"))
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await viewModel.reload(using: appState.apiClient) }
        .task {
            if viewModel.entries.isEmpty {
                await viewModel.loadInitial(using: appState.apiClient)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: ActivityLogEntry) -> some View {
        let isExpanded = expandedEntry == entry.id

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isExpanded {
                    expandedEntry = nil
                } else {
                    expandedEntry = entry.id
                }
            }
        } label: {
            HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
                severityDot(for: entry.severity)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name ?? "—")
                        .font(CinemaFont.label(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                        .multilineTextAlignment(.leading)

                    if let short = entry.shortOverview, !short.isEmpty {
                        Text(short)
                            .font(CinemaFont.label(.medium))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .multilineTextAlignment(.leading)
                            .lineLimit(isExpanded ? nil : 2)
                    }

                    HStack(spacing: CinemaSpacing.spacing2) {
                        if let date = entry.date {
                            Text(relativeTimeLabel(for: date))
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                        if let type = entry.type, !type.isEmpty {
                            Text("•")
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                            Text(type)
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                        }
                    }

                    if isExpanded, let overview = entry.overview, overview != entry.shortOverview {
                        Text(overview)
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                            .padding(.top, CinemaSpacing.spacing1)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()
            }
            .padding(.vertical, CinemaSpacing.spacing1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func severityDot(for severity: LogLevel?) -> some View {
        let color: Color = {
            switch severity {
            case .critical, .error: CinemaColor.error
            case .warning: .orange
            case .information, .trace, .debug: themeManager.accent
            default: CinemaColor.onSurfaceVariant
            }
        }()

        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private func relativeTimeLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
#endif
