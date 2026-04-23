#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Scheduled tasks list. Mirrors Jellyfin web's Tâches planifiées panel —
/// tasks grouped by category with inline start/stop actions. When any task
/// is running the view model polls every 2s so the progress bar advances
/// live; polling self-cancels when no tasks are running.
struct AdminScheduledTasksScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var viewModel = AdminScheduledTasksViewModel()

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.tasks.isEmpty,
            errorMessage: viewModel.errorMessage,
            isEmpty: viewModel.isEmpty,
            emptyIcon: "calendar.badge.exclamationmark",
            emptyTitle: loc.localized("admin.tasks.empty.title"),
            emptySubtitle: loc.localized("admin.tasks.empty.subtitle"),
            onRetry: { Task { await viewModel.load(using: appState.apiClient) } }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    ForEach(viewModel.groupedByCategory, id: \.category) { group in
                        categorySection(group)
                    }
                }
                .padding(.horizontal, CinemaSpacing.spacing3)
                .padding(.top, CinemaSpacing.spacing4)
                .padding(.bottom, CinemaSpacing.spacing8)
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.tasks.title"))
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await viewModel.load(using: appState.apiClient) }
        .task {
            if viewModel.tasks.isEmpty {
                await viewModel.load(using: appState.apiClient)
            }
            if viewModel.hasRunningTask {
                viewModel.startPolling(using: appState.apiClient)
            }
        }
        .onDisappear { viewModel.stopPolling() }
    }

    @ViewBuilder
    private func categorySection(_ group: (category: String, tasks: [TaskInfo])) -> some View {
        AdminSectionGroup(group.category) {
            ForEach(Array(group.tasks.enumerated()), id: \.element.id) { index, task in
                taskRow(task)
                if index < group.tasks.count - 1 {
                    iOSSettingsDivider
                }
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ task: TaskInfo) -> some View {
        let isPending = viewModel.pendingActionTaskId == task.id
        let isRunning = task.state == .running
        let isCancelling = task.state == .cancelling

        iOSSettingsRow {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                HStack(alignment: .top, spacing: CinemaSpacing.spacing2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.name ?? "—")
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurface)

                        if let description = task.description, !description.isEmpty {
                            Text(description)
                                .font(CinemaFont.label(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                                .multilineTextAlignment(.leading)
                        }

                        statusLine(task)
                    }

                    Spacer()

                    actionButton(task, isPending: isPending, isRunning: isRunning, isCancelling: isCancelling)
                }

                if isRunning, let progress = task.currentProgressPercentage {
                    ProgressView(value: progress / 100.0)
                        .progressViewStyle(.linear)
                        .tint(themeManager.accent)
                }
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ task: TaskInfo) -> some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            stateBadge(for: task.state)

            if let last = task.lastExecutionResult, let resultStatus = last.status {
                Text("•")
                    .font(CinemaFont.label(.small))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                HStack(spacing: 4) {
                    Image(systemName: resultStatus == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(resultStatus == .completed ? CinemaColor.success : CinemaColor.error)
                    if let endTime = last.endTimeUtc {
                        Text(relativeShort(endTime))
                            .font(CinemaFont.label(.small))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stateBadge(for state: TaskState?) -> some View {
        switch state {
        case .running:
            labelBadge(loc.localized("admin.tasks.state.running"), color: themeManager.accent)
        case .cancelling:
            labelBadge(loc.localized("admin.tasks.state.cancelling"), color: .orange)
        default:
            labelBadge(loc.localized("admin.tasks.state.idle"), color: CinemaColor.onSurfaceVariant)
        }
    }

    private func relativeShort(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func labelBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    @ViewBuilder
    private func actionButton(_ task: TaskInfo, isPending: Bool, isRunning: Bool, isCancelling: Bool) -> some View {
        if isPending {
            ProgressView().tint(themeManager.accent)
        } else if isRunning {
            Button {
                Task {
                    let ok = await viewModel.stopTask(task, using: appState.apiClient)
                    if ok {
                        toasts.info(loc.localized("admin.tasks.stopped"))
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(CinemaColor.error)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(CinemaColor.error.opacity(0.15)))
            }
            .buttonStyle(.plain)
        } else if isCancelling {
            Image(systemName: "hourglass")
                .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
        } else {
            Button {
                Task {
                    let ok = await viewModel.startTask(task, using: appState.apiClient)
                    if ok {
                        toasts.success(loc.localized("admin.tasks.started"))
                    } else if let err = viewModel.errorMessage {
                        toasts.error(err)
                    }
                }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: CinemaScale.pt(14), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(themeManager.accent.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
    }
}
#endif
