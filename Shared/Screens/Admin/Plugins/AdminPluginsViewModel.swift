#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminPluginsViewModel {
    var plugins: [PluginInfo] = []
    var isLoading = false
    var errorMessage: String?
    /// Id of the plugin currently being toggled / uninstalled — lets us render
    /// a per-row spinner without blocking the whole list.
    var pendingActionPluginId: String?
    var pendingUninstall: PluginInfo?

    var isEmpty: Bool {
        !isLoading && errorMessage == nil && plugins.isEmpty
    }

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = plugins.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            plugins = try await apiClient.getInstalledPlugins()
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ plugin: PluginInfo, enabled: Bool, using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = plugin.id, let version = plugin.version else { return false }
        pendingActionPluginId = id
        defer { pendingActionPluginId = nil }
        do {
            if enabled {
                try await apiClient.enablePlugin(id: id, version: version)
            } else {
                try await apiClient.disablePlugin(id: id, version: version)
            }
            // Reload so the server-reported status reflects whether a restart
            // is now pending — the badge on the row should flip accordingly.
            await load(using: apiClient)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func uninstall(_ plugin: PluginInfo, using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = plugin.id, let version = plugin.version else { return false }
        pendingActionPluginId = id
        defer { pendingActionPluginId = nil }
        do {
            try await apiClient.uninstallPlugin(id: id, version: version)
            plugins.removeAll { $0.id == plugin.id }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
#endif
