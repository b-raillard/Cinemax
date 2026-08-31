import Foundation
import CinemaxKit

/// Which audio track the VLC engine should open a media on.
///
/// Jellyfin hands us a default (`MediaSourceInfo.defaultAudioStreamIndex`),
/// derived from the file's own `IsDefault` flag and the account's audio-language
/// preference, and `VLCStreamPresenter` used to apply it verbatim. That is right
/// for every codec but one: **libVLC on Apple cannot output Dolby TrueHD**, so a
/// file whose default track is TrueHD opens silent — picture, HUD and playhead
/// all normal, no error anywhere.
///
/// Measured on the simulator 2026-08-31, « Hunger Games : La Révolte - partie 2 »
/// (the exact media source the report came from):
///
///     want=2
///     jellyfin: [0] id=1 « TrueFrench DTS-HD Master 7.1 »
///               [1] id=2 « English Dolby-TrueHD Atmos 7.1 » — Par défaut
///     selected ordinal=1 « English Dolby-TrueHD Atmos 7.1 »
///
/// — i.e. the app faithfully picked the one track that cannot be heard, while a
/// working DTS-HD track sat next to it. Apple exposes no TrueHD passthrough
/// route and libVLC's S/PDIF encapsulator only covers A/52 and DTS, so this is a
/// platform limit, not a decoding bug to fix elsewhere.
///
/// Pure and unit-tested (`AudioTrackPolicyTests`), like `SeekCoalescer` and
/// `PlaybackEndPolicy` — the presenter keeps ownership of the engine call.
enum AudioTrackPolicy {

    /// Codecs that reach the user as silence on this engine + platform pair.
    /// `mlp` is TrueHD's own core codec name, which some muxes report instead.
    ///
    /// Deliberately **not** a general "codecs we dislike" list: every entry here
    /// must be one that cannot produce sound at all. DTS-HD, EAC3 and AC3 all
    /// decode fine and must never be added.
    static let silentCodecs: Set<String> = ["truehd", "mlp"]

    /// A track we have no reason to believe is silent. An unknown or absent
    /// codec counts as audible: the server not reporting one is not evidence of
    /// a problem, and refusing on that basis would break ordinary files.
    static func isAudible(_ track: MediaTrackInfo) -> Bool {
        guard let codec = track.codec?.trimmingCharacters(in: .whitespaces).lowercased(),
              !codec.isEmpty else { return true }
        return !silentCodecs.contains(codec)
    }

    /// The ordinal-within-type to hand the engine, or `nil` to leave the
    /// engine's own pick alone (the server named no default, or named one this
    /// media source doesn't contain — both were already no-ops before).
    ///
    /// When the server's default is silent, the replacement **keeps the
    /// language** where it can: on an English-TrueHD + English-AC3 + French-AC3
    /// file, dropping to "the first audible track" would switch the user's
    /// language as a side effect of a codec problem. Only when no audible track
    /// shares the language does it fall through to the first audible one — which
    /// is the case in the report above, where French DTS-HD is the only
    /// alternative and is exactly what the user wanted.
    ///
    /// A source whose tracks are *all* silent keeps the server's choice: there
    /// is nothing better to offer, and second-guessing it would only make the
    /// selection differ from what every other client shows.
    static func defaultOrdinal(tracks: [MediaTrackInfo], serverDefaultId: Int?) -> Int? {
        guard let serverDefaultId,
              let serverOrdinal = tracks.firstIndex(where: { $0.id == serverDefaultId })
        else { return nil }

        if isAudible(tracks[serverOrdinal]) { return serverOrdinal }

        if let wanted = normalized(tracks[serverOrdinal].language),
           let sameLanguage = tracks.indices.first(where: {
               isAudible(tracks[$0]) && normalized(tracks[$0].language) == wanted
           }) {
            return sameLanguage
        }

        return tracks.indices.first(where: { isAudible(tracks[$0]) }) ?? serverOrdinal
    }

    /// Primary subtag, lowercased — servers report `fre`, `fr`, `fr-FR` for the
    /// same thing. Same normalization as `RemoteImageCatalog`.
    private static func normalized(_ code: String?) -> String? {
        guard let code else { return nil }
        let primary = code.split(separator: "-").first.map(String.init) ?? code
        let trimmed = primary.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
