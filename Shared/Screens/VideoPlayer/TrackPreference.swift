import Foundation
import CinemaxKit

/// The audio and subtitle tracks the viewer picked BY HAND, remembered per
/// TITLE — a series (every episode of it, whatever the season) or a film
/// (picked up again when it is resumed) — and re-applied at every opening
/// (owner, 2026-11-24: « on ne conserve pas le réglage sous-titre et audio
/// qu'on a choisi à un épisode », then « il faut que ça soit conservé dans les
/// films aussi »).
///
/// What is kept is a DESCRIPTION of the track — language, forced or not, its
/// label as a tie-break — never a stream index or an ordinal: the next
/// episode's file can carry its tracks in another order. The two halves are
/// independent, so turning subtitles on leaves the audio to the server.
struct TrackPreference: Codable, Equatable, Sendable {
    struct Audio: Codable, Equatable, Sendable {
        var language: String?
        var label: String
        var codec: String?
    }

    enum Subtitle: Codable, Equatable, Sendable {
        case off
        case track(language: String?, isForced: Bool, label: String)
    }

    var audio: Audio?
    var subtitle: Subtitle?
    var updatedAt: Date
}

/// Pure: what a remembered choice selects among the tracks of the episode
/// being opened. `nil` = no match, the server's default applies — and the
/// preference is kept for the next episode, which may carry the track again.
enum TrackPreferencePolicy {
    static func audio(_ track: MediaTrackInfo) -> TrackPreference.Audio {
        .init(language: track.language, label: track.label, codec: track.codec)
    }

    static func subtitle(_ track: MediaTrackInfo?) -> TrackPreference.Subtitle {
        guard let track else { return .off }
        return .track(language: track.language, isForced: track.isForced, label: track.label)
    }

    /// Only an AUDIBLE track ever matches (`AudioTrackPolicy`): a TrueHD track
    /// picked by hand plays silent on Apple, and remembering it must not open
    /// every following episode silent — the same language in an audible codec
    /// is taken instead, else the server's default. Among the candidates of
    /// the same language, the same label wins, then the same codec.
    static func audioOrdinal(for wanted: TrackPreference.Audio, in tracks: [MediaTrackInfo]) -> Int? {
        let language = AudioTrackPolicy.normalized(wanted.language)
        let candidates = tracks.indices.filter { index in
            let track = tracks[index]
            guard AudioTrackPolicy.isAudible(track) else { return false }
            if let language { return AudioTrackPolicy.normalized(track.language) == language }
            return track.label == wanted.label
        }
        return candidates.first(where: { tracks[$0].label == wanted.label })
            ?? candidates.first(where: { wanted.codec != nil && tracks[$0].codec == wanted.codec })
            ?? candidates.first
    }

    enum SubtitleChoice: Equatable {
        case off
        case ordinal(Int)
    }

    /// Forced and full subtitles never stand in for each other: « forced »
    /// translates only the foreign lines, so swapping one for the other would
    /// either flood the screen or leave whole scenes untranslated.
    static func subtitleChoice(for wanted: TrackPreference.Subtitle, in tracks: [MediaTrackInfo]) -> SubtitleChoice? {
        switch wanted {
        case .off:
            return .off
        case .track(let rawLanguage, let isForced, let label):
            let language = AudioTrackPolicy.normalized(rawLanguage)
            let candidates = tracks.indices.filter { index in
                let track = tracks[index]
                guard track.isForced == isForced else { return false }
                if let language { return AudioTrackPolicy.normalized(track.language) == language }
                return track.label == label
            }
            guard let ordinal = candidates.first(where: { tracks[$0].label == label }) ?? candidates.first else {
                return nil
            }
            return .ordinal(ordinal)
        }
    }
}

/// The device's copy (`player.trackPreferences` in `UserDefaults`), read at
/// every opening so the player never waits on the network: every title's
/// choice keyed by account AND title (the series id for an episode, the item
/// id for a film) — a shared Apple TV holds several accounts. The account's
/// copy on the server (`TrackPreferenceSync`) is merged into it before each
/// playback and receives every pick. Bounded per account: past `limit`
/// titles the oldest choice goes.
struct TrackPreferenceStore {
    static let key = "player.trackPreferences"
    static let limit = 500

    let defaults: UserDefaults

    func preference(userId: String, titleId: String) -> TrackPreference? {
        all()[Self.entryKey(userId: userId, titleId: titleId)]
    }

