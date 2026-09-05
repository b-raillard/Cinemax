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

    @Test("Without the sessions half, the card falls back to the group's name")
    func groupsWithoutSessions() {
        // An account without `canSeeOthers` reaches this with an empty session
        // list, so there is no artwork and no item — but the group NAME does
        // reach every member, and the create sheet seeds it with the work's
        // title. That is the only thing such a card can say, and saying it is
        // what stops it reading "Séance en cours" to everyone but an admin.
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Downton Abbey", participants: ["Marie", "Paul"])],
            sessions: [],
            currentUserName: "Bastien"
        )
        #expect(entries.count == 1)
        #expect(entries[0].itemId == nil)
        #expect(entries[0].title == "Downton Abbey")
        #expect(entries[0].participants == ["Marie", "Paul"])
    }

    @Test("A blank group name leaves the title nil rather than empty")
    func blankGroupNameStaysNil() {
        // The view substitutes "Séance en cours" for a nil title; an empty
        // string would sail past that and draw a card with no headline at all.
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "   ", participants: ["Marie"])],
            sessions: [],
            currentUserName: "Bastien"
        )
        #expect(entries.count == 1)
        #expect(entries[0].title == nil)
    }

    @Test("A session's own title still wins over the group name")
    func sessionTitleWins() {
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Soirée du samedi", participants: ["Marie"])],
            sessions: [session("s1", user: "Marie", itemId: "i1", title: "Le Parrain")],
            currentUserName: "Bastien"
        )
        #expect(entries[0].title == "Le Parrain")
    }

    @Test("State and age ride along; a solo card carries neither")
    func stateAndAge() {
        let opened = Date().addingTimeInterval(-4 * 60)
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(
                id: "g1", name: "Arrow", participants: ["Marie"],
                state: "Paused", lastUpdatedAt: opened
            )],
            sessions: [session("s3", user: "Léa", itemId: "i2", title: "Toy Story")],
            currentUserName: "Bastien"
        )
        #expect(entries[0].groupState == .paused)
        #expect(entries[0].minutesSinceUpdate() == 4)
        // A solo session is not a group: it has no transport state to report.
        #expect(entries[1].groupState == nil)
        #expect(entries[1].minutesSinceUpdate() == nil)
    }

    @Test("A timestamp in the future reads as just opened, never as negative")
    func futureTimestampClamped() {
        // A client clock a few seconds ahead of the server's is ordinary; it
        // must not produce "opened -1 min ago".
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(
                id: "g1", name: "Arrow", participants: ["Marie"],
                state: "Playing", lastUpdatedAt: Date().addingTimeInterval(120)
            )],
            sessions: [],
            currentUserName: "Bastien"
        )
        #expect(entries[0].minutesSinceUpdate() == 0)
    }

    @Test("An unknown group state is dropped rather than guessed")
    func unknownStateDropped() {
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Arrow", participants: ["Marie"], state: "Levitating")],
            sessions: [],
            currentUserName: "Bastien"
        )
        #expect(entries[0].groupState == nil)
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

    @Test("A group holding only the viewer keeps its card — it is the way out")
    func selfOnlyGroupKeepsItsExit() {
        // The server keeps a membership across an app kill, so this is what a
        // relaunch finds: nobody else in the group, and this process knowing
        // nothing about it. Dropping the card took away the app's only exit
        // while everyone else's Accueil still listed the account as present.
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Seul", participants: ["Bastien"])],
            sessions: [],
            currentUserName: "Bastien"
        )
        #expect(entries.count == 1)
        #expect(entries[0].viewerIsParticipant)
        #expect(entries[0].participants.isEmpty)
    }

    @Test("A group holding nobody the viewer knows of is still dropped")
    func emptyGroupDropped() {
        // Same shape, opposite membership: the viewer is NOT in it and there is
        // nobody to join, so there is nothing to draw.
        let entries = LiveSessionsRow.build(
            groups: [SyncPlayGroup(id: "g1", name: "Vide", participants: [])],
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

    @Test("Seeing other people's activity is a per-user permission, not an admin gate")
    func seeOthersGate() {
        func policy(_ remoteControl: Bool?) -> UserPolicy {
            var p = UserPolicy(authenticationProviderID: "", passwordResetProviderID: "")
            p.enableRemoteControlOfOtherUsers = remoteControl
            return p
        }

        // An administrator always qualifies — the policy flag is what opens the
        // half of the row that used to be theirs alone.
        #expect(LiveSessionsRow.canSeeOthers(isAdministrator: true, policy: policy(false)))
        #expect(LiveSessionsRow.canSeeOthers(isAdministrator: true, policy: nil))

        #expect(LiveSessionsRow.canSeeOthers(isAdministrator: false, policy: policy(true)))
        #expect(!LiveSessionsRow.canSeeOthers(isAdministrator: false, policy: policy(false)))
        // Absent means unknown, and unknown means refused — the same discipline
        // as `canJoin` and `ServerVersion.serverSupports`.
        #expect(!LiveSessionsRow.canSeeOthers(isAdministrator: false, policy: policy(nil)))
        #expect(!LiveSessionsRow.canSeeOthers(isAdministrator: false, policy: nil))
    }
}
