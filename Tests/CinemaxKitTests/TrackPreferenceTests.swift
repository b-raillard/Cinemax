import Foundation
import Testing
import CinemaxKit
@testable import Cinemax

/// The audio and subtitles picked by hand in one episode carry to the next
/// episodes of the series — matched by description, never by position, since
/// the next file can list its tracks in another order.
@Suite("TrackPreference")
struct TrackPreferenceTests {

    private func track(
        _ id: Int, _ label: String, language: String?, codec: String? = "ac3", forced: Bool = false
    ) -> MediaTrackInfo {
        MediaTrackInfo(id: id, label: label, isDefault: false, isForced: forced, codec: codec, language: language)
    }

    @Test("the remembered audio is found by language in a reordered episode")
    func audioFollowsLanguageNotPosition() {
        let episode1 = [track(1, "Français - AC3", language: "fre"), track(2, "English - EAC3", language: "eng", codec: "eac3")]
        let wanted = TrackPreferencePolicy.audio(episode1[1])
        let episode2 = [track(1, "English - EAC3", language: "eng", codec: "eac3"), track(2, "Français - AC3", language: "fre")]
        #expect(TrackPreferencePolicy.audioOrdinal(for: wanted, in: episode2) == 0)
    }

    @Test("same label wins, then same codec, within the language")
    func audioTieBreaks() {
        let wanted = TrackPreference.Audio(language: "eng", label: "English - Commentary", codec: "aac")
        let tracks = [
            track(1, "English - AC3 5.1", language: "eng"),
            track(2, "English - AAC", language: "eng", codec: "aac"),
            track(3, "English - Commentary", language: "eng", codec: "aac"),
        ]
        #expect(TrackPreferencePolicy.audioOrdinal(for: wanted, in: tracks) == 2)
        #expect(TrackPreferencePolicy.audioOrdinal(for: wanted, in: Array(tracks.prefix(2))) == 1)
    }

    @Test("a silent pick never opens the next episode silent")
    func silentPickFallsToAudibleSameLanguage() {
        let wanted = TrackPreference.Audio(language: "eng", label: "English - TrueHD Atmos", codec: "truehd")
        let tracks = [
            track(1, "Français - DTS", language: "fre", codec: "dts"),
            track(2, "English - TrueHD Atmos", language: "eng", codec: "truehd"),
            track(3, "English - AC3", language: "eng"),
        ]
        #expect(TrackPreferencePolicy.audioOrdinal(for: wanted, in: tracks) == 2)
        #expect(TrackPreferencePolicy.audioOrdinal(for: wanted, in: Array(tracks.prefix(2))) == nil)
    }

    @Test("no track of that language: the server decides")
    func audioWithoutMatch() {
        let wanted = TrackPreference.Audio(language: "jpn", label: "Japanese", codec: "aac")
        #expect(TrackPreferencePolicy.audioOrdinal(for: wanted, in: [track(1, "English", language: "eng")]) == nil)
    }

    @Test("subtitles off stays off")
    func subtitlesOff() {
        #expect(TrackPreferencePolicy.subtitleChoice(for: .off, in: [track(5, "Français", language: "fre")]) == .off)
        #expect(TrackPreferencePolicy.subtitle(nil) == .off)
    }

    @Test("forced and full subtitles never stand in for each other")
    func forcedIsKept() {
        let forced = TrackPreferencePolicy.subtitle(track(5, "Français (forcés)", language: "fre", forced: true))
        let full = TrackPreferencePolicy.subtitle(track(6, "Français", language: "fre"))
        let episode2 = [track(7, "Français", language: "fre"), track(8, "Français (forcés)", language: "fre", forced: true)]
        #expect(TrackPreferencePolicy.subtitleChoice(for: forced, in: episode2) == .ordinal(1))
        #expect(TrackPreferencePolicy.subtitleChoice(for: full, in: episode2) == .ordinal(0))
        #expect(TrackPreferencePolicy.subtitleChoice(for: forced, in: [track(7, "Français", language: "fre")]) == nil)
    }

