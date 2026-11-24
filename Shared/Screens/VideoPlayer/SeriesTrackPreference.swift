import Foundation
import CinemaxKit

/// The audio and subtitle tracks the viewer picked BY HAND in an episode of a
/// series, re-applied to every later episode of it (owner, 2026-11-24: « on ne
/// conserve pas le réglage sous-titre et audio qu'on a choisi à un épisode »).
///
/// What is kept is a DESCRIPTION of the track — language, forced or not, its
/// label as a tie-break — never a stream index or an ordinal: the next
/// episode's file can carry its tracks in another order. The two halves are
/// independent, so turning subtitles on leaves the audio to the server.
struct SeriesTrackPreference: Codable, Equatable, Sendable {
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
enum SeriesTrackPolicy {
    static func audio(_ track: MediaTrackInfo) -> SeriesTrackPreference.Audio {
        .init(language: track.language, label: track.label, codec: track.codec)
    }

    static func subtitle(_ track: MediaTrackInfo?) -> SeriesTrackPreference.Subtitle {
        guard let track else { return .off }
        return .track(language: track.language, isForced: track.isForced, label: track.label)
    }

    /// Only an AUDIBLE track ever matches (`AudioTrackPolicy`): a TrueHD track
    /// picked by hand plays silent on Apple, and remembering it must not open
    /// every following episode silent — the same language in an audible codec
    /// is taken instead, else the server's default. Among the candidates of
    /// the same language, the same label wins, then the same codec.
    static func audioOrdinal(for wanted: SeriesTrackPreference.Audio, in tracks: [MediaTrackInfo]) -> Int? {
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
    static func subtitleChoice(for wanted: SeriesTrackPreference.Subtitle, in tracks: [MediaTrackInfo]) -> SubtitleChoice? {
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

/// One `UserDefaults` entry (`player.seriesTrackPreferences`) holding every
/// series' choice, keyed by account AND series — a shared Apple TV holds
/// several accounts. Bounded: past `limit` series the oldest choice goes.
struct SeriesTrackPreferenceStore {
    static let key = "player.seriesTrackPreferences"
    static let limit = 200

    let defaults: UserDefaults

    func preference(userId: String, seriesId: String) -> SeriesTrackPreference? {
        all()[Self.entryKey(userId: userId, seriesId: seriesId)]
    }

    func recordAudio(_ audio: SeriesTrackPreference.Audio, userId: String, seriesId: String, now: Date = .now) {
        update(userId: userId, seriesId: seriesId, now: now) { $0.audio = audio }
    }

    func recordSubtitle(_ subtitle: SeriesTrackPreference.Subtitle, userId: String, seriesId: String, now: Date = .now) {
        update(userId: userId, seriesId: seriesId, now: now) { $0.subtitle = subtitle }
    }

    private func update(
        userId: String, seriesId: String, now: Date, _ change: (inout SeriesTrackPreference) -> Void
    ) {
        var entries = all()
        let key = Self.entryKey(userId: userId, seriesId: seriesId)
        var entry = entries[key] ?? SeriesTrackPreference(audio: nil, subtitle: nil, updatedAt: now)
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

    private func all() -> [String: SeriesTrackPreference] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([String: SeriesTrackPreference].self, from: data)
        else { return [:] }
        return entries
    }

    private static func entryKey(userId: String, seriesId: String) -> String { "\(userId)/\(seriesId)" }
}
