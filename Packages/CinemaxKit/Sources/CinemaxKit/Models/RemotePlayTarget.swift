import Foundation
@preconcurrency import JellyfinAPI

/// One Jellyfin session this user can drive from here — the "Play on…" picker's
/// row model. A flattened, `Sendable` projection of `SessionInfoDto`: the DTO
/// itself carries a `BaseItemDto` and isn't Sendable, and the view only needs
/// these four strings.
public struct RemotePlayTarget: Identifiable, Sendable, Equatable {
    /// Jellyfin session id — what `POST /Sessions/{id}/Playing` addresses.
    public let id: String
    /// Best-effort device name. May be empty: the view localizes the fallback
    /// (the model has no `LocalizationManager`).
    public let name: String
    /// Client app name ("Jellyfin for Apple TV"), shown as the row subtitle.
    public let clientName: String?
    /// What the target is already playing, when it is — warns the user that
    /// sending will interrupt something.
    public let nowPlayingTitle: String?

    public init(id: String, name: String, clientName: String?, nowPlayingTitle: String?) {
        self.id = id
        self.name = name
        self.clientName = clientName
        self.nowPlayingTitle = nowPlayingTitle
    }

    /// Filters and orders the sessions the server returned into sendable targets.
    ///
    /// Pure on purpose — the filtering rules are exactly where a silent mistake
    /// costs the most (sending a film to a stranger's TV), so they're locked by
    /// unit tests rather than by an eyeball check.
    ///
    /// **RULE — the `userID == currentUserId` test is defense in depth, not
    /// redundancy.** `GET /Sessions?controllableByUserId=` is supposed to filter
    /// server-side, but the unfiltered endpoint leaks every user's session to
    /// non-admins on some servers (jellyfin#5210); a server that ignored the
    /// parameter would otherwise let one tap start a film on someone else's TV.
    /// A session with no `userID` can't be verified and is dropped.
    public static func resolve(
        sessions: [SessionInfoDto],
        currentUserId: String,
        excludingDeviceId: String?
    ) -> [RemotePlayTarget] {
        sessions
            .filter { session in
                guard let id = session.id, !id.isEmpty else { return false }
                guard session.userID == currentUserId else { return false }
                guard session.isSupportsRemoteControl == true else { return false }
                if let excludingDeviceId, session.deviceID == excludingDeviceId { return false }
                // Older clients under-report their capabilities, so an absent
                // or empty list is treated as "unknown", not as "no video".
                if let types = session.playableMediaTypes, !types.isEmpty,
                   !types.contains(.video) { return false }
                return true
            }
            .map { session in
                let device = session.deviceName ?? ""
                let name = device.isEmpty ? (session.client ?? "") : device
                return RemotePlayTarget(
                    id: session.id ?? "",
                    name: name,
                    clientName: session.client,
                    nowPlayingTitle: session.nowPlayingItem?.name
                )
            }
            // Total order: the comparison folds case and diacritics, so equal
            // names fall through to the session id and the list stays stable
            // between two polls instead of shuffling under the user's finger.
            .sorted { lhs, rhs in
                let cmp = lhs.name.compare(
                    rhs.name,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: nil,
                    locale: nil
                )
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            }
    }
}
