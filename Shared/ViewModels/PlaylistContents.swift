import Foundation
import JellyfinAPI

// Pure helpers behind a playlist's page, its « Ajouter des titres » picker and
// the « Ajouter à une playlist » sheet. No view, no network: what a row shows,
// which rows fold together, and what a selection will send — unit-tested in
// `PlaylistContentsTests`.

/// A run of consecutive episodes of ONE series, shown as a single folded line.
///
/// Display only. Jellyfin stores a series added to a playlist as all its
/// episodes (`Playlist.GetPlaylistItems` expands the folder at add time), so a
/// show used to open the page with one line per episode. The entries keep
/// their own ids: every mutation still addresses them one by one.
struct PlaylistSeriesRun: Equatable, Identifiable {
    let seriesId: String
    let seriesName: String
    let posterTag: String?
    let entries: [BaseItemDto]

    /// Stable across reloads as long as the run starts on the same entry.
    var id: String { "run-" + (entries.first?.playlistItemID ?? seriesId) }
    var entryIds: [String] { entries.compactMap(\.playlistItemID) }
}

/// One line of a playlist's page.
enum PlaylistDisplayRow: Equatable, Identifiable {
    case entry(BaseItemDto)
    case run(PlaylistSeriesRun)

    var id: String {
        switch self {
        case .entry(let item): item.playlistItemID ?? item.id ?? ""
        case .run(let run): run.id
        }
    }
}

enum PlaylistGrouping {
    /// Two episodes side by side stay two lines: folding them would save one
    /// row and hide both titles.
    static let minimumRun = 3

    /// The page's lines, in playlist order: consecutive episodes of the same
    /// series fold into a run once there are `minimumRun` of them.
    static func rows(from items: [BaseItemDto], minimumRun: Int = Self.minimumRun) -> [PlaylistDisplayRow] {
        var rows: [PlaylistDisplayRow] = []
        var pending: [BaseItemDto] = []

        func flush() {
            guard let first = pending.first else { return }
            if pending.count >= minimumRun, let seriesId = first.seriesID {
                rows.append(.run(PlaylistSeriesRun(
                    seriesId: seriesId,
                    seriesName: first.seriesName ?? "",
                    posterTag: first.seriesPrimaryImageTag,
                    entries: pending
                )))
            } else {
                rows.append(contentsOf: pending.map(PlaylistDisplayRow.entry))
            }
            pending = []
        }

        for item in items {
            let isEpisode = item.type == .episode && item.seriesID != nil
            if isEpisode, pending.first?.seriesID == item.seriesID {
                pending.append(item)
            } else {
                flush()
                if isEpisode { pending = [item] } else { rows.append(.entry(item)) }
            }
        }
        flush()
        return rows
    }
}

/// What a playlist already holds, for the picker's marks and the sheet's ticks.
enum PlaylistMembership {
    /// Ids of the items themselves (a film, an episode).
    static func itemIds(in items: [BaseItemDto]) -> Set<String> {
        Set(items.compactMap(\.id))
    }

    /// How many of a series' episodes sit in the playlist.
    static func episodeCount(ofSeries seriesId: String, in items: [BaseItemDto]) -> Int {
        items.count { $0.type == .episode && $0.seriesID == seriesId }
    }

    /// The ENTRY ids that stand for `itemId`: the item itself, or — for a
    /// series — every one of its episodes. Entry ids, never item ids: the same
    /// film can sit in a playlist twice and each occurrence is its own entry.
    static func entryIds(matching itemId: String, in items: [BaseItemDto]) -> [String] {
        items
            .filter { $0.id == itemId || $0.seriesID == itemId }
            .compactMap(\.playlistItemID)
    }

    /// Entries the user has finished — what « Retirer les titres vus » removes.
    static func watchedEntryIds(in items: [BaseItemDto]) -> [String] {
        items
            .filter { $0.userData?.isPlayed == true }
            .compactMap(\.playlistItemID)
    }
}

/// The picker's selection: an ORDERED list, because the order of the taps is
/// the order the titles are added in — which is what the number on each poster
/// says.
struct PlaylistPickerSelection: Equatable {
    private(set) var ids: [String] = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    /// 1-based position of `id`, `nil` when it is not selected.
    func number(of id: String) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    /// Selects `id` at the end, or deselects it — the titles after it then
    /// move up one number.
    mutating func toggle(_ id: String) {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
    }
}

extension BaseItemDto {
    /// « S01:E02 » for an episode carrying both numbers — the app's one
    /// spelling of an episode's place (`episodeLabel` prints the same).
    var playlistEpisodeCode: String? {
        guard type == .episode, let season = parentIndexNumber, let episode = indexNumber else { return nil }
        return String(format: "S%02d:E%02d", season, episode)
    }
}
