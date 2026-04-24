import Foundation
import JellyfinAPI

extension JellyfinAPIClient {
    // MARK: - Devices

    public func getDevices() async throws -> [DeviceInfoDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getDevices())
        return response.value.items ?? []
    }

    public func deleteDevice(id: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.deleteDevice(id: id))
    }

    // MARK: - Admin

    public func getUserByID(id: String) async throws -> UserDto {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getUserByID(userID: id))
        return response.value
    }

    public func createUserByName(name: String, password: String?) async throws -> UserDto {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let body = CreateUserByName(name: name, password: password)
        let response = try await client.send(Paths.createUserByName(body))
        return response.value
    }

    public func updateUser(id: String, user: UserDto) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.updateUser(userID: id, user))
    }

    public func updateUserPolicy(id: String, policy: UserPolicy) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.updateUserPolicy(userID: id, policy))
    }

    public func updateUserPassword(id: String, newPassword: String, resetPassword: Bool) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        // Admin-as-another-user password resets don't require the target user's
        // current password — the server trusts the admin's session, so we send
        // only `newPw` (and `resetPassword` to clear without setting a new one).
        let body = UpdateUserPassword(
            currentPassword: nil,
            currentPw: nil,
            newPw: resetPassword ? nil : newPassword,
            isResetPassword: resetPassword
        )
        _ = try await client.send(Paths.updateUserPassword(userID: id, body))
    }

    public func deleteUser(id: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.deleteUser(userID: id))
    }

    public func getMediaFolders() async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getMediaFolders())
        return response.value.items ?? []
    }

    public func getActivityLogEntries(startIndex: Int, limit: Int, minDate: Date?) async throws -> (entries: [ActivityLogEntry], total: Int) {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetLogEntriesParameters(startIndex: startIndex, limit: limit, minDate: minDate)
        let response = try await client.send(Paths.getLogEntries(parameters: params))
        return (response.value.items ?? [], response.value.totalRecordCount ?? 0)
    }

    public func getSystemInfo() async throws -> SystemInfo {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getSystemInfo)
        return response.value
    }

    // MARK: - Plugins

    public func getInstalledPlugins() async throws -> [PluginInfo] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getPlugins)
        return response.value
    }

    public func enablePlugin(id: String, version: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.enablePlugin(pluginID: id, version: version))
    }

    public func disablePlugin(id: String, version: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.disablePlugin(pluginID: id, version: version))
    }

    public func uninstallPlugin(id: String, version: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.uninstallPluginByVersion(pluginID: id, version: version))
    }

    // MARK: - Plugin catalog

    public func getPluginCatalog() async throws -> [PackageInfo] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getPackages)
        return response.value
    }

    public func installPackage(name: String, assemblyGuid: String?, version: String?, repositoryURL: String?) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.InstallPackageParameters(
            assemblyGuid: assemblyGuid,
            version: version,
            repositoryURL: repositoryURL
        )
        _ = try await client.send(Paths.installPackage(name: name, parameters: params))
    }

    // MARK: - Scheduled tasks

    public func getScheduledTasks(includeHidden: Bool) async throws -> [TaskInfo] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        // `isHidden == false` requests visible-only; `nil` returns everything.
        let response = try await client.send(Paths.getTasks(isHidden: includeHidden ? nil : false))
        return response.value
    }

    public func startTask(id: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.startTask(taskID: id))
    }

    public func stopTask(id: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.stopTask(taskID: id))
    }

    public func updateTaskTriggers(id: String, triggers: [TaskTriggerInfo]) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.updateTask(taskID: id, triggers))
    }

    // MARK: - Encoding options (named configuration)

    public func getEncodingOptions() async throws -> EncodingOptions {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getNamedConfiguration(key: "encoding"))
        return try JSONDecoder().decode(EncodingOptions.self, from: response.value)
    }

    public func updateEncodingOptions(_ options: EncodingOptions) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        // Round-trip through AnyJSON — SDK's named-configuration endpoint is
        // type-erased so we can't hand it an EncodingOptions directly.
        let data = try JSONEncoder().encode(options)
        let anyJSON = try JSONDecoder().decode(AnyJSON.self, from: data)
        _ = try await client.send(Paths.updateNamedConfiguration(key: "encoding", anyJSON))
    }

    // MARK: - Network configuration

    public func getNetworkConfiguration() async throws -> NetworkConfiguration {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getNamedConfiguration(key: "network"))
        return try JSONDecoder().decode(NetworkConfiguration.self, from: response.value)
    }

    public func updateNetworkConfiguration(_ config: NetworkConfiguration) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let data = try JSONEncoder().encode(config)
        let anyJSON = try JSONDecoder().decode(AnyJSON.self, from: data)
        _ = try await client.send(Paths.updateNamedConfiguration(key: "network", anyJSON))
    }

    // MARK: - Logs

    public func getServerLogs() async throws -> [LogFile] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getServerLogs)
        return response.value
    }

    public func getLogFileContents(name: String) async throws -> String {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getLogFile(name: name))
        return response.value
    }

    // MARK: - API keys
    //
    // We intentionally do not cache key responses (unlike resume/latest) — the
    // list is small, changes at admin speed, and we don't want stale revoked
    // keys lingering in memory longer than necessary.

    public func getApiKeys() async throws -> [AuthenticationInfo] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getKeys)
        return response.value.items ?? []
    }

    public func createApiKey(app: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.createKey(app: app))
    }

    public func revokeApiKey(key: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.revokeKey(key: key))
    }

    // MARK: - Metadata editor

    public func updateItem(id: String, item: BaseItemDto) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.updateItem(itemID: id, item))
        // Invalidate cached item queries — stale data after a metadata edit
        // is misleading (renamed titles staying renamed only in memory, etc.).
        cache.clear()
    }

    public func refreshItem(
        id: String,
        metadataMode: MetadataRefreshMode,
        imageMode: MetadataRefreshMode,
        replaceAllMetadata: Bool,
        replaceAllImages: Bool
    ) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.RefreshItemParameters(
            metadataRefreshMode: metadataMode,
            imageRefreshMode: imageMode,
            isReplaceAllMetadata: replaceAllMetadata,
            isReplaceAllImages: replaceAllImages
        )
        _ = try await client.send(Paths.refreshItem(itemID: id, parameters: params))
        cache.clear()
    }

    public func deleteItem(id: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.deleteItem(itemID: id))
        cache.clear()
    }

    public func downloadRemoteImage(itemId: String, type: JellyfinAPI.ImageType, imageURL: String) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.DownloadRemoteImageParameters(type: type, imageURL: imageURL)
        _ = try await client.send(Paths.downloadRemoteImage(itemID: itemId, parameters: params))
        cache.clear()
    }

    public func deleteItemImage(id: String, type: JellyfinAPI.ImageType, index: Int?) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        // SDK path takes imageType as String (the wire format is the raw value).
        if let index {
            _ = try await client.send(Paths.deleteItemImageByIndex(itemID: id, imageType: type.rawValue, imageIndex: index))
        } else {
            _ = try await client.send(Paths.deleteItemImage(itemID: id, imageType: type.rawValue))
        }
        cache.clear()
    }

    public func searchRemoteMovies(query: MovieInfoRemoteSearchQuery) async throws -> [RemoteSearchResult] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getMovieRemoteSearchResults(query))
        return response.value
    }

    public func searchRemoteSeries(query: SeriesInfoRemoteSearchQuery) async throws -> [RemoteSearchResult] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getSeriesRemoteSearchResults(query))
        return response.value
    }

    public func applyRemoteSearchResult(itemId: String, result: RemoteSearchResult, replaceAllImages: Bool) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        _ = try await client.send(Paths.applySearchCriteria(itemID: itemId, isReplaceAllImages: replaceAllImages, result))
        cache.clear()
    }
}
