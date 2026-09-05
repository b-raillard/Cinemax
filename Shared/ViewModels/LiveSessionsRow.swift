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
/// **The two sources carry different permissions, and both are now per user.**
/// `GET /SyncPlay/List` is governed by the server's own
/// `UserPolicy.syncPlayAccess`; `/Sessions` — which hands out every account's
/// current activity — by `canSeeOthers` below. Each half is fetched only when
/// its own permission allows it, and neither is ever faked in the other's
/// absence: a card that cannot be filled in is simply not drawn.
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
        /// The group's transport state. `nil` on a solo card, and on a group
        /// whose server reported none.
        let groupState: SyncPlayGroupState?
        /// When the group last changed state. This is what tells a session
        /// opened a minute ago apart from one abandoned an hour back — both of
        /// which `/SyncPlay/List` returns identically otherwise.
        let updatedAt: Date?

        var isTogether: Bool { if case .together = kind { return true }; return false }

        /// Fraction watched, or `nil` when the position is unknown.
        var progress: Double? {
            guard let positionTicks, let runtimeTicks, runtimeTicks > 0 else { return nil }
            return min(1, max(0, Double(positionTicks) / Double(runtimeTicks)))
        }

        /// Minutes since the group last changed state — floored, never
        /// negative (a client clock ahead of the server's would otherwise read
        /// as a session opened in the future). `nil` when no timestamp was
        /// reported, so the card drops the age instead of claiming "0 min".
        func minutesSinceUpdate(now: Date = Date()) -> Int? {
            guard let updatedAt else { return nil }
            return max(0, Int(now.timeIntervalSince(updatedAt) / 60))
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

            // A group carries no item, so without this a card seen by someone
            // who cannot read `/Sessions` would have no title at all. The
            // group's NAME does reach every member, and the create sheet seeds
            // it with the work's title — so the card can say what it is with no
            // permission and no extra request.
            let groupTitle = group.name.trimmingCharacters(in: .whitespaces)

            entries.append(Entry(
                id: "group-" + group.id,
                kind: .together(groupId: group.id),
                participants: others.sorted(),
                itemId: item?.id,
                backdropItemId: item?.backdropItemID ?? item?.id,
                backdropTag: item?.backdropImageTagValue,
                title: item.map { ($0.seriesName ?? $0.name) ?? "" }
                    ?? (groupTitle.isEmpty ? nil : groupTitle),
                itemType: item?.type,
                positionTicks: session?.playState?.positionTicks,
                runtimeTicks: item?.runTimeTicks,
                groupState: group.state.flatMap(SyncPlayGroupState.init(rawValue:)),
                updatedAt: group.lastUpdatedAt
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
                runtimeTicks: item.runTimeTicks,
                groupState: nil,
                updatedAt: nil
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

    /// Whether the account may see what *other people* are doing: the
    /// `/Sessions` half of this row (the "watching alone" cards) and the
    /// lobby's list of people to notify.
    ///
    /// **The gate this replaces was Cinemax's, not the server's.** `GET
    /// /Sessions` declares `DefaultAuthorization` — Jellyfin does not reserve
    /// it to administrators. It was reserved here because it hands out every
    /// account's current activity, and on some servers ignores its own
    /// `controllableByUserId` filter (jellyfin#5210). So the answer is not to
    /// keep it shut, it is to govern it per user — which is now done through
    /// the closest permission Jellyfin actually models,
    /// `UserPolicy.enableRemoteControlOfOtherUsers` ("this account may act on
    /// other people's sessions").
    ///
    /// Reusing it rather than inventing a flag is what makes the control real:
    /// it is stored server-side, edited from the admin screen this app already
    /// has, and holds for every Jellyfin client the account uses. **The cost,
    /// accepted deliberately: it also grants *controlling* those sessions, not
    /// only seeing them.** Jellyfin models nothing narrower, and the
    /// alternative — an app-side per-user flag — would need a shared store the
    /// server does not offer.
    ///
    /// An absent policy resolves to false: the same "unknown means
    /// unsupported" discipline as `canJoin`.
    static func canSeeOthers(isAdministrator: Bool, policy: UserPolicy?) -> Bool {
        if isAdministrator { return true }
        return policy?.enableRemoteControlOfOtherUsers == true
    }
}
