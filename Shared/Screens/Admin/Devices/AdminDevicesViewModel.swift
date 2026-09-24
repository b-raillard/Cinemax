#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminDevicesViewModel {
    var devices: [DeviceInfoDto] = []
    /// Starts TRUE: the screen's `.task` loads on first appearance, and a
    /// `false` start drew the « Aucun… » empty state for a frame before the
    /// spinner replaced it.
    var isLoading = true
    var errorMessage: String?
    var pendingRevoke: DeviceInfoDto?

    var isEmpty: Bool {
        !isLoading && errorMessage == nil && devices.isEmpty
    }

    func load(using apiClient: any AuthAPI, loc: LocalizationManager) async {
        isLoading = true
        errorMessage = nil
        do {
            devices = try await apiClient.getDevices().sorted {
                ($0.dateLastActivity ?? .distantPast) > ($1.dateLastActivity ?? .distantPast)
            }
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
        }
        isLoading = false
    }

    func revoke(_ device: DeviceInfoDto, using apiClient: any AuthAPI, loc: LocalizationManager) async -> Bool {
        guard let id = device.id else { return false }
        do {
            try await apiClient.deleteDevice(id: id)
            devices.removeAll { $0.id == id }
            return true
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
            return false
        }
    }
}
#endif
