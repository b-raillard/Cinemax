import Foundation
import Testing
import CinemaxKit
@testable import Cinemax

/// The audio and subtitles picked by hand in one episode carry to the next
/// episodes of the series — matched by description, never by position, since
/// the next file can list its tracks in another order.
@Suite("SeriesTrackPreference")
struct SeriesTrackPreferenceTests {

    private func track(
        _ id: Int, _ label: String, language: String?, codec: String? = "ac3", forced: Bool = false
    ) -> MediaTrackInfo {
        MediaTrackInfo(id: id, label: label, isDefault: false, isForced: forced, codec: codec, language: language)
    }

    @Test("the remembered audio is found by language in a reordered episode")
    func audioFollowsLanguageNotPosition() {
        let episode1 = [track(1, "Français - AC3", language: "fre"), track(2, "English - EAC3", language: "eng", codec: "eac3")]
        let wanted = SeriesTrackPolicy.audio(episode1[1])
        let episode2 = [track(1, "English - EAC3", language: "eng", codec: "eac3"), track(2, "Français - AC3", language: "fre")]
        #expect(SeriesTrackPolicy.audioOrdinal(for: wanted, in: episode2) == 0)
    }

    @Test("same label wins, then same codec, within the language")
    func audioTieBreaks() {
        let wanted = SeriesTrackPreference.Audio(language: "eng", label: "English - Commentary", codec: "aac")
        let tracks = [
            track(1, "English - AC3 5.1", language: "eng"),
            track(2, "English - AAC", language: "eng", codec: "aac"),
            track(3, "English - Commentary", language: "eng", codec: "aac"),
        ]
        #expect(SeriesTrackPolicy.audioOrdinal(for: wanted, in: tracks) == 2)
        #expect(SeriesTrackPolicy.audioOrdinal(for: wanted, in: Array(tracks.prefix(2))) == 1)
    }

    @Test("a silent pick never opens the next episode silent")
    func silentPickFallsToAudibleSameLanguage() {
        let wanted = SeriesTrackPreference.Audio(language: "eng", label: "English - TrueHD Atmos", codec: "truehd")
        let tracks = [
            track(1, "Français - DTS", language: "fre", codec: "dts"),
            track(2, "English - TrueHD Atmos", language: "eng", codec: "truehd"),
            track(3, "English - AC3", language: "eng"),
        ]
        #expect(SeriesTrackPolicy.audioOrdinal(for: wanted, in: tracks) == 2)
        #expect(SeriesTrackPolicy.audioOrdinal(for: wanted, in: Array(tracks.prefix(2))) == nil)
    }

    @Test("no track of that language: the server decides")
    func audioWithoutMatch() {
        let wanted = SeriesTrackPreference.Audio(language: "jpn", label: "Japanese", codec: "aac")
        #expect(SeriesTrackPolicy.audioOrdinal(for: wanted, in: [track(1, "English", language: "eng")]) == nil)
    }

    @Test("subtitles off stays off")
    func subtitlesOff() {
        #expect(SeriesTrackPolicy.subtitleChoice(for: .off, in: [track(5, "Français", language: "fre")]) == .off)
        #expect(SeriesTrackPolicy.subtitle(nil) == .off)
    }

    @Test("forced and full subtitles never stand in for each other")
    func forcedIsKept() {
        let forced = SeriesTrackPolicy.subtitle(track(5, "Français (forcés)", language: "fre", forced: true))
        let full = SeriesTrackPolicy.subtitle(track(6, "Français", language: "fre"))
        let episode2 = [track(7, "Français", language: "fre"), track(8, "Français (forcés)", language: "fre", forced: true)]
        #expect(SeriesTrackPolicy.subtitleChoice(for: forced, in: episode2) == .ordinal(1))
        #expect(SeriesTrackPolicy.subtitleChoice(for: full, in: episode2) == .ordinal(0))
        #expect(SeriesTrackPolicy.subtitleChoice(for: forced, in: [track(7, "Français", language: "fre")]) == nil)
    }

    @Test("the store keeps audio and subtitles apart, per account and series")
    func storeMergesAndScopes() {
        let store = SeriesTrackPreferenceStore(defaults: .isolatedForTesting())
        let audio = SeriesTrackPreference.Audio(language: "eng", label: "English", codec: "ac3")
        store.recordAudio(audio, userId: "u1", seriesId: "s1")
        store.recordSubtitle(.off, userId: "u1", seriesId: "s1")
        let kept = store.preference(userId: "u1", seriesId: "s1")
        #expect(kept?.audio == audio)
        #expect(kept?.subtitle == .off)
        #expect(store.preference(userId: "u2", seriesId: "s1") == nil)
        #expect(store.preference(userId: "u1", seriesId: "s2") == nil)
    }

    @Test("past the limit the oldest series is forgotten")
    func storeIsBounded() {
        let store = SeriesTrackPreferenceStore(defaults: .isolatedForTesting())
        let start = Date(timeIntervalSince1970: 0)
        for index in 0...SeriesTrackPreferenceStore.limit {
            store.recordSubtitle(.off, userId: "u", seriesId: "s\(index)", now: start.addingTimeInterval(Double(index)))
        }
        #expect(store.preference(userId: "u", seriesId: "s0") == nil)
        #expect(store.preference(userId: "u", seriesId: "s1") != nil)
        #expect(store.preference(userId: "u", seriesId: "s\(SeriesTrackPreferenceStore.limit)") != nil)
    }
}
