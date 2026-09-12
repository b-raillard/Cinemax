import Testing
import CinemaxKit
@testable import Cinemax

/// A file whose default audio track is Dolby TrueHD opens **silent** on the VLC
/// engine — Apple exposes no TrueHD passthrough and libVLC's S/PDIF
/// encapsulator covers only A/52 and DTS. Applying the server's default
/// verbatim therefore meant picking the one unplayable track on a source that
/// carried a working one, with no error anywhere to explain the silence.
@Suite("AudioTrackPolicy.defaultOrdinal")
struct AudioTrackPolicyTests {

    private func track(
        _ id: Int,
        codec: String? = "ac3",
        language: String? = "eng",
        isDefault: Bool = false
    ) -> MediaTrackInfo {
        MediaTrackInfo(
            id: id,
            label: "Track \(id)",
            isDefault: isDefault,
            isForced: false,
            codec: codec,
            language: language
        )
    }

    @Test("an ordinary default is applied untouched")
    func ordinaryDefaultPassesThrough() {
        let tracks = [track(1, language: "fre"), track(2, isDefault: true)]
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: 2) == 1)
    }

    /// The measured case: « Hunger Games : La Révolte - partie 2 ».
    @Test("a TrueHD default is replaced by the audible alternative")
    func trueHDDefaultIsReplaced() {
        let tracks = [
            track(1, codec: "dts", language: "fre"),
            track(2, codec: "truehd", language: "eng", isDefault: true),
        ]
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: 2) == 0)
    }

    @Test("mlp — TrueHD's own core codec name — is refused too")
    func mlpIsRefused() {
        let tracks = [track(1, codec: "mlp", language: "eng", isDefault: true), track(2, codec: "eac3", language: "eng")]
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: 1) == 1)
    }

    @Test("the codec test is case- and whitespace-insensitive")
    func codecMatchingIsLenient() {
        let tracks = [track(1, codec: " TrueHD ", language: "eng", isDefault: true), track(2, codec: "ac3", language: "eng")]
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: 1) == 1)
    }

    @Test("the replacement keeps the language when an audible track shares it")
    func languageIsPreserved() {
        // Dropping to "first audible" here would switch the user to French as a
        // side effect of a codec problem.
        let tracks = [
            track(1, codec: "ac3", language: "fre"),
            track(2, codec: "truehd", language: "eng", isDefault: true),
            track(3, codec: "ac3", language: "eng"),
        ]
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: 2) == 2)
    }

    @Test("regional variants count as the same language")
    func regionalVariantsMatch() {
        let tracks = [
            track(1, codec: "ac3", language: "fre"),
            track(2, codec: "truehd", language: "EN-GB", isDefault: true),
            track(3, codec: "ac3", language: "en"),
        ]
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: 2) == 2)
    }

    @Test("a source with only silent tracks keeps the server's choice")
    func allSilentKeepsServerPick() {
        // Nothing better to offer — diverging would only make this client
        // disagree with every other one for no gain.
        let tracks = [track(1, codec: "truehd", language: "eng"), track(2, codec: "truehd", language: "fre", isDefault: true)]
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: 2) == 1)
    }

    @Test("an unknown or absent codec is treated as audible, never refused")
    func unknownCodecIsTrusted() {
        #expect(AudioTrackPolicy.isAudible(track(1, codec: nil)))
        #expect(AudioTrackPolicy.isAudible(track(1, codec: "")))
        #expect(AudioTrackPolicy.isAudible(track(1, codec: "some-future-codec")))
    }

    @Test("DTS-HD, EAC3 and AC3 are never refused")
    func lossyAndDTSStayAudible() {
        for codec in ["dts", "dtshd", "eac3", "ac3", "aac", "flac", "opus"] {
            #expect(AudioTrackPolicy.isAudible(track(1, codec: codec)), "\(codec) must stay selectable")
        }
    }

    @Test("no server default, or one this source doesn't carry, leaves the engine alone")
    func absentDefaultIsANoOp() {
        let tracks = [track(1), track(2)]
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: nil) == nil)
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: 99) == nil)
        #expect(AudioTrackPolicy.defaultOrdinal(tracks: [], serverDefaultId: 1) == nil)
    }
}

/// A TrueHD track picked BY HAND is still silent — Apple exposes no TrueHD
/// route — so both pickers tag it and the player explains the choice with the
/// audible alternative. The pick is never refused: sources can be mis-tagged.
@Suite("AudioTrackPolicy.manualPickVerdict")
struct AudioTrackManualPickTests {

