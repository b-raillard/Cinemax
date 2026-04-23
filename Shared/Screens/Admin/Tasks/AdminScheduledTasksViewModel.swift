#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminScheduledTasksViewModel {
    var tasks: [TaskInfo] = []
    var isLoading = false
    var errorMessage: String?
    /// Task id that is currently being started/stopped — used to render a
    /// spinner on just that row instead of blocking the whole list.
    var pendingActionTaskId: String?

    private var pollingTask: Task<Void, Never>?

    var isEmpty: Bool {
        !isLoading && errorMessage == nil && tasks.isEmpty
    }

    /// Categories preserved in server-returned order. `Dictionary(grouping:)`
    /// alone would randomise the order between renders; we collect keys in
    /// first-seen order so the UI is stable across refreshes.
    var groupedByCategory: [(category: String, tasks: [TaskInfo])] {
        var order: [String] = []
        var buckets: [String: [TaskInfo]] = [:]
        for task in tasks {
            let key = task.category ?? "—"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(task)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var hasRunningTask: Bool {
        tasks.contains { $0.state == .running || $0.state == .cancelling }
    }

    // MARK: - Load / poll

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = tasks.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            tasks = try await apiClient.getScheduledTasks(includeHidden: false)
                .sorted { ($0.category ?? "") < ($1.category ?? "") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes without clearing the list. Used by the polling loop so the
    /// visible list doesn't blink on every tick.
    private func silentRefresh(using apiClient: any APIClientProtocol) async {
        if let fresh = try? await apiClient.getScheduledTasks(includeHidden: false) {
            tasks = fresh.sorted { ($0.category ?? "") < ($1.category ?? "") }
        }
    }

    /// Polls every 2s while any task is running. Self-cancels when the screen
    /// unmounts (via `stopPolling()`) or when no tasks are running — whichever
    /// comes first.
    func startPolling(using apiClient: any APIClientProtocol) {
        stopPolling()
        pollingTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                if !self.hasRunningTask { break }
                await self.silentRefresh(using: apiClient)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Actions

    func startTask(_ task: TaskInfo, using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = task.id else { return false }
        pendingActionTaskId = id
        defer { pendingActionTaskId = nil }
        do {
            try await apiClient.startTask(id: id)
            await silentRefresh(using: apiClient)
            startPolling(using: apiClient)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func stopTask(_ task: TaskInfo, using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = task.id else { return false }
        pendingActionTaskId = id
        defer { pendingActionTaskId = nil }
        do {
            try await apiClient.stopTask(id: id)
            await silentRefresh(using: apiClient)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
#endif