    /// Every title of one account, keyed by title id.
    func entries(userId: String) -> [String: TrackPreference] {
        let prefix = userId + "/"
        var result: [String: TrackPreference] = [:]
        for (key, value) in all() where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = value
        }
        return result
    }

    func recordAudio(_ audio: TrackPreference.Audio, userId: String, titleId: String, now: Date = .now) {
        update(userId: userId, titleId: titleId, now: now) { $0.audio = audio }
    }

    func recordSubtitle(_ subtitle: TrackPreference.Subtitle, userId: String, titleId: String, now: Date = .now) {
        update(userId: userId, titleId: titleId, now: now) { $0.subtitle = subtitle }
    }

    /// Takes in the account's copy from the server: per title, the newer
    /// choice wins (`TrackPreferenceSync.merged`).
    func absorb(_ remote: [String: TrackPreference], userId: String) {
        let merged = TrackPreferenceSync.merged(entries(userId: userId), remote, limit: Self.limit)
        guard merged != entries(userId: userId) else { return }
        var all = all().filter { !$0.key.hasPrefix(userId + "/") }
        for (titleId, value) in merged { all[Self.entryKey(userId: userId, titleId: titleId)] = value }
        save(all)
    }

    private func update(
        userId: String, titleId: String, now: Date, _ change: (inout TrackPreference) -> Void
    ) {
        var entries = all()
        let key = Self.entryKey(userId: userId, titleId: titleId)
        var entry = entries[key] ?? TrackPreference(audio: nil, subtitle: nil, updatedAt: now)
        change(&entry)
        entry.updatedAt = now
        entries[key] = entry
        let prefix = userId + "/"
        let mine = entries.filter { $0.key.hasPrefix(prefix) }
        if mine.count > Self.limit {
            let oldest = mine.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(mine.count - Self.limit)
            for (stale, _) in oldest { entries[stale] = nil }
        }
        save(entries)
    }

    private func save(_ entries: [String: TrackPreference]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private func all() -> [String: TrackPreference] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([String: TrackPreference].self, from: data)
        else { return [:] }
        return entries
    }

    private static func entryKey(userId: String, titleId: String) -> String { "\(userId)/\(titleId)" }
}

/// The account's copy of the choices, so the iPhone, the iPad and the Apple TV
/// signed in to one account share them: the DisplayPreferences entity
/// `jellyglass-tracks` (client `jellyglass`), one JSON value
/// `[titleId: TrackPreference]` under `titles`. Its own entity, like
/// `NextUpHiddenList`'s: a write replaces the whole entity.
///
/// Never on the path of a frame: the player reads the device's copy.
/// `pull` runs beside the stream negotiation (bounded by `pullTimeout`) and
/// merges the account's copy in; `push` follows every pick. Both merge per
/// title, newer wins, so two devices writing close together keep both
/// titles — a same-title race keeps the later pick. A failed read or write
/// changes nothing: the device's copy plays on, and the next push carries it.
@MainActor
enum TrackPreferenceSync {
    nonisolated static let preferencesId = "jellyglass-tracks"
    nonisolated static let client = "jellyglass"
    nonisolated static let preferenceKey = "titles"
    nonisolated static let pullTimeout: Duration = .seconds(2)

    /// Pushes queued behind one another: each is a read-modify-write.
    private static var pushTail: Task<Void, Never>?

    /// Merges the account's copy into the device's; gives up after
    /// `pullTimeout` (the device's copy then decides this opening).
    static func pull(api: any UserPreferencesAPI, userId: String, store: TrackPreferenceStore) async {
        let remote = await withTaskGroup(of: [String: TrackPreference]?.self) { group in
            group.addTask {
                guard let dto = try? await api.getDisplayPreferences(
                    id: preferencesId, client: client, userId: userId
                ) else { return nil }
                return decode(dto.customPrefs?[preferenceKey])
            }
            group.addTask {
                try? await Task.sleep(for: pullTimeout)
                return nil
            }
            let first = (await group.next()).flatMap { $0 }
            group.cancelAll()
            return first
        }
        if let remote { store.absorb(remote, userId: userId) }
    }

    /// Writes the device's copy of this account into the account's, after
    /// reading it back (another device may have written since).
    static func push(api: any UserPreferencesAPI, userId: String, store: TrackPreferenceStore) {
        let previous = pushTail
        pushTail = Task { @MainActor in
            await previous?.value
            guard let dto = try? await api.getDisplayPreferences(
                id: preferencesId, client: client, userId: userId
            ) else { return }
            let remote = decode(dto.customPrefs?[preferenceKey])
            let merged = merged(store.entries(userId: userId), remote, limit: TrackPreferenceStore.limit)
            store.absorb(merged, userId: userId)
            guard merged != remote, let value = encode(merged) else { return }
            var next = dto
            var prefs = next.customPrefs ?? [:]
            prefs[preferenceKey] = value
            next.customPrefs = prefs
            next.id = preferencesId
            next.client = client
            try? await api.updateDisplayPreferences(next, id: preferencesId, client: client, userId: userId)
        }
    }

    /// Per title, the newer `updatedAt` wins; past `limit` the oldest go.
    nonisolated static func merged(
        _ local: [String: TrackPreference], _ remote: [String: TrackPreference], limit: Int
    ) -> [String: TrackPreference] {
        var result = remote
        for (titleId, mine) in local where (result[titleId]?.updatedAt ?? .distantPast) < mine.updatedAt {
            result[titleId] = mine
        }
        guard result.count > limit else { return result }
        let kept = result.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// Anything unreadable is an empty copy, never an error.
    nonisolated static func decode(_ value: String?) -> [String: TrackPreference] {
        guard let data = value?.data(using: .utf8),
              let entries = try? JSONDecoder().decode([String: TrackPreference].self, from: data)
        else { return [:] }
        return entries
    }

    nonisolated static func encode(_ entries: [String: TrackPreference]) -> String? {
        guard let data = try? JSONEncoder().encode(entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
