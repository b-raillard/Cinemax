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

/// One `UserDefaults` entry (`player.trackPreferences`) holding every
/// title's choice, keyed by account AND title (the series id for an episode,
/// the item id for a film) — a shared Apple TV holds several accounts.
/// Bounded: past `limit` titles the oldest choice goes.
struct TrackPreferenceStore {
    static let key = "player.trackPreferences"
    static let limit = 200

    let defaults: UserDefaults

    func preference(userId: String, titleId: String) -> TrackPreference? {
        all()[Self.entryKey(userId: userId, titleId: titleId)]
    }

    func recordAudio(_ audio: TrackPreference.Audio, userId: String, titleId: String, now: Date = .now) {
        update(userId: userId, titleId: titleId, now: now) { $0.audio = audio }
    }

    func recordSubtitle(_ subtitle: TrackPreference.Subtitle, userId: String, titleId: String, now: Date = .now) {
        update(userId: userId, titleId: titleId, now: now) { $0.subtitle = subtitle }
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
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(entries.count - Self.limit)
            for (stale, _) in oldest { entries[stale] = nil }
        }
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
