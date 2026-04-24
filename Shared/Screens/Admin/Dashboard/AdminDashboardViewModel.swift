#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminDashboardViewModel {
    var isLoading = false
    var errorMessage: String?
    var activeSessions: [SessionInfoDto] = []
    var systemInfo: SystemInfo?

    /// Fires all three server calls in parallel via `async let` so the dashboard
    /// renders as fast as the slowest dependency. We intentionally don't bail
    /// on the first failure — each fetch owns its own try/catch so a broken
    /// system-info endpoint doesn't hide active sessions, and vice versa.
    func load(using apiClient: any APIClientProtocol) async {
        isLoading = true
        errorMessage = nil

        async let sessionsResult: [SessionInfoDto] = (try? await apiClient.getActiveSessions()) ?? []
        async let systemResult: SystemInfo? = try? await apiClient.getSystemInfo()

        activeSessions = await sessionsResult
        systemInfo = await systemResult

        // We only surface an error banner when BOTH calls failed — otherwise
        // the partial data is useful on its own.
        if activeSessions.isEmpty && systemInfo == nil {
            errorMessage = "—"
        }
        isLoading = false
    }
}
#endif
