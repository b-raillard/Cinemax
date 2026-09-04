import Foundation
import CinemaxKit
import JellyfinAPI

/// Builds the merged "En direct" row: Watch Together sessions and people
/// watching alone, in one list.
///
/// **Why merged rather than a second row.** A SyncPlay group and the `/Sessions`
/// list describe the same people from two angles: Marie and Paul watching
/// together appear as *one* group and as *two* sessions on the same title. Two
/// neighbouring rows stating that differently does not read as richness, it
/// reads as a bug — and folding a group into a single card also fixes something
/// the row already got wrong on its own, where three people on one film drew
/// three identical cards.
///
/// **The two sources carry different permissions, and that is what unlocks the
/// feature.** `/Sessions` is admin-only here (it leaks every user's session on
/// some servers), while `GET /SyncPlay/List` is governed by the server's own
/// `UserPolicy.syncPlayAccess`. So a non-admin sees the sessions and nothing
/// else; an admin sees both. Neither is faked in the other's absence.
enum LiveSessionsRow {

    /// One card in the row.
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A Watch Together group. `groupId` is the join target.
            case together(groupId: String)
            /// One person watching alone.
            case solo(sessionId: String)
        }

        let id: String
        let kind: Kind
        /// Everyone on this card, excluding the viewer.
        let participants: [String]
        /// What is playing. **`nil` is an ordinary outcome, not an error**:
        /// `GroupInfoDto` carries no item at all, so a group's title is
        /// unknowable to a non-admin until they join.
        let itemId: String?
        let backdropItemId: String?
        let backdropTag: String?
        let title: String?
        let itemType: BaseItemKind?
        let positionTicks: Int?
        let runtimeTicks: Int?

        var isTogether: Bool { if case .together = kind { return true }; return false }

        /// Fraction watched, or `nil` when the position is unknown.
        var progress: Double? {
            guard let positionTicks, let runtimeTicks, runtimeTicks > 0 else { return nil }
            return min(1, max(0, Double(positionTicks) / Double(runtimeTicks)))
        }
    }

    /// - Parameters:
    ///   - groups: from `syncPlayListGroups()`. Empty when the account has no
    ///     SyncPlay access, which is a legitimate server policy.
    ///   - sessions: from `getActiveSessions`. Empty for a non-admin — the row
    ///     still renders, with groups only.
    ///   - currentUserName: dropped from every card. Seeing yourself listed as
    ///     someone to watch with is nonsense.
    static func build(
        groups: [SyncPlayGroup],
        sessions: [SessionInfoDto],
        currentUserName: String?
    ) -> [Entry] {
        var entries: [Entry] = []
        // Everyone accounted for by a group, so their solo session is not also
        // drawn — the duplication this merge exists to remove.
        var claimed = Set<String>()

        for group in groups where !group.id.isEmpty {
            let others = group.participants.filter { $0 != currentUserName }
            claimed.formUnion(group.participants)
            // A group whose only member is the viewer is not something to join.
            guard !others.isEmpty else { continue }

            // Artwork comes from any participant's session, when we can see one.
            let session = sessions.first {
                guard let name = $0.userName else { return false }
                return group.participants.contains(name) && $0.nowPlayingItem != nil
            }
            let item = session?.nowPlayingItem

            entries.append(Entry(
                id: "group-" + group.id,
                kind: .together(groupId: group.id),
                participants: others.sorted(),
                itemId: item?.id,
                backdropItemId: item?.backdropItemID ?? item?.id,
                backdropTag: item?.backdropImageTagValue,
                title: item.map { ($0.seriesName ?? $0.name) ?? "" },
                itemType: item?.type,
                positionTicks: session?.playState?.positionTicks,
                runtimeTicks: item?.runTimeTicks
            ))
        }

        for session in sessions {
            guard let sessionId = session.id,
                  let name = session.userName,
                  name != currentUserName,
                  !claimed.contains(name),
                  let item = session.nowPlayingItem,
                  let itemId = item.id else { continue }

            entries.append(Entry(
                id: "session-" + sessionId,
                kind: .solo(sessionId: sessionId),
                participants: [name],
                itemId: itemId,
                backdropItemId: item.backdropItemID ?? itemId,
                backdropTag: item.backdropImageTagValue,
                title: (item.seriesName ?? item.name) ?? "",
                itemType: item.type,
                positionTicks: session.playState?.positionTicks,
                runtimeTicks: item.runTimeTicks
            ))
        }

        // Groups lead: they are the only cards that can be joined, and a row
        // whose actionable entries are scattered through it reads as a list of
        // people rather than a list of doors.
        return entries
    }

    /// Whether the account may take part at all, per the server's own policy.
    ///
    /// Gating on this rather than on an invented flag matters: Jellyfin already
    /// models the permission (`None` / `JoinGroups` / `CreateAndJoinGroups`) and
    /// the client had no notion of it, so it would offer "Watch together" to
    /// accounts the server then refuses.
    static func canJoin(_ access: SyncPlayUserAccessType?) -> Bool {
        // Unwrapped before the switch: `.none` is both a case of this enum and
        // `Optional.none`, and matching the optional directly is ambiguous.
        // An absent policy means "we don't know yet" and resolves to false —
        // the same discipline as `ServerVersion.serverSupports`, where an
        // unknown version is treated as unsupported.
        guard let access else { return false }
        switch access {
        case .createAndJoinGroups, .joinGroups: return true
        case .none: return false
        }
    }

    /// Whether the account may *start* a session (a stricter right than joining).
    static func canCreate(_ access: SyncPlayUserAccessType?) -> Bool {
        access == .createAndJoinGroups
    }
}
