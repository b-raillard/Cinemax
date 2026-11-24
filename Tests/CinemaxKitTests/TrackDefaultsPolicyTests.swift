import Foundation
import Testing
import CinemaxKit
@testable import Cinemax

/// The tracks a media opens on: remembered choice, account languages, app
/// language, file default, first audible — audio and subtitles each their own.
@Suite("TrackDefaultsPolicy")
struct TrackDefaultsPolicyTests {

    private func audio(_ id: Int, _ language: String?, codec: String = "ac3", isDefault: Bool = false) -> MediaTrackInfo {
        MediaTrackInfo(id: id, label: "A\(id)", isDefault: isDefault, isForced: false, codec: codec, language: language)
    }

    private func sub(_ id: Int, _ language: String?, forced: Bool = false, isDefault: Bool = false) -> MediaTrackInfo {
        MediaTrackInfo(id: id, label: "S\(id)", isDefault: isDefault, isForced: forced, codec: "subrip", language: language)
    }

    private func decide(
        audio: [MediaTrackInfo], subs: [MediaTrackInfo] = [], remembered: TrackPreference? = nil,
        account: UserPlaybackPreferences? = UserPlaybackPreferences(), interface: String = "fr",
        serverAudio: Int? = nil, serverSub: Int? = nil
    ) -> TrackDefaultsPolicy.Decision {
        TrackDefaultsPolicy.decide(.init(
            audioTracks: audio, subtitleTracks: subs, remembered: remembered, account: account,
            interfaceLanguage: interface, serverAudioId: serverAudio, serverSubtitleId: serverSub
        ))
    }

    @Test("language codes compare whatever their form")
    func languageKeys() {
        #expect(LanguageKey.of("fr") == "fr")
        #expect(LanguageKey.of("fra") == "fr")
        #expect(LanguageKey.of("fre") == "fr")
        #expect(LanguageKey.of("fr-FR") == "fr")
        #expect(LanguageKey.of("FRA") == "fr")
        #expect(LanguageKey.of("deu") == "de")
        #expect(LanguageKey.of("ger") == "de")
        #expect(LanguageKey.of("eng") == "en")
        #expect(LanguageKey.of("jpn") == "ja")
        #expect(LanguageKey.of("und") == nil)
        #expect(LanguageKey.of("") == nil)
        #expect(LanguageKey.of(nil) == nil)
    }

    // MARK: Audio

    @Test("account preferences unknown: the server's picks stand")
    func unknownAccountKeepsServer() {
        let tracks = [audio(1, "fra", isDefault: true), audio(2, "eng")]
        let subs = [sub(3, "fra"), sub(4, "eng")]
        let decision = decide(audio: tracks, subs: subs, account: nil, serverAudio: 2, serverSub: 4)
        #expect(decision.audio == 1 && decision.audioReason == .server)
        #expect(decision.subtitle == .ordinal(1) && decision.subtitleReason == .server)
    }

    @Test("the remembered choice comes first")
    func rememberedFirst() {
        let remembered = TrackPreference(audio: .init(language: "jpn", label: "x", codec: nil), subtitle: nil, updatedAt: .now)
        let decision = decide(audio: [audio(1, "fra", isDefault: true), audio(2, "jpn")], remembered: remembered,
                              account: UserPlaybackPreferences(audioLanguage: "fr"))
        #expect(decision.audio == 1 && decision.audioReason == .title)
    }

    @Test("the account's language beats the file's default")
    func accountBeatsDefault() {
        let decision = decide(audio: [audio(1, "fra", isDefault: true), audio(2, "eng")],
                              account: UserPlaybackPreferences(audioLanguage: "en"))
        #expect(decision.audio == 1 && decision.audioReason == .account)
    }

    @Test("no account language: the app's language beats the file's default")
    func interfaceBeatsDefault() {
        let decision = decide(audio: [audio(1, "eng", isDefault: true), audio(2, "fre")], interface: "fr")
        #expect(decision.audio == 1 && decision.audioReason == .interface)
    }

    @Test("a language missing from the file falls to the next step")
    func missingLanguageFallsThrough() {
        let decision = decide(audio: [audio(1, "spa"), audio(2, "jpn", isDefault: true)],
                              account: UserPlaybackPreferences(audioLanguage: "de"), interface: "fr")
        #expect(decision.audio == 1 && decision.audioReason == .fileDefault)
    }

    @Test("a silent default gives way to an audible track of its language")
    func silentDefaultKeepsLanguage() {
        let tracks = [audio(1, "spa"), audio(2, "jpn", codec: "truehd", isDefault: true), audio(3, "jpn", codec: "eac3")]
        let decision = decide(audio: tracks, interface: "fr")
        #expect(decision.audio == 2 && decision.audioReason == .fileDefault)
    }

    @Test("no match and no default: the first audible track")
    func firstAudible() {
        let decision = decide(audio: [audio(1, "spa", codec: "truehd"), audio(2, "jpn")], interface: "fr")
        #expect(decision.audio == 1 && decision.audioReason == .firstAudible)
    }

