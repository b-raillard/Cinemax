import Testing
import Foundation
@testable import CinemaxKit

/// Locks the `PlayQueue` update — the message that tells a participant **what**
/// the group is watching.
///
/// It was parsed by nobody: `SyncPlayController.apply` filed `.playQueue` in a
/// branch that did nothing, so a joined client had a perfectly synchronised
/// transport and no idea which item to apply it to. The payload shape is also
/// easy to get wrong from memory — the queue lives under `Playlist` as
/// `SyncPlayQueueItem { ItemId, PlaylistItemId }`, never as a bare `ItemIds`
/// array — so these tests pin the real thing.
@Suite("SyncPlay PlayQueue parsing")
struct SyncPlayQueueParsingTests {

    private func playQueue(
        playlist: [[String: Any]],
        index: Int? = 0,
        ticks: Int? = 12_000_000,
        isPlaying: Bool? = true
    ) -> [String: Any] {
        var data: [String: Any] = ["Playlist": playlist]
        if let index { data["PlayingItemIndex"] = index }
        if let ticks { data["StartPositionTicks"] = ticks }
        if let isPlaying { data["IsPlaying"] = isPlaying }
        return ["Type": "PlayQueue", "GroupId": "g1", "Data": data]
    }

    @Test("The queue is read from Playlist, not from an ItemIds array")
    func readsPlaylist() {
        let update = JellyfinSocket.parseGroupUpdate(playQueue(playlist: [
            ["ItemId": "item-a", "PlaylistItemId": "p1"],
            ["ItemId": "item-b", "PlaylistItemId": "p2"]
        ], index: 1))
        #expect(update.type == .playQueue)
        #expect(update.playlist == ["item-a", "item-b"])
        #expect(update.playingItemIndex == 1)
        #expect(update.playingItemId == "item-b")
        #expect(update.startPositionTicks == 12_000_000)
        #expect(update.isPlaying == true)
    }

    @Test("A bare ItemIds array yields nothing — that shape does not exist")
    func rejectsInventedShape() {
        let update = JellyfinSocket.parseGroupUpdate([
            "Type": "PlayQueue",
            "Data": ["ItemIds": ["item-a"], "StartPositionTicks": 5]
        ])
        #expect(update.playlist.isEmpty)
        #expect(update.playingItemId == nil)
    }

    @Test("An out-of-range or missing index falls back to the first entry")
    func indexFallback() {
        // A nil answer here would mean a black screen for the user, so the
        // fallback is deliberate rather than defensive.
        let outOfRange = JellyfinSocket.parseGroupUpdate(playQueue(playlist: [
            ["ItemId": "item-a", "PlaylistItemId": "p1"]
        ], index: 7))
        #expect(outOfRange.playingItemId == "item-a")

        let noIndex = JellyfinSocket.parseGroupUpdate(playQueue(playlist: [
            ["ItemId": "item-a", "PlaylistItemId": "p1"]
        ], index: nil))
        #expect(noIndex.playingItemId == "item-a")
    }

    @Test("An empty queue names no item")
    func emptyQueue() {
        let update = JellyfinSocket.parseGroupUpdate(playQueue(playlist: []))
        #expect(update.playingItemId == nil)
    }

    @Test("Blank item ids are dropped rather than offered as a target")
    func blankIdsDropped() {
        let update = JellyfinSocket.parseGroupUpdate(playQueue(playlist: [
            ["ItemId": "", "PlaylistItemId": "p1"],
            ["ItemId": "item-b", "PlaylistItemId": "p2"]
        ], index: 0))
        #expect(update.playlist == ["item-b"])
        // Index 0 now addresses "item-b" — the only thing that can be opened.
        #expect(update.playingItemId == "item-b")
    }

    @Test("The queue ENTRY id is carried, not just the item id")
    func carriesPlaylistItemId() {
        // Jellyfin matches a `Ready` report against `PlaylistItemId`. Sending
        // nil — which this client always did — means the report names no entry,
        // so the participant is never counted ready and the group sits in
        // `Waiting`: a black screen where nothing ever starts.
        let update = JellyfinSocket.parseGroupUpdate(playQueue(playlist: [
            ["ItemId": "item-a", "PlaylistItemId": "entry-1"],
            ["ItemId": "item-b", "PlaylistItemId": "entry-2"]
        ], index: 1))
        #expect(update.playlistItemIds == ["entry-1", "entry-2"])
        #expect(update.playingPlaylistItemId == "entry-2")
    }

    @Test("The two lists stay positionally aligned when an entry is dropped")
    func alignmentHolds() {
        // `PlayingItemIndex` addresses both lists, so an entry dropped from one
        // must drop from the other or the index resolves to the wrong pair.
        let update = JellyfinSocket.parseGroupUpdate(playQueue(playlist: [
            ["ItemId": "", "PlaylistItemId": "entry-junk"],
            ["ItemId": "item-b", "PlaylistItemId": "entry-2"]
        ], index: 0))
        #expect(update.playlist == ["item-b"])
        #expect(update.playlistItemIds == ["entry-2"])
        #expect(update.playingItemId == "item-b")
        #expect(update.playingPlaylistItemId == "entry-2")
    }

    @Test("A queue entry with no PlaylistItemId yields an empty marker, never a crash")
    func missingEntryId() {
        let update = JellyfinSocket.parseGroupUpdate(playQueue(playlist: [
            ["ItemId": "item-a"]
        ], index: 0))
        #expect(update.playlist == ["item-a"])
        #expect(update.playingPlaylistItemId == "")
    }

    @Test("Library access denied is a recognised outcome, not an unknown type")
    func libraryAccessDenied() {
        // The group is watching something this account cannot see. Before it was
        // modelled, this reached the user as nothing at all.
        let update = JellyfinSocket.parseGroupUpdate([
            "Type": "LibraryAccessDenied", "GroupId": "g1"
        ])
        #expect(update.type == .libraryAccessDenied)
    }

    @Test("Group state is read from a StateUpdate")
    func stateUpdate() {
        let update = JellyfinSocket.parseGroupUpdate([
            "Type": "StateUpdate", "GroupId": "g1",
            "Data": ["State": "Waiting", "Reason": "Buffering"]
        ])
        #expect(update.type == .stateUpdate)
        #expect(SyncPlayGroupState(rawValue: update.state ?? "") == .waiting)
    }

    @Test("A group state the client does not know resolves to nil, never a wrong one")
    func unknownState() {
        #expect(SyncPlayGroupState(rawValue: "Rewinding") == nil)
    }
}