    private func track(_ id: Int, codec: String? = "ac3", language: String? = "eng") -> MediaTrackInfo {
        MediaTrackInfo(id: id, label: "Track \(id)", isDefault: false, isForced: false, codec: codec, language: language)
    }

    @Test("an audible pick needs no explanation")
    func audiblePickIsSilentlyAccepted() {
        let tracks = [track(1, codec: "dts", language: "fre"), track(2, codec: "truehd", language: "eng")]
        #expect(AudioTrackPolicy.manualPickVerdict(ordinal: 0, tracks: tracks) == .audible)
        #expect(!AudioTrackPolicy.isSilent(ordinal: 0, in: tracks))
    }

    /// The acceptance case: « Hunger Games : La Révolte - partie 2 ».
    @Test("English TrueHD points at the French DTS-HD, the only audible track")
    func measuredCaseSuggestsTheAudibleTrack() {
        let tracks = [track(1, codec: "dts", language: "fre"), track(2, codec: "truehd", language: "eng")]
        #expect(AudioTrackPolicy.isSilent(ordinal: 1, in: tracks))
        #expect(AudioTrackPolicy.manualPickVerdict(ordinal: 1, tracks: tracks) == .silent(suggestedOrdinal: 0))
    }

    @Test("the suggestion keeps the language when an audible track shares it")
    func suggestionKeepsTheLanguage() {
        let tracks = [
            track(1, codec: "ac3", language: "fre"),
            track(2, codec: "truehd", language: "eng"),
            track(3, codec: "eac3", language: "eng"),
        ]
        #expect(AudioTrackPolicy.manualPickVerdict(ordinal: 1, tracks: tracks) == .silent(suggestedOrdinal: 2))
    }

    @Test("mlp is flagged too, whatever its case or padding")
    func mlpIsFlagged() {
        let tracks = [track(1, codec: " MLP ", language: "eng"), track(2, codec: "eac3", language: "eng")]
        #expect(AudioTrackPolicy.manualPickVerdict(ordinal: 0, tracks: tracks) == .silent(suggestedOrdinal: 1))
    }

    @Test("a source with no audible track flags the pick without a suggestion")
    func allSilentHasNoSuggestion() {
        let tracks = [track(1, codec: "truehd", language: "eng"), track(2, codec: "mlp", language: "fre")]
        #expect(AudioTrackPolicy.manualPickVerdict(ordinal: 0, tracks: tracks) == .silent(suggestedOrdinal: nil))
    }

    @Test("a track the server did not describe is never flagged")
    func undescribedOrdinalIsNotSilent() {
        let tracks = [track(1, codec: "truehd")]
        #expect(!AudioTrackPolicy.isSilent(ordinal: 3, in: tracks))
        #expect(!AudioTrackPolicy.isSilent(ordinal: -1, in: tracks))
        #expect(AudioTrackPolicy.manualPickVerdict(ordinal: 3, tracks: tracks) == .audible)
    }

    @Test("DTS-HD, EAC3 and AC3 picks are never flagged")
    func decodableCodecsAreNeverFlagged() {
        for codec in ["dts", "dtshd", "eac3", "ac3", "aac", "flac", nil] {
            let tracks = [track(1, codec: codec)]
            #expect(AudioTrackPolicy.manualPickVerdict(ordinal: 0, tracks: tracks) == .audible,
                    "\(codec ?? "nil") must not be tagged silent")
        }
    }

    @Test("the manual suggestion and the automatic default name the same track")
    func suggestionMatchesTheAutomaticDefault() {
        let fixtures: [[MediaTrackInfo]] = [
            [track(1, codec: "dts", language: "fre"), track(2, codec: "truehd", language: "eng")],
            [track(1, codec: "ac3", language: "fre"), track(2, codec: "truehd", language: "eng"), track(3, codec: "ac3", language: "eng")],
            [track(1, codec: "truehd", language: "eng"), track(2, codec: "aac", language: "ger"), track(3, codec: "ac3", language: "fre")],
        ]
        for tracks in fixtures {
            let silentOrdinal = tracks.firstIndex { !AudioTrackPolicy.isAudible($0) }!
            let automatic = AudioTrackPolicy.defaultOrdinal(tracks: tracks, serverDefaultId: tracks[silentOrdinal].id)
            #expect(AudioTrackPolicy.manualPickVerdict(ordinal: silentOrdinal, tracks: tracks) == .silent(suggestedOrdinal: automatic))
        }
    }
}
