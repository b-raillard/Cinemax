import Testing
import Foundation
@testable import CinemaxKit

/// Locks the App Group session contract that three intentionally un-deduplicated
/// copies of the shape must agree on:
///   • the app — CinemaxKit `ExtensionSessionBridge.Session` (the publisher);
///   • the iOS widget — `Widgets/CinemaxWidget/JellyfinLite.Session`;
///   • the tvOS Top Shelf — `TopShelf/CinemaxTopShelf/ContentProvider.Session`.
///
/// The two extensions deliberately don't link CinemaxKit (widget memory budget),
/// so they re-declare the suite id, the defaults key, and the JSON shape by hand.
/// A rename or recoding on the CinemaxKit side would silently break them at
/// runtime — the extension would read `nil` and fall back to its signed-out
/// state — with no compiler error to catch it. These assertions fail the moment
/// the publisher drifts, pointing the author at the two copies to update.
@Suite("Extension session contract")
struct ExtensionSessionContractTests {

    @Test("Suite + key constants match the extension copies")
    func constantsMatch() {
        // Hardcoded as string literals in JellyfinLite.swift and
        // ContentProvider.swift — keep all three in lockstep.
        #expect(ExtensionSessionBridge.appGroupId == "group.com.cinemax.shared")
        #expect(ExtensionSessionBridge.sessionKey == "extension.session")
    }

    @Test("Session encodes to exactly the keys the extensions decode")
    func jsonKeysMatch() throws {
        let session = ExtensionSessionBridge.Session(
            serverURL: URL(string: "https://jelly.example.com")!,
            accessToken: "tok-123",
            userId: "user-abc"
        )
        let data = try JSONEncoder().encode(session)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The widget / Top Shelf `Session` structs declare exactly these three
        // stored properties with default (property-name) coding keys.
        #expect(Set(object.keys) == ["serverURL", "accessToken", "userId"])
    }

    @Test("A payload in the extensions' wire shape decodes back into Session")
    func decodesExtensionWireShape() throws {
        // The exact byte shape an extension reads from the App Group defaults.
        let json = Data("""
        {"serverURL":"https://jelly.example.com","accessToken":"tok-123","userId":"user-abc"}
        """.utf8)
        let session = try JSONDecoder().decode(ExtensionSessionBridge.Session.self, from: json)
        #expect(session.serverURL == URL(string: "https://jelly.example.com"))
        #expect(session.accessToken == "tok-123")
        #expect(session.userId == "user-abc")
    }

    // Only runs where the shared access group resolves — i.e. a signed context
    // with a team prefix. Unsigned CI runners expand `$(AppIdentifierPrefix)` to
    // empty, so `sharedAccessGroup` is nil and the test is SKIPPED (not failed):
    // the Keychain mechanism is build-verified there, and the real proof is the
    // local + on-device round-trip.
    @Test(
        "Shared session round-trips through the Keychain access group",
        .enabled(if: KeychainService.sharedAccessGroup != nil)
    )
    func sharedSessionRoundTrips() {
        #expect(KeychainService.sharedAccessGroup?.hasSuffix("com.cinemax.shared") == true)

        let keychain = KeychainService()
        let payload = Data("shared-session-payload".utf8)

        keychain.deleteSharedSession()       // clean slate
        keychain.saveSharedSession(payload)
        #expect(keychain.readSharedSession() == payload)

        keychain.deleteSharedSession()
        #expect(keychain.readSharedSession() == nil)
    }
}
