import Foundation
import Testing
@testable import CinemaxKit

/// Jellyfin 12.0 localizes per request from `Accept-Language` (jellyfin PR
/// #16488): the `DisplayTitle` of every media stream — « Default » / « Forced »
/// become « Par défaut » / « Forcé » — is what the audio and subtitle pickers
/// print. A 10.x server has no request-localization middleware and ignores the
/// header, so this is the one 12.0 feature that needs no version gate: it is
/// a pure header, and it is harmless wherever it lands.
@Suite("Accept-Language")
struct AcceptLanguageTests {

    @Test("the app's two languages map to a region-qualified header with a bare fallback")
    func mapping() {
        #expect(JellyfinAPIClient.acceptLanguageHeader(for: "fr") == "fr-FR, fr;q=0.9")
        #expect(JellyfinAPIClient.acceptLanguageHeader(for: "en") == "en-US, en;q=0.9")
    }

    @Test("an unknown code travels as-is rather than being dropped")
    func unknownCode() {
        #expect(JellyfinAPIClient.acceptLanguageHeader(for: "de") == "de")
    }

    @Test("an empty or blank code yields no header")
    func blank() {
        #expect(JellyfinAPIClient.acceptLanguageHeader(for: "") == nil)
        #expect(JellyfinAPIClient.acceptLanguageHeader(for: "  ") == nil)
    }

    @Test("the session configuration carries the header and keeps its bounded-timeout contract")
    func sessionConfiguration() {
        let with = JellyfinAPIClient.sessionConfiguration(acceptLanguage: "fr-FR, fr;q=0.9")
        #expect(with.httpAdditionalHeaders?["Accept-Language"] as? String == "fr-FR, fr;q=0.9")
        #expect(with.timeoutIntervalForRequest == 30)
        #expect(with.timeoutIntervalForResource == 60)
        #expect(with.waitsForConnectivity == false)
        #expect(with.urlCache == nil)

        let without = JellyfinAPIClient.sessionConfiguration(acceptLanguage: nil)
        #expect(without.httpAdditionalHeaders?["Accept-Language"] == nil)
        #expect(without.urlCache == nil)
    }

    @Test("changing the language rebuilds the client in place: same server, same token, version kept")
    func rebuildKeepsSession() {
        let api = JellyfinAPIClient()
        let url = URL(string: "https://host/jellyfin")!
        api.reconnect(url: url, accessToken: "tok")
        api.setServerVersion("12.0.0")

        api.setPreferredLanguage("en")

        #expect(api.getServerURL() == url)
        #expect(api.getClient() != nil)
        #expect(api.getServerVersion() == ServerVersion(12, 0, 0),
                "a language change repoints nothing — the learned version must survive")
        #expect(api.getPreferredLanguage() == "en")
    }

    @Test("the raw PlaybackInfo POST re-attaches the header the SDK session would carry")
    func rawPlaybackInfoRequest() {
        var request = URLRequest(url: URL(string: "https://host/Items/x/PlaybackInfo")!)
        JellyfinAPIClient.applyAcceptLanguage(to: &request, languageCode: "fr")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "fr-FR, fr;q=0.9")

        var bare = URLRequest(url: URL(string: "https://host/Items/x/PlaybackInfo")!)
        JellyfinAPIClient.applyAcceptLanguage(to: &bare, languageCode: nil)
        #expect(bare.value(forHTTPHeaderField: "Accept-Language") == nil)
    }

    @Test("setting the language before any connection only records it")
    func recordedBeforeConnection() {
        let api = JellyfinAPIClient()
        api.setPreferredLanguage("fr")
        #expect(api.getClient() == nil)
        #expect(api.getPreferredLanguage() == "fr")
    }
}
