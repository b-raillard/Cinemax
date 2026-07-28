import Testing
import Foundation
@testable import CinemaxKit

/// Locks the shared-session contract that three intentionally un-deduplicated
/// copies of the shape must agree on:
///   • the app — CinemaxKit `ExtensionSessionBridge.Session` (the publisher);
///   • the iOS widget — `Widgets/CinemaxWidget/JellyfinLite.Session`;
///   • the tvOS Top Shelf — `TopShelf/CinemaxTopShelf/ContentProvider.Session`.
///
/// The two extensions deliberately don't link CinemaxKit (widget memory budget),
/// so they re-declare the Keychain item identifiers and the JSON shape by hand.
/// A rename or recoding on the CinemaxKit side would silently break them at
/// runtime — the extension would read `nil` and fall back to its signed-out
/// state — with no compiler error to catch it. These assertions fail the moment
/// the publisher drifts, pointing the author at the two copies to update.
@Suite("Extension session contract")
struct ExtensionSessionContractTests {

    @Test("Legacy App Group constants still name the scrub target")
    func legacyScrubConstantsMatch() {
        // These two are NO LONGER part of the extension contract — the
        // extensions read the Keychain only (see the suite/test below). They
        // survive because `ExtensionSessionBridge.publish` uses them to delete
        // the legacy (1.0.3–1.0.6) plaintext copy of the token from the App Group
        // container on upgraded installs. Change either literal and the scrub
        // silently stops finding that blob, leaving the token in cleartext
        // forever — so they stay locked here.
        #expect(ExtensionSessionBridge.appGroupId == "group.com.cinemax.shared")
        #expect(ExtensionSessionBridge.sessionKey == "extension.session")
    }

    @Test("Keychain item identifiers match the extension copies")
    func keychainContractMatches() {
        // The shared-Keychain read in JellyfinLite.swift / ContentProvider.swift
        // hardcodes these three literals (the extensions can't link CinemaxKit).
        // Locking the CinemaxKit side fails the build if the contract drifts —
        // the only guard, since the round-trip test is skipped on unsigned CI.
        // Mirror of `kSecAttrService` / `kSecAttrAccount` / access-group suffix.
        #expect(KeychainService.serviceName == "com.cinemax.jellyfin")
        #expect(KeychainService.sharedSessionAccount == "extension_session")
        #expect(KeychainService.sharedAccessGroupSuffix == "com.cinemax.shared")
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
        // The exact byte shape an extension reads from the Keychain group.
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

/// Locks the pure equivalence decision `ExtensionSessionBridge.publish` uses to
/// skip a redundant Keychain write + WidgetCenter/Top Shelf poke when nothing
/// actually changed since the last publish. Only the decision is tested here —
/// never the WidgetCenter/Top Shelf side effects.
///
/// The decision is Keychain-only: the legacy plaintext App Group copy is no
/// longer an input (it used to force a republish whenever it went missing, to
/// keep the dual-write in step). It's scrubbed unconditionally ahead of this
/// check and never rewritten, so it can neither suppress nor trigger a publish.
@Suite("Extension session republish skip decision")
struct ExtensionSessionSkipDecisionTests {
    let session = ExtensionSessionBridge.Session(
        serverURL: URL(string: "https://jelly.example.com")!,
        accessToken: "tok-123",
        userId: "user-abc"
    )

    @Test("Keychain blob matches ⇒ current, skip publish")
    func matchingKeychainBlobSkips() throws {
        let data = try JSONEncoder().encode(session)
        #expect(ExtensionSessionBridge.isCurrent(session: session, keychainData: data))
    }

    @Test("Token changed ⇒ not current, must publish")
    func tokenChangedPublishes() throws {
        let data = try JSONEncoder().encode(session)
        let changed = ExtensionSessionBridge.Session(
            serverURL: session.serverURL,
            accessToken: "tok-456",
            userId: session.userId
        )
        #expect(!ExtensionSessionBridge.isCurrent(session: changed, keychainData: data))
    }

    @Test("Keychain copy missing ⇒ must publish")
    func missingKeychainPublishes() {
        #expect(!ExtensionSessionBridge.isCurrent(session: session, keychainData: nil))
    }

    @Test("Corrupt/undecodable Keychain blob ⇒ treated as changed, must publish")
    func corruptKeychainPublishes() {
        let corrupt = Data("not json".utf8)
        #expect(!ExtensionSessionBridge.isCurrent(session: session, keychainData: corrupt))
    }

    @Test("Keychain already empty while clearing ⇒ current, skip publish")
    func emptyKeychainClearSkips() {
        #expect(ExtensionSessionBridge.isCurrent(session: nil, keychainData: nil))
    }

    @Test("A stale Keychain blob while clearing ⇒ must publish")
    func staleKeychainClearPublishes() throws {
        let data = try JSONEncoder().encode(session)
        #expect(!ExtensionSessionBridge.isCurrent(session: nil, keychainData: data))
    }
}
