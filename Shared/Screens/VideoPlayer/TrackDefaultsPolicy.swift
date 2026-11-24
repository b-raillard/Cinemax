import Foundation
import CinemaxKit

/// A language code reduced to one comparable key: the two-letter ISO 639-1
/// code. The app's language and the Profile speak `fr`; Jellyfin's tracks
/// speak ISO 639-2 in either form (`fra` / `fre`, `deu` / `ger`), sometimes
/// with a region (`fr-FR`). `und`, `mul`… and nothing at all are « unknown ».
enum LanguageKey {
    private static let undefined: Set<String> = ["und", "unknown", "undetermined", "mul", "zxx", "mis"]
    /// ISO 639-2/B codes Foundation reads only in their /T form, plus a few
    /// codes servers emit that it does not reduce (`nob`, `pob`).
    private static let bibliographic: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl",
        "fre": "fr", "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi",
        "may": "ms", "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
        "nob": "nb", "nno": "nn", "nor": "no", "pob": "pt"
    ]

    static func of(_ code: String?) -> String? {
        guard let first = code?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first else {
            return nil
        }
        let raw = first.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !undefined.contains(raw) else { return nil }
        if raw.count == 2 { return raw }
        if let mapped = bibliographic[raw] { return mapped }
        if let alpha2 = Locale.LanguageCode(raw).identifier(.alpha2) { return alpha2 }
        return raw
    }
}

/// The tracks a media opens on when nothing restores them (owner, 2026-11-24),
/// first match wins, each half on its own:
///
/// **Audio** — 1 the choice remembered for this title; 2 the account's audio
/// language (Profile); 3 the app's language; 4 the file's default track; 5 the
/// first audible track. Only AUDIBLE tracks ever match (`AudioTrackPolicy`:
/// TrueHD plays silent on Apple), a default that is silent gives way to an
/// audible one of its language, and a source with nothing audible keeps the
/// server's pick. Among several tracks of the language, the default-flagged one.
///
/// **Subtitles** — 1 the remembered choice; 2 the account's subtitle language
/// and mode, when either is set (mode « par défaut » with no language is « no
/// preference »); 3 the app's language, read « intelligent »: full subtitles
/// when the audio is in another language, forced ones when it is the same;
/// 4 forced subtitles in the audio's language, else forced ones the file
/// flags default; 5 none. Steps 2–5 read the audio track THIS policy chose.
///
/// Unknown account preferences (`account == nil`: the user not loaded yet)
/// skip 2–5 and keep the server's picks — never read « unknown » as « no
/// preference ». External subtitles are never candidates: libVLC does not
/// load them, so they have no ordinal.
enum TrackDefaultsPolicy {
    enum Reason: String, Equatable {
        case title = "choix gardé pour ce titre"
        case account = "préférence du compte"
        case interface = "langue de l'app"
        case fileDefault = "piste par défaut du fichier"
        case firstAudible = "première piste audible"
        case server = "choix du serveur"
        case none = "aucun"
    }

    struct Decision: Equatable {
        var audio: Int?
        var audioReason: Reason
        var subtitle: TrackPreferencePolicy.SubtitleChoice
        var subtitleReason: Reason
    }

    /// Everything the decision reads. `account` nil = not known yet.
    struct Inputs {
        var audioTracks: [MediaTrackInfo]
        var subtitleTracks: [MediaTrackInfo]
        var remembered: TrackPreference?
        var account: UserPlaybackPreferences?
        var interfaceLanguage: String
        var serverAudioId: Int?
        var serverSubtitleId: Int?
    }

    static func decide(_ input: Inputs) -> Decision {
        let (audio, audioReason) = audioChoice(input)
        let tracks = input.audioTracks
        let audioKey = audio.flatMap { tracks.indices.contains($0) ? LanguageKey.of(tracks[$0].language) : nil }
        let (subtitle, subtitleReason) = subtitleChoice(input, audioKey: audioKey)
        return Decision(audio: audio, audioReason: audioReason, subtitle: subtitle, subtitleReason: subtitleReason)
    }

    // MARK: Audio

