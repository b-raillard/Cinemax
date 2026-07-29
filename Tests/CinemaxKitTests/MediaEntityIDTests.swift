import Testing
import Foundation
@testable import Cinemax

/// A shortcut the user builds today is replayed weeks later, possibly after
/// they've added or switched servers. Its stored identity is therefore both
/// long-lived and user-reachable, so it gets the same treatment as a deep link:
/// composite, shape-validated, and never resolved against the wrong server.
@Suite("Media entity identity")
struct MediaEntityIDTests {

    private let serverA = "11111111-2222-3333-4444-555555555555"
    private let serverB = "99999999-8888-7777-6666-555555555555"
    private let undashedItem = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
    private let dashedItem = "550E8400-E29B-41D4-A716-446655440000"

    // MARK: Round-trip

    @Test("Survives a serialization round-trip")
    func roundTrip() throws {
        let id = MediaEntityID(serverId: serverA, itemId: undashedItem)
        let restored = try #require(MediaEntityID(rawValue: id.rawValue))
        #expect(restored == id)
        #expect(restored.serverId == serverA)
        #expect(restored.itemId == undashedItem)
    }

    @Test("Accepts both Jellyfin item-id forms")
    func bothItemIdForms() {
        #expect(MediaEntityID(rawValue: "\(serverA)|\(undashedItem)") != nil)
        #expect(MediaEntityID(rawValue: "\(serverA)|\(dashedItem)") != nil)
    }

    // MARK: Rejection

    @Test("Rejects a raw value with no separator")
    func rejectsMissingSeparator() {
        #expect(MediaEntityID(rawValue: undashedItem) == nil)
        #expect(MediaEntityID(rawValue: "") == nil)
    }

    @Test("Rejects empty components")
    func rejectsEmptyComponents() {
        #expect(MediaEntityID(rawValue: "|\(undashedItem)") == nil)
        #expect(MediaEntityID(rawValue: "\(serverA)|") == nil)
    }

    @Test("Rejects a malformed item id")
    func rejectsMalformedItemId() {
        // Same defense-in-depth as the deep-link path: only the two real
        // Jellyfin id shapes get through, so a hand-edited or corrupted
        // shortcut can't drive a lookup with arbitrary path text.
        #expect(MediaEntityID(rawValue: "\(serverA)|../../etc/passwd") == nil)
        #expect(MediaEntityID(rawValue: "\(serverA)|not-an-id") == nil)
        #expect(MediaEntityID(rawValue: "\(serverA)|a1b2c3") == nil)
    }

    @Test("Rejects extra separators rather than guessing")
    func rejectsExtraSeparators() {
        #expect(MediaEntityID(rawValue: "\(serverA)|\(undashedItem)|extra") == nil)
    }

    // MARK: Server scoping

    @Test("Belongs only to the server it was minted against")
    func serverScoping() {
        // The whole point of the composite id: a shortcut saved while on one
        // server must fail cleanly on another, never play a different item.
        let id = MediaEntityID(serverId: serverA, itemId: undashedItem)
        #expect(id.belongs(to: serverA))
        #expect(!id.belongs(to: serverB))
    }

    @Test("Two servers can hold the same item id without colliding")
    func noCrossServerCollision() {
        let onA = MediaEntityID(serverId: serverA, itemId: undashedItem)
        let onB = MediaEntityID(serverId: serverB, itemId: undashedItem)
        #expect(onA != onB)
        #expect(onA.rawValue != onB.rawValue)
    }
}
