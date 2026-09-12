import Foundation
import Testing
@testable import Cinemax

/// `VLCStreamPresenter.authedURL` is the only place the app puts the account
/// token into a URL for libVLC, which cannot reliably send the
/// `Authorization` header. Jellyfin 12.0 disables legacy authorization by
/// default (`EnableLegacyAuthorization = false`, PR #15559 / #16992), which
/// rejects the `api_key` spelling; `ApiKey` is read unconditionally on every
/// server since 10.8 (`AuthorizationContext.cs`), so it is the one to send.
@Suite("VLCStreamPresenter.authedURL")
struct AuthedURLTests {

    @Test("appends ApiKey, never the legacy api_key")
    func appendsApiKey() {
        let url = URL(string: "https://h/Videos/1/stream?static=true")!
        let authed = VLCStreamPresenter.authedURL(url, token: "tok")
        let items = URLComponents(url: authed, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.contains(URLQueryItem(name: "ApiKey", value: "tok")))
        #expect(!items.contains { $0.name == "api_key" })
        #expect(items.contains(URLQueryItem(name: "static", value: "true")))
    }

    @Test("a server-emitted transcode URL already carrying ApiKey is left alone")
    func keepsServerApiKey() {
        // What `TranscodingUrl` looks like: the server appends `&ApiKey=<token>`
        // itself (`StreamInfo.cs`). Before this the check compared against
        // `api_key` only, so the URL went out with BOTH spellings.
        let url = URL(string: "https://h/videos/1/master.m3u8?MediaSourceId=m&ApiKey=server")!
        let authed = VLCStreamPresenter.authedURL(url, token: "tok")
        #expect(authed == url)
        let items = URLComponents(url: authed, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.filter { $0.name.lowercased() == "apikey" }.count == 1)
    }

    @Test("a URL already carrying the legacy spelling is not double-authenticated")
    func keepsLegacyApiKey() {
        let url = URL(string: "https://h/s?api_key=old")!
        #expect(VLCStreamPresenter.authedURL(url, token: "tok") == url)
    }

    @Test("no token means no change")
    func noToken() {
        let url = URL(string: "https://h/s?static=true")!
        #expect(VLCStreamPresenter.authedURL(url, token: nil) == url)
        #expect(VLCStreamPresenter.authedURL(url, token: "") == url)
    }

    @Test("the server base path survives")
    func keepsBasePath() {
        let url = URL(string: "https://host/jellyfin/Videos/1/stream")!
        let authed = VLCStreamPresenter.authedURL(url, token: "tok")
        #expect(authed.absoluteString == "https://host/jellyfin/Videos/1/stream?ApiKey=tok")
    }

    @Test("either spelling, any case, counts as a token already present")
    func detectsApiKeyAnySpelling() {
        #expect(VLCStreamPresenter.carriesApiKey(URL(string: "https://h/s?APIKEY=x")!))
        #expect(VLCStreamPresenter.carriesApiKey(URL(string: "https://h/s?api_key=x")!))
        #expect(!VLCStreamPresenter.carriesApiKey(URL(string: "https://h/s?static=true")!))
    }
}

/// `VLCStreamPresenter.streamURL` decides, attempt by attempt, whether the
/// account token rides a stream URL (#184). The DirectPlay route is anonymous
/// on every supported server, so its `ApiKey` only ever reached reverse-proxy
/// access logs; it comes back on a DIRECT retry alone, and a proxied open
/// authenticates through the proxy's `Authorization` header instead.
@Suite("VLCStreamPresenter.streamURL")
struct StreamURLTests {

    /// The shape `getPlaybackInfo` builds for a VLC DirectPlay, sub-path server.
    private let directPlay = URL(string: "https://h/jellyfin/Videos/1/stream?static=true&playSessionId=p&mediaSourceId=m")!
    /// What a forced-transcode `TranscodingUrl` looks like: the server's own `ApiKey`.
    private let transcode = URL(string: "https://h/videos/1/master.m3u8?MediaSourceId=m&ApiKey=server")!

    private func tokens(_ url: URL) -> [URLQueryItem] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { ["apikey", "api_key"].contains($0.name.lowercased()) }
    }

    @Test("a first DirectPlay open carries no token, direct or proxied")
    func firstOpenIsTokenless() {
        for viaProxy in [false, true] {
            let url = VLCStreamPresenter.streamURL(directPlay, token: "tok", isRetry: false, viaProxy: viaProxy)
            #expect(url == directPlay)
            #expect(tokens(url).isEmpty)
        }
    }

    @Test("a direct retry puts exactly one ApiKey back, on the same path")
    func directRetryCarriesOneToken() {
        let url = VLCStreamPresenter.streamURL(directPlay, token: "tok", isRetry: true, viaProxy: false)
        #expect(tokens(url) == [URLQueryItem(name: "ApiKey", value: "tok")])
        #expect(url.path == "/jellyfin/Videos/1/stream")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.contains(URLQueryItem(name: "playSessionId", value: "p")))
    }

    @Test("a proxied retry leaves the token to the proxy's Authorization header")
    func proxiedRetryIsTokenless() {
        let url = VLCStreamPresenter.streamURL(directPlay, token: "tok", isRetry: true, viaProxy: true)
        #expect(url == directPlay)
        #expect(tokens(url).isEmpty)
    }

    @Test("a direct retry with no token to give changes nothing")
    func directRetryWithoutToken() {
        #expect(VLCStreamPresenter.streamURL(directPlay, token: nil, isRetry: true, viaProxy: false) == directPlay)
    }

    @Test("a TranscodingUrl keeps the server's single ApiKey on every attempt and route")
    func transcodeTokenNeverDoubled() {
        for isRetry in [false, true] {
            for viaProxy in [false, true] {
                for token in [nil, "tok"] as [String?] {
                    let url = VLCStreamPresenter.streamURL(transcode, token: token, isRetry: isRetry, viaProxy: viaProxy)
                    #expect(tokens(url) == [URLQueryItem(name: "ApiKey", value: "server")])
                }
            }
        }
    }
}