    private static func audioChoice(_ input: Inputs) -> (Int?, Reason) {
        let tracks = input.audioTracks
        let interface = input.interfaceLanguage
        if let remembered = input.remembered?.audio, let ordinal = TrackPreferencePolicy.audioOrdinal(for: remembered, in: tracks) {
            return (ordinal, .title)
        }
        let serverPick = AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: input.serverAudioId)
        guard let account = input.account else { return (serverPick, .server) }
        if let key = LanguageKey.of(account.audioLanguage), let ordinal = audible(in: tracks, language: key) {
            return (ordinal, .account)
        }
        if let key = LanguageKey.of(interface), let ordinal = audible(in: tracks, language: key) {
            return (ordinal, .interface)
        }
        if let flagged = tracks.firstIndex(where: \.isDefault) {
            if AudioTrackPolicy.isAudible(tracks[flagged]) { return (flagged, .fileDefault) }
            if let replacement = AudioTrackPolicy.audibleReplacementOrdinal(for: flagged, in: tracks) {
                return (replacement, .fileDefault)
            }
        }
        if let first = tracks.firstIndex(where: AudioTrackPolicy.isAudible) { return (first, .firstAudible) }
        return (serverPick, .server)
    }

    private static func audible(in tracks: [MediaTrackInfo], language: String) -> Int? {
        let matches = tracks.indices.filter {
            AudioTrackPolicy.isAudible(tracks[$0]) && LanguageKey.of(tracks[$0].language) == language
        }
        return matches.first(where: { tracks[$0].isDefault }) ?? matches.first
    }

    // MARK: Subtitles

    private static func subtitleChoice(
        _ input: Inputs, audioKey: String?
    ) -> (TrackPreferencePolicy.SubtitleChoice, Reason) {
        let tracks = input.subtitleTracks
        if let remembered = input.remembered?.subtitle, let choice = TrackPreferencePolicy.subtitleChoice(for: remembered, in: tracks) {
            return (choice, .title)
        }
        guard let account = input.account else {
            if let serverSubtitleId = input.serverSubtitleId, serverSubtitleId >= 0,
               let ordinal = tracks.firstIndex(where: { $0.id == serverSubtitleId }) {
                return (.ordinal(ordinal), .server)
            }
            return (.off, .server)
        }
        let interfaceKey = LanguageKey.of(input.interfaceLanguage)
        let accountKey = LanguageKey.of(account.subtitleLanguage)
        if accountKey != nil || account.subtitleMode != .defaultTrack,
           let choice = accountDecision(tracks, mode: account.subtitleMode, language: accountKey ?? interfaceKey, audioKey: audioKey) {
            return (choice, .account)
        }
        if let interfaceKey, let choice = smart(tracks, language: interfaceKey, audioKey: audioKey) {
            return (choice, .interface)
        }
        if let audioKey, let forced = pick(tracks, language: audioKey, forced: true) {
            return (.ordinal(forced), .fileDefault)
        }
        if let flagged = tracks.firstIndex(where: { $0.isForced && $0.isDefault }) {
            return (.ordinal(flagged), .fileDefault)
        }
        return (.off, .none)
    }

    /// The account's mode, Jellyfin's reading of it. `nil` = this step has no
    /// match (the next one decides); `.off` = it decided « none ».
    private static func accountDecision(
        _ tracks: [MediaTrackInfo], mode: UserPlaybackPreferences.SubtitleMode, language: String?, audioKey: String?
    ) -> TrackPreferencePolicy.SubtitleChoice? {
        switch mode {
        case .none:
            return .off
        case .defaultTrack:
            let flagged = tracks.indices.filter { tracks[$0].isDefault || tracks[$0].isForced }
            let ordinal = flagged.first(where: { language != nil && LanguageKey.of(tracks[$0].language) == language })
                ?? flagged.first
            return ordinal.map(TrackPreferencePolicy.SubtitleChoice.ordinal) ?? .off
        case .onlyForced:
            return pick(tracks, language: language, forced: true).map(TrackPreferencePolicy.SubtitleChoice.ordinal) ?? .off
        case .always:
            return (pick(tracks, language: language, forced: false) ?? pick(tracks, language: language, forced: true))
                .map(TrackPreferencePolicy.SubtitleChoice.ordinal)
        case .smart:
            guard let language else { return nil }
            return smart(tracks, language: language, audioKey: audioKey)
        }
    }

    /// « Intelligent »: full subtitles in `language` when the audio speaks
    /// another one; forced ones (or none) when it speaks that one — or when
    /// its language is unknown, the cautious reading.
    private static func smart(
        _ tracks: [MediaTrackInfo], language: String, audioKey: String?
    ) -> TrackPreferencePolicy.SubtitleChoice? {
        if audioKey == nil || audioKey == language {
            return pick(tracks, language: language, forced: true).map(TrackPreferencePolicy.SubtitleChoice.ordinal) ?? .off
        }
        return (pick(tracks, language: language, forced: false) ?? pick(tracks, language: language, forced: true))
            .map(TrackPreferencePolicy.SubtitleChoice.ordinal)
    }

    /// A subtitle of `language` (any language when nil) that is, or is not,
    /// forced — the default-flagged one first.
    private static func pick(_ tracks: [MediaTrackInfo], language: String?, forced: Bool) -> Int? {
        let matches = tracks.indices.filter {
            tracks[$0].isForced == forced && (language == nil || LanguageKey.of(tracks[$0].language) == language)
        }
        return matches.first(where: { tracks[$0].isDefault }) ?? matches.first
    }
}
