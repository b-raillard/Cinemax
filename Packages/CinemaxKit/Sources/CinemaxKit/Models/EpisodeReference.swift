import Foundation

/// The two fields episode NAVIGATION needs about an episode: its id and its
/// title. Nothing else.
///
/// Exists because `getEpisodes` is the app's single largest payload and its
/// heaviest consumer reads almost none of it. The detail screen legitimately
/// wants the full `BaseItemDto` — overview, media sources, per-episode userData
/// for the watched marks and the progress bars. Home's prev/next navigation
/// maps, `fillMissingEpisodeNavigation` and `CardEpisodeNavigationResolver`
/// want an ordered list of (id, title) and discard the rest, yet they were
/// asking for the same thing: measured against Jellyfin 12.0 on 2026-09-10,
/// one season of *Arrow* (23 episodes) is **164 069 bytes** with the fields the
/// app requests and **18 292** without them — **9.0×** — and a Home load
/// resolves up to 40 distinct seasons.
///
/// A purpose-built value type rather than a leaner `BaseItemDto`: it is
/// `Sendable` (so it crosses the navigation fan-out's `TaskGroup` boundary
/// without a region transfer, unlike the DTO), and it makes the reduced
/// payload a compile-time fact instead of a convention — nobody can read a
/// `userData` off it that the request deliberately did not ask for. Same
/// discipline as `RemoteImageCandidate` and `CardPlayTarget`.
public struct EpisodeReference: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
