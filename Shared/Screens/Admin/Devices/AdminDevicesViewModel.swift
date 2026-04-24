#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminDevicesViewModel {
    var devices: [DeviceInfoDto] = []
    var isLoading = false
    var errorMessage: String?
    var pendingRevoke: DeviceInfoDto?

    var isEmpty: Bool {
        !isLoading && errorMessage == nil && devices.isEmpty
    }

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = true
        errorMessage = nil
        do {
            devices = try await apiClient.getDevices().sorted {
                ($0.dateLastActivity ?? .distantPast) > ($1.dateLastActivity ?? .distantPast)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func revoke(_ device: DeviceInfoDto, using apiClient: any APIClientProtocol) async -> Bool {
        guard let id = device.id else { return false }
        do {
            try await apiClient.deleteDevice(id: id)
            devices.removeAll { $0.id == id }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
#endif