    @Test("a matching language is never taken silent")
    func silentMatchIsSkipped() {
        let decision = decide(audio: [audio(1, "fra", codec: "truehd"), audio(2, "eng", isDefault: true)], interface: "fr")
        #expect(decision.audio == 1 && decision.audioReason == .fileDefault)
    }

    // MARK: Subtitles

    @Test("app language, audio in another language: full subtitles in the app's language")
    func interfaceSmartForeignAudio() {
        let subs = [sub(5, "fra", forced: true), sub(6, "eng"), sub(7, "fra")]
        let decision = decide(audio: [audio(1, "eng", isDefault: true)], subs: subs, interface: "fr")
        #expect(decision.subtitle == .ordinal(2) && decision.subtitleReason == .interface)
    }

    @Test("app language, audio in that language: forced only, else none")
    func interfaceSmartSameAudio() {
        let tracks = [audio(1, "fra", isDefault: true)]
        let withForced = decide(audio: tracks, subs: [sub(5, "fra"), sub(6, "fra", forced: true)], interface: "fr")
        #expect(withForced.subtitle == .ordinal(1) && withForced.subtitleReason == .interface)
        let without = decide(audio: tracks, subs: [sub(5, "fra"), sub(6, "eng")], interface: "fr")
        #expect(without.subtitle == .off && without.subtitleReason == .interface)
    }

    @Test("untagged audio reads the cautious way: forced or none")
    func untaggedAudioIsCautious() {
        let decision = decide(audio: [audio(1, nil, isDefault: true)], subs: [sub(5, "fra")], interface: "fr")
        #expect(decision.subtitle == .off)
    }

    @Test("no subtitle in the app's language: forced ones in the audio's language")
    func forcedInAudioLanguage() {
        let subs = [sub(5, "jpn", forced: true), sub(6, "spa")]
        let decision = decide(audio: [audio(1, "jpn", isDefault: true)], subs: subs, interface: "fr")
        #expect(decision.subtitle == .ordinal(0) && decision.subtitleReason == .fileDefault)
    }

    @Test("nothing relevant: no subtitles, never the first track that comes")
    func nothingRelevant() {
        let decision = decide(audio: [audio(1, "jpn", isDefault: true)], subs: [sub(5, "spa"), sub(6, "deu")], interface: "fr")
        #expect(decision.subtitle == .off && decision.subtitleReason == .none)
    }

    @Test("account mode « aucun » stays off, whatever the language")
    func accountNone() {
        let decision = decide(audio: [audio(1, "eng")], subs: [sub(5, "fra")],
                              account: UserPlaybackPreferences(subtitleMode: .none), interface: "fr")
        #expect(decision.subtitle == .off && decision.subtitleReason == .account)
    }

    @Test("account « intelligent »: full when the audio is foreign, forced when it is the same")
    func accountSmart() {
        let subs = [sub(5, "eng", forced: true), sub(6, "eng"), sub(7, "fra")]
        let account = UserPlaybackPreferences(subtitleLanguage: "en", subtitleMode: .smart)
        let foreign = decide(audio: [audio(1, "fra")], subs: subs, account: account)
        #expect(foreign.subtitle == .ordinal(1) && foreign.subtitleReason == .account)
        let same = decide(audio: [audio(1, "eng")], subs: subs, account: account)
        #expect(same.subtitle == .ordinal(0) && same.subtitleReason == .account)
    }

    @Test("account « toujours » with no match falls to the app's language")
    func accountAlwaysFallsThrough() {
        let subs = [sub(5, "fra")]
        let account = UserPlaybackPreferences(subtitleLanguage: "de", subtitleMode: .always)
        let decision = decide(audio: [audio(1, "eng")], subs: subs, account: account, interface: "fr")
        #expect(decision.subtitle == .ordinal(0) && decision.subtitleReason == .interface)
    }

    @Test("account « forcés seulement » without forced subtitles: none")
    func accountOnlyForced() {
        let account = UserPlaybackPreferences(subtitleLanguage: "fr", subtitleMode: .onlyForced)
        let decision = decide(audio: [audio(1, "eng")], subs: [sub(5, "fra")], account: account)
        #expect(decision.subtitle == .off && decision.subtitleReason == .account)
    }

    @Test("subtitles follow the audio the cascade chose, not the server's")
    func subtitlesReadChosenAudio() {
        let tracks = [audio(1, "fra", isDefault: true), audio(2, "eng")]
        let subs = [sub(5, "fra")]
        let decision = decide(audio: tracks, subs: subs, account: UserPlaybackPreferences(audioLanguage: "en"),
                              interface: "fr", serverAudio: 1)
        #expect(decision.audio == 1)
        #expect(decision.subtitle == .ordinal(0) && decision.subtitleReason == .interface)
    }
}
