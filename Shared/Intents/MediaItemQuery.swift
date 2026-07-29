#if os(iOS)
import AppIntents
import Foundation
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Resolves library items for Siri and the Shortcuts editor.
///
/// Runs **without the app's UI** — see `IntentSessionProvider`. Every entry
/// point rebuilds its own session, because there is no guarantee the app has a
/// scene (or has ever launched) when the system asks.
///
/// No local index backs this: matching goes straight to the server through
/// `LibrarySearchRanker`, the same path the search screen uses. That shared path
/// is what makes a dictated title resolvable — it folds the punctuation and
/// diacritics dictation drops. The cost is that resolution needs the network;
/// offline, the honest answer is "nothing", not a stale guess.
struct MediaItemQuery: EntityStringQuery {

    /// Enough to disambiguate, few enough that a Siri list stays usable and a
    /// picker doesn't turn into an unscrollable dump of a large library.
    private static let maxResults = 12

    /// What a spoken or typed title may match. Mirrors `SearchScope.all`.
    private static let searchableKinds: [BaseItemKind] = [.movie, .series, .episode]

    // MARK: Re-resolving a saved shortcut

    /// **The cross-server guard.** A shortcut built while signed in to one
    /// server must not resolve against another — silently playing a different
    /// item would be worse than failing. Identities that don't belong to the
    /// active server are dropped, and App Intents surfaces that as an
    /// unresolvable parameter.
    func entities(for identifiers: [String]) async throws -> [MediaItemEntity] {
        guard let session = IntentSessionProvider.makeSession() else { return [] }
        let serverId = session.context.serverId

        var resolved: [MediaItemEntity] = []
        for raw in identifiers {
            guard let parsed = MediaEntityID(rawValue: raw), parsed.belongs(to: serverId) else { continue }
            guard let item = try? await session.api.getItem(
                userId: session.context.userId,
                itemId: parsed.itemId
            ) else { continue }
            if let entity = MediaItemEntity(item: item, serverId: serverId) {
                resolved.append(entity)
            }
        }
        return resolved
    }

    // MARK: Matching a spoken or typed title

    func entities(matching string: String) async throws -> [MediaItemEntity] {
        guard let session = IntentSessionProvider.makeSession() else { return [] }
        let query = LibrarySearchRanker.sanitize(string)
        guard !query.isEmpty else { return [] }

        let outcome = await LibrarySearchRanker.rank(
            query: query,
            userId: session.context.userId,
            includeItemTypes: Self.searchableKinds,
            api: session.api
        )
        return outcome.items
            .prefix(Self.maxResults)
            .compactMap { MediaItemEntity(item: $0, serverId: session.context.serverId) }
    }

    // MARK: Suggestions

    /// What the Shortcuts editor offers before the user types anything.
    ///
    /// In-progress items first, then the next unwatched episodes — the two
    /// things someone building a shortcut is overwhelmingly likely to want.
    /// Cheap: no search, just the two rails the home screen already loads.
    func suggestedEntities() async throws -> [MediaItemEntity] {
        guard let session = IntentSessionProvider.makeSession() else { return [] }
        let serverId = session.context.serverId
        let userId = session.context.userId

        async let resume = try? session.api.getResumeItems(userId: userId, limit: 10)
        async let nextUp = try? session.api.getNextUpEpisodes(userId: userId, limit: 10)

        let items = (await resume ?? []) + (await nextUp ?? [])

        var seen = Set<String>()
        return items
            .compactMap { MediaItemEntity(item: $0, serverId: serverId) }
            .filter { seen.insert($0.id).inserted }
            .prefix(Self.maxResults)
            .map { $0 }
    }
}
#endif
