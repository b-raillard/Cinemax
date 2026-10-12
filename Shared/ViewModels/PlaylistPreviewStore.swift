import SwiftUI
import OSLog
import CinemaxKit
import JellyfinAPI

private let logger = Logger(subsystem: "com.cinemax", category: "PlaylistPreview")

// MARK: - Playlist cover: the pure part

/// One poster on a playlist cover: the item whose primary image is drawn, and
/// that image's tag (the cache-buster every image URL carries).
struct PlaylistCoverPoster: Hashable, Sendable {
    let itemId: String
    let tag: String?
}

/// What a playlist card knows beyond `getPlaylists`: the posters its cover
/// fans out, and the playlist's real length.
struct PlaylistPreview: Equatable, Sendable {
    /// Front first, at most `PlaylistCoverStack.maxPosters`, never repeated.
    let posters: [PlaylistCoverPoster]
    let totalCount: Int
}

/// What a cover draws.
enum PlaylistCoverContent: Equatable {
    /// A neutral ground, deliberately WITHOUT the empty icon: nothing known
    /// yet (a playlist with contents must never flash « vide » first), or
    /// contents known but none of them drawable (every fetched entry hidden
    /// by the age cap, or id-less) — the count beside it says it is not empty.
    case neutral
    /// Known to hold nothing drawable.
    case empty
    /// Front first, 1 to 3 posters.
    case posters([PlaylistCoverPoster])
}

/// The « pile d'affiches » cover, as data: which posters, and where each one
/// sits. Pure, so the layout rules are testable without a view.
///
/// Jellyfin's own playlist image is a 2×2 mosaic that REPEATS its posters when
/// the playlist holds one or two — a single film drawn four times. This cover
/// fans out at most three distinct posters instead, and with fewer entries it
/// simply shows fewer posters.
enum PlaylistCoverStack {
    /// The most posters a cover fans out.
    static let maxPosters = 3
    /// How many entries a preview asks for. Far more than `maxPosters`
    /// because Jellyfin stores a series added to a playlist as ALL its
    /// episodes: a playlist opening on a show starts with a run of its
    /// episodes, which collapse to one poster, and four entries drew a single
    /// poster on a three-title playlist. Cheap: no userData, the primary tag
    /// only.
    static let previewLimit = 24
    /// A poster's height, as a fraction of the cover's side (posters are 2:3).
    static let posterHeightFraction: CGFloat = 0.7
    /// A poster's corner radius, as a fraction of the cover's side — the
    /// mock-up rounds a poster with the cover's scale, not a fixed token.
    static let posterCornerFraction: CGFloat = 0.025

    /// Where one poster sits, as fractions of the cover's side.
    struct Slot: Equatable {
        /// Index into the posters, 0 being the front one.
        let posterIndex: Int
        /// Degrees, clockwise.
        let rotation: Double
        let xOffset: CGFloat
        let yOffset: CGFloat
    }

    /// The poster that stands for one entry. An EPISODE is drawn with its
    /// series' poster: its own primary image is a 16:9 still, which a 2:3 slot
    /// would crop down to a sliver.
    static func poster(for item: BaseItemDto) -> PlaylistCoverPoster? {
        if item.type == .episode, let seriesId = item.seriesID {
            return PlaylistCoverPoster(itemId: seriesId, tag: item.seriesPrimaryImageTag)
        }
        guard let id = item.id else { return nil }
        return PlaylistCoverPoster(itemId: id, tag: item.primaryImageTagValue)
    }

    /// Up to `maxPosters` distinct posters, in playlist order. Distinct by the
    /// item DRAWN, so the same film twice — or three episodes of one show —
    /// is one poster, never the same artwork side by side.
    static func posters(from items: [BaseItemDto]) -> [PlaylistCoverPoster] {
        var seen = Set<String>()
        var result: [PlaylistCoverPoster] = []
        for item in items {
            guard let poster = poster(for: item), seen.insert(poster.itemId).inserted else { continue }
            result.append(poster)
            if result.count == maxPosters { break }
        }
        return result
    }

