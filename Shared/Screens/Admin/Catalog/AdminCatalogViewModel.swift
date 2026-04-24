#if os(iOS)
import Foundation
import Observation
import CinemaxKit
@preconcurrency import JellyfinAPI

@MainActor @Observable
final class AdminCatalogViewModel {
    var packages: [PackageInfo] = []
    var isLoading = false
    var errorMessage: String?
    var searchText: String = ""
    var selectedPackage: PackageInfo?
    var isInstalling = false

    var isEmpty: Bool {
        !isLoading && errorMessage == nil && packages.isEmpty
    }

    /// Search-and-group result. Categories preserve catalog order, packages
    /// within each category are name-sorted for predictability.
    var groupedByCategory: [(category: String, packages: [PackageInfo])] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered: [PackageInfo] = {
            guard !query.isEmpty else { return packages }
            return packages.filter {
                ($0.name ?? "").lowercased().contains(query)
                    || ($0.description ?? "").lowercased().contains(query)
                    || ($0.overview ?? "").lowercased().contains(query)
            }
        }()

        var order: [String] = []
        var buckets: [String: [PackageInfo]] = [:]
        for package in filtered {
            let key = package.category ?? "—"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(package)
        }
        return order.map { ($0, (buckets[$0] ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") }) }
    }

    func load(using apiClient: any APIClientProtocol) async {
        isLoading = packages.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            packages = try await apiClient.getPluginCatalog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Installs the latest version of the selected package. Jellyfin publishes
    /// packages newest-first, so `versions.first` is the install target.
    /// `assemblyGuid` is included because some repositories (notably the
    /// official catalog) require it to disambiguate similar names.
    func installSelected(using apiClient: any APIClientProtocol) async -> Bool {
        guard let package = selectedPackage,
              let name = package.name,
              let version = package.versions?.first else { return false }
        isInstalling = true
        errorMessage = nil
        defer { isInstalling = false }
        do {
            try await apiClient.installPackage(
                name: name,
                assemblyGuid: package.guid,
                version: version.version,
                repositoryURL: version.repositoryURL
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
#endif
