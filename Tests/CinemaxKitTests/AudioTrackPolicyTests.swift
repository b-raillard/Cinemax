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
