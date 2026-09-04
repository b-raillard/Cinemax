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
}