    /// The slots for `count` posters, in DRAWING order (back to front). One
    /// poster stands alone, centred; two add the one on the left; three add
    /// the one on the right. No poster index ever appears twice. The whole
    /// stack sits 2 % below centre (the validated mock-up), the two back
    /// posters 3 % lower still.
    static func slots(count: Int) -> [Slot] {
        let front = Slot(posterIndex: 0, rotation: 0, xOffset: 0, yOffset: 0.02)
        let left = Slot(posterIndex: 1, rotation: -9, xOffset: -0.15, yOffset: 0.05)
        let right = Slot(posterIndex: 2, rotation: 9, xOffset: 0.15, yOffset: 0.05)
        if count <= 0 { return [] }
        if count == 1 { return [front] }
        if count == 2 { return [left, front] }
        return [right, left, front]
    }

    /// One poster in its slot — what the cover draws, back to front.
    struct PlacedPoster: Equatable, Identifiable {
        let slot: Slot
        let poster: PlaylistCoverPoster
        var id: Int { slot.posterIndex }
    }

    /// `posters` (front first) matched to their slots, in drawing order. The
    /// pairing is done here rather than by subscripting in the view, so a
    /// slot can never name a poster that is not there.
    static func placed(_ posters: [PlaylistCoverPoster]) -> [PlacedPoster] {
        slots(count: posters.count).compactMap { slot in
            guard posters.indices.contains(slot.posterIndex) else { return nil }
            return PlacedPoster(slot: slot, poster: posters[slot.posterIndex])
        }
    }

    /// What a card's cover draws, from what is known so far. `fallbackCount`
    /// is `getPlaylists`' `childCount`: a playlist it already reports empty
    /// shows its empty cover at once instead of waiting on a preview. A
    /// preview with entries but no drawable poster stays neutral: the « vide »
    /// icon beside « 5 éléments » would contradict itself.
    static func content(preview: PlaylistPreview?, fallbackCount: Int?) -> PlaylistCoverContent {
        if let preview {
            if !preview.posters.isEmpty { return .posters(preview.posters) }
            return preview.totalCount > 0 ? .neutral : .empty
        }
        return fallbackCount == 0 ? .empty : .neutral
    }
}

// MARK: - The store

/// Holds every playlist card's preview (cover posters + count), keyed by
/// playlist id, so the Home rail, « Vos playlists » and any later surface
/// share one fetch per playlist.
///
/// - **Lazy**: a card asks from its own `.task(id:)`, and cards live in lazy
///   containers, so only the playlists actually drawn are fetched.
/// - **One request in flight per playlist**: a second ask while one is running
///   joins it.
/// - **Stale, never blank**: `.cinemaxPlaylistsChanged` and
///   `.cinemaxShouldRefreshCatalogue` bump `generation` and KEEP every preview
///   held. Cards key their task on `generation`, so each card on screen re-asks
///   once and swaps its cover when the answer lands — no flash back to the
///   loading ground. A card off screen re-asks when it next appears.
/// - The fetch runs in the store's own task, not the card's: a card scrolled
///   out of a lazy rail mid-request does not cancel it.
///
/// Process singleton, like the presenters injected at the root: it observes
/// the two notifications itself, so screens that are alive at the same time
/// (Home, with « Vos playlists » pushed above it) don't invalidate it twice.
/// Plain stored properties, no `didSet` (the `@Observable` RULE).
@MainActor
@Observable
final class PlaylistPreviewStore {
    static let shared = PlaylistPreviewStore()

    /// Bumped by `invalidate()`. Cards fold it into their `.task(id:)`.
    private(set) var generation = 0
    private(set) var previews: [String: PlaylistPreview] = [:]

