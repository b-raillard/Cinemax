import Foundation
import JellyfinAPI

// MARK: - Offline-downloads feature flag (global)
//
// See `OfflineFeatureFlag` for why the global flag lives in the Branding
// `CustomCss`. The per-user half of the gate is the native Jellyfin policy
// `UserPolicy.enableContentDownloading`, edited via `updateUserPolicy`.

extension JellyfinAPIClient {
    /// Reads the global offline-downloads flag. Uses the public
    /// `/Branding/Configuration` endpoint so *any* signed-in user (not just
    /// admins) can evaluate the gate. Uncached — the flag must reflect an
    /// admin's change on the next `refreshCurrentUser()` pass.
    public func isOfflineDownloadsEnabledGlobally() async throws -> Bool {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let response = try await client.send(Paths.getBrandingOptions)
        return OfflineFeatureFlag.isEnabled(customCss: response.value.customCss)
    }

    /// Admin-only: flips the global offline-downloads flag by rewriting the
    /// Branding `CustomCss` marker. Read-modify-write so the admin's own
    /// custom CSS, login disclaimer, and splashscreen setting are preserved.
    public func setOfflineDownloadsEnabledGlobally(_ enabled: Bool) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        // Authoritative admin read of the branding store (same shape as the
        // public endpoint, but never served from any intermediary cache).
        let current = try await client.send(Paths.getNamedConfiguration(key: "branding"))
        // Throwing decode on purpose (same as `getEncodingOptions`): a decode
        // failure must abort the write — falling back to an empty DTO here
        // would clobber the admin's CustomCss / LoginDisclaimer on the server.
        var options = try JSONDecoder().decode(BrandingOptionsDto.self, from: current.value)
        options.customCss = OfflineFeatureFlag.applying(enabled: enabled, to: options.customCss)
        // Round-trip through AnyJSON — SDK's named-configuration endpoint is
        // type-erased (same pattern as `updateEncodingOptions`).
        let data = try JSONEncoder().encode(options)
        let anyJSON = try JSONDecoder().decode(AnyJSON.self, from: data)
        _ = try await client.send(Paths.updateNamedConfiguration(key: "branding", anyJSON))
    }
}
