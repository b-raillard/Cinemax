import Testing
import Foundation
import JellyfinAPI
@testable import Cinemax
@testable import CinemaxKit

/// Locks the merge that turns two overlapping server views — SyncPlay groups
/// and active sessions — into one "En direct" row.
@Suite("Live sessions row merge")
struct LiveSessionsRowTests {

    private func session(_ id: String, user: String, itemId: String, title: String, position: Int? = nil) -> SessionInfoDto {
        var item = BaseItemDto()
        item.id = itemId
        item.name = title
        item.runTimeTicks = 60_000_000_000
        var s = SessionInfoDto()
        s.id = id
        s.userName = user
        s.nowPlayingItem = item
        if let position {
            var state = PlayerStateInfo()
            state.positionTicks = position
            s.playState = state
        }
        return s
    }

    @Test("A group folds its members into one card instead of one card each")
    func groupCollapses() {
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Soirée", participants: ["Marie", "Paul"])],
            sessions: [
                session("s1", user: "Marie", itemId: "i1", title: "Downton Abbey"),
                session("s2", user: "Paul", itemId: "i1", title: "Downton Abbey")
            ],
            currentUserName: "Bastien"
        )
        #expect(entries.count == 1)
        #expect(entries[0].isTogether)
        #expect(entries[0].participants == ["Marie", "Paul"])
        // Artwork is borrowed from whichever member's session we can see.
        #expect(entries[0].itemId == "i1")
        #expect(entries[0].title == "Downton Abbey")
    }

    @Test("Someone watching alone keeps their own card")
    func soloSurvives() {
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Soirée", participants: ["Marie", "Paul"])],
            sessions: [
                session("s1", user: "Marie", itemId: "i1", title: "Downton Abbey"),
                session("s3", user: "Léa", itemId: "i2", title: "Le Parrain 3")
            ],
            currentUserName: "Bastien"
        )
        #expect(entries.count == 2)
        #expect(entries[0].isTogether)
        #expect(entries[1].kind == .solo(sessionId: "s3"))
        #expect(entries[1].participants == ["Léa"])
    }

    @Test("A non-admin sees groups with no sessions to draw artwork from")
    func groupsWithoutSessions() {
        // `/Sessions` is admin-only, so a regular account reaches this with an
        // empty session list. The card must still render — a nil title is an
        // ordinary outcome here, since GroupInfoDto carries no item.
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Soirée", participants: ["Marie", "Paul"])],
            sessions: [],
            currentUserName: "Bastien"
        )
        #expect(entries.count == 1)
        #expect(entries[0].itemId == nil)
        #expect(entries[0].title == nil)
        #expect(entries[0].participants == ["Marie", "Paul"])
    }

    @Test("The viewer is never listed as someone to watch with")
    func dropsSelf() {
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Soirée", participants: ["Bastien", "Marie"])],
            sessions: [session("s9", user: "Bastien", itemId: "i1", title: "Arrow")],
            currentUserName: "Bastien"
        )
        #expect(entries.count == 1)
        #expect(entries[0].participants == ["Marie"])
    }

    @Test("A group holding only the viewer produces no card at all")
    func selfOnlyGroupDropped() {
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Seul", participants: ["Bastien"])],
            sessions: [],
            currentUserName: "Bastien"
        )
        #expect(entries.isEmpty)
    }

    @Test("A group with no id is refused — it cannot be joined")
    func idlessGroupDropped() {
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "", name: "Fantôme", participants: ["Marie"])],
            sessions: [],
            currentUserName: "Bastien"
        )
        #expect(entries.isEmpty)
    }

    @Test("Progress comes from the session's play state")
    func progress() {
        let entries = LiveSessionsRow.build(
            groups: [],
            sessions: [session("s1", user: "Marie", itemId: "i1", title: "Arrow", position: 15_000_000_000)],
            currentUserName: "Bastien"
        )
        let progress = try? #require(entries.first?.progress)
        #expect(progress != nil)
        #expect(abs((progress ?? 0) - 0.25) < 0.001)
    }

    @Test("Server policy governs joining and creating")
    func policyGate() {
        #expect(LiveSessionsRow.canJoin(.createAndJoinGroups))
        #expect(LiveSessionsRow.canJoin(.joinGroups))
        #expect(!LiveSessionsRow.canJoin(.none))
        // An unknown policy is treated as no access — same discipline as
        // ServerVersion, where an unknown version is unsupported.
        #expect(!LiveSessionsRow.canJoin(nil))

        #expect(LiveSessionsRow.canCreate(.createAndJoinGroups))
        #expect(!LiveSessionsRow.canCreate(.joinGroups))
        #expect(!LiveSessionsRow.canCreate(nil))
    }
}