    @Test("the store keeps audio and subtitles apart, per account and series")
    func storeMergesAndScopes() {
        let store = TrackPreferenceStore(defaults: .isolatedForTesting())
        let audio = TrackPreference.Audio(language: "eng", label: "English", codec: "ac3")
        store.recordAudio(audio, userId: "u1", titleId: "s1")
        store.recordSubtitle(.off, userId: "u1", titleId: "s1")
        let kept = store.preference(userId: "u1", titleId: "s1")
        #expect(kept?.audio == audio)
        #expect(kept?.subtitle == .off)
        #expect(store.preference(userId: "u2", titleId: "s1") == nil)
        #expect(store.preference(userId: "u1", titleId: "s2") == nil)
    }

    @Test("past the limit the oldest series is forgotten")
    func storeIsBounded() {
        let store = TrackPreferenceStore(defaults: .isolatedForTesting())
        let start = Date(timeIntervalSince1970: 0)
        for index in 0...TrackPreferenceStore.limit {
            store.recordSubtitle(.off, userId: "u", titleId: "s\(index)", now: start.addingTimeInterval(Double(index)))
        }
        #expect(store.preference(userId: "u", titleId: "s0") == nil)
        #expect(store.preference(userId: "u", titleId: "s1") != nil)
        #expect(store.preference(userId: "u", titleId: "s\(TrackPreferenceStore.limit)") != nil)
    }

    // MARK: Account sync

    private func pref(_ language: String, at seconds: Double) -> TrackPreference {
        TrackPreference(
            audio: .init(language: language, label: language, codec: "aac"),
            subtitle: .off,
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("per title, the newer choice wins; titles from both sides are kept")
    func mergeNewestWins() {
        let local = ["s1": pref("eng", at: 20), "s2": pref("fra", at: 5)]
        let remote = ["s1": pref("fra", at: 10), "s2": pref("eng", at: 30), "s3": pref("deu", at: 1)]
        let merged = TrackPreferenceSync.merged(local, remote, limit: 500)
        #expect(merged["s1"]?.audio?.language == "eng")
        #expect(merged["s2"]?.audio?.language == "eng")
        #expect(merged["s3"]?.audio?.language == "deu")
    }

    @Test("past the limit, the oldest titles go")
    func mergeIsBounded() {
        let local = ["a": pref("eng", at: 1), "b": pref("eng", at: 3)]
        let remote = ["c": pref("eng", at: 2)]
        let merged = TrackPreferenceSync.merged(local, remote, limit: 2)
        #expect(Set(merged.keys) == ["b", "c"])
    }

    @Test("the stored value round-trips; anything unreadable is an empty copy")
    func encodingRoundTrips() {
        let entries = ["s1": pref("eng", at: 20)]
        #expect(TrackPreferenceSync.decode(TrackPreferenceSync.encode(entries)) == entries)
        #expect(TrackPreferenceSync.decode("not json").isEmpty)
        #expect(TrackPreferenceSync.decode(nil).isEmpty)
    }

    @Test("absorbing the account's copy touches that account only")
    func absorbIsPerAccount() {
        let store = TrackPreferenceStore(defaults: .isolatedForTesting())
        store.recordSubtitle(.off, userId: "u1", titleId: "s1", now: Date(timeIntervalSince1970: 50))
        store.recordSubtitle(.off, userId: "u2", titleId: "s1", now: Date(timeIntervalSince1970: 50))
        store.absorb(["s1": pref("fra", at: 10), "s9": pref("eng", at: 10)], userId: "u1")
        #expect(store.preference(userId: "u1", titleId: "s1")?.audio == nil) // the newer local one stays
        #expect(store.preference(userId: "u1", titleId: "s9")?.audio?.language == "eng")
        #expect(store.preference(userId: "u2", titleId: "s9") == nil)
        #expect(store.entries(userId: "u2").count == 1)
    }
}

