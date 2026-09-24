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
            onRetry: { Task { await viewModel.reload(using: appState.apiClient, loc: loc) } }
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
                                    using: appState.apiClient,
                                    loc: loc
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
        .refreshable { await viewModel.reload(using: appState.apiClient, loc: loc) }
        .task {
            if viewModel.entries.isEmpty {
                await viewModel.loadInitial(using: appState.apiClient, loc: loc)
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

                    if let short = Self.displayedShortOverview(entry.shortOverview) {
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

    /// The server's one-line summary, or `nil` when it says nothing. Jellyfin
    /// fills it from a template even when the value is missing, which printed
    /// a bare « Adresse IP : » under half the sign-in events — a label whose
    /// value is empty is dropped rather than shown dangling.
    ///
    /// The entry's `type` (« SessionEnded », « AuthenticationSucceeded ») is
    /// deliberately not rendered at all: it is the server's internal event
    /// name, never localized, and the entry's own title already says the same
    /// thing in words.
    static func displayedShortOverview(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !trimmed.hasSuffix(":") else { return nil }
        return trimmed
    }

    private func relativeTimeLabel(for date: Date) -> String {
        AdminRelativeFormatter.string(for: date, style: .full, locale: loc.locale)
    }
}
#endif