    /// The generation each held preview was fetched in — current means fresh.
    @ObservationIgnored private var loadedGeneration: [String: Int] = [:]
    @ObservationIgnored private var inFlight: [String: InFlight] = [:]
    /// Whose previews these are, and under which content-age cap. Another
    /// account (a user switch, another server) or another cap starts from
    /// nothing: what a cover may show depends on both, and keeping the old
    /// previews "until the refetch lands" would leave a poster the new cap
    /// hides on screen — for good, if that refetch fails.
    @ObservationIgnored private var owner: Owner?
    /// Bumped by that reset, so an answer for the previous account is dropped.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var observerTokens: [any NSObjectProtocol] = []

    private struct InFlight {
        let generation: Int
        let task: Task<Void, Never>
    }

    private struct Owner: Equatable {
        let userId: String
        let contentAgeCap: Int
    }

    /// `notificationCenter` is injectable so a test can post without touching
    /// the shared store every other suite reads.
    init(notificationCenter: NotificationCenter = .default) {
        for name in [Notification.Name.cinemaxPlaylistsChanged, .cinemaxShouldRefreshCatalogue] {
            // `.main`: every poster of these two is main-actor code, and the
            // block then runs on the main thread whoever posts.
            let token = notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.invalidate()
                }
            }
            observerTokens.append(token)
        }
    }

    func preview(for playlistId: String) -> PlaylistPreview? {
        previews[playlistId]
    }

    /// Starts fetching `playlistId`'s preview unless the one held is current
    /// or a fetch for this generation is already running. Returns the running
    /// fetch — a test awaits it; a card never does. `contentAgeCap` is the
    /// Privacy & Security ceiling (`SettingsKey.privacyMaxContentAge`), which
    /// the client applies to what the preview returns.
    @discardableResult
    func load(playlistId: String, userId: String, contentAgeCap: Int = 0, api: any PlaylistAPI) -> Task<Void, Never>? {
        let requester = Owner(userId: userId, contentAgeCap: contentAgeCap)
        if requester != owner { reset(for: requester) }
        if loadedGeneration[playlistId] == generation { return nil }
        if let running = inFlight[playlistId], running.generation == generation { return running.task }

        let requestGeneration = generation
        let requestEpoch = epoch
        let task = Task { [weak self] in
            var preview: PlaylistPreview?
            do {
                let page = try await api.getPlaylistPreview(
                    playlistId: playlistId, userId: userId, limit: PlaylistCoverStack.previewLimit
                )
                preview = PlaylistPreview(
                    posters: PlaylistCoverStack.posters(from: page.items),
                    totalCount: page.totalCount
                )
            } catch {
                // The card keeps what it shows (a previous preview, or its
                // `childCount` and the neutral ground) — a cover is decoration.
                // A reset (another account) cancels its fetches: not a failure.
                if !Task.isCancelled {
                    logger.warning("Playlist preview failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            self?.finish(playlistId: playlistId, generation: requestGeneration, epoch: requestEpoch, preview: preview)
        }
        inFlight[playlistId] = InFlight(generation: requestGeneration, task: task)
        return task
    }

    /// Marks every held preview stale WITHOUT dropping it: cards keep drawing
    /// it until the refetch lands.
    func invalidate() {
        generation += 1
    }

    private func finish(playlistId: String, generation requestGeneration: Int, epoch requestEpoch: Int, preview: PlaylistPreview?) {
        guard requestEpoch == epoch else { return }
        if inFlight[playlistId]?.generation == requestGeneration { inFlight[playlistId] = nil }
        guard let preview else { return }
        // Two fetches can overlap across an invalidation; the older one must
        // never overwrite what the newer one already brought.
        if let held = loadedGeneration[playlistId], held > requestGeneration { return }
        loadedGeneration[playlistId] = requestGeneration
        // Equality-guarded: `@Observable` notifies even for an identical value,
        // and every card on screen reads this dictionary.
        if previews[playlistId] != preview { previews[playlistId] = preview }
    }

    private func reset(for newOwner: Owner) {
        owner = newOwner
        epoch += 1
        for running in inFlight.values { running.task.cancel() }
        inFlight = [:]
        loadedGeneration = [:]
        if !previews.isEmpty { previews = [:] }
    }
}
