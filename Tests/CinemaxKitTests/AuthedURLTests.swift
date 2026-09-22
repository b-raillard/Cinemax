import Foundation
import Testing
import JellyfinAPI
@testable import CinemaxKit
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

// MARK: - Device profiles (moved here: a new test file needs an xcodegen run)

/// The device profiles are what the server reads to decide between DirectPlay,
/// a remux and a full re-encode, and several of their fields carry a measured
/// defect behind them (see CLAUDE.md → Video Playback). None of that was locked
/// by a test: a well-meaning "cleanup" of one allow-list would compile, pass
/// the whole suite, and bring a freeze or a desync back.
@Suite("Device profiles")
struct DeviceProfileTests {

    private func codecs(_ list: String?) -> Set<String> {
        Set((list ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    // MARK: - Native (AVPlayer)

    @Test("the native HLS transcode targets hevc/h264 only — never mpeg4")
    func nativeTranscodeHasNoMpeg4() throws {
        let profile = JellyfinAPIClient.buildAppleDeviceProfile()
        let transcodes = try #require(profile.transcodingProfiles)
        #expect(!transcodes.isEmpty)
        for t in transcodes {
            #expect(codecs(t.videoCodec) == ["hevc", "h264"])
            #expect(!codecs(t.videoCodec).contains("mpeg4"))
            #expect(t.protocol == .hls)
        }
        for d in profile.directPlayProfiles ?? [] {
            #expect(!codecs(d.videoCodec).contains("mpeg4"))
        }
    }

    @Test("maxBitrate reaches the profile")
    func bitrateIsCarried() {
        #expect(JellyfinAPIClient.buildAppleDeviceProfile(maxBitrate: 20_000_000).maxStreamingBitrate == 20_000_000)
        #expect(JellyfinAPIClient.buildVLCDeviceProfile(maxBitrate: 120_000_000).maxStreamingBitrate == 120_000_000)
        #expect(JellyfinAPIClient.buildVLCTranscodeProfile(maxBitrate: 20_000_000).maxStreamingBitrate == 20_000_000)
    }

    // MARK: - VLC

    @Test("the VLC DirectPlay profile has no container restriction")
    func vlcDirectPlayIsUnrestricted() throws {
        let direct = try #require(JellyfinAPIClient.buildVLCDeviceProfile().directPlayProfiles)
        #expect(direct.count == 1)
        #expect(direct.first?.container == nil)
        // The DirectPlay list is where MPEG audio is copied as-is — the
        // opposite goal from the transcode list below.
        #expect(codecs(direct.first?.audioCodec).isSuperset(of: ["mp1", "mp2", "mp3"]))
    }

    @Test("the VLC transcode asks for MPEG-TS segments, one of them, and re-encodes MPEG audio")
    func vlcTranscodeShape() throws {
        for profile in [JellyfinAPIClient.buildVLCDeviceProfile(), JellyfinAPIClient.buildVLCTranscodeProfile()] {
            let transcodes = try #require(profile.transcodingProfiles)
            #expect(transcodes.count == 1)
            let t = try #require(transcodes.first)
            #expect(t.container == "ts")
            #expect(t.minSegments == 1)
            #expect(t.protocol == .hls)
            #expect(codecs(t.audioCodec).isDisjoint(with: ["mp1", "mp2", "mp3"]))
            #expect(codecs(t.videoCodec) == ["hevc", "h264"])
            // Jellyfin ignores it and 12.0 deprecates it — see CLAUDE.md.
            #expect(t.isBreakOnNonKeyFrames == false)
        }
    }

    @Test("the forced-transcode profile offers no DirectPlay at all")
    func vlcTranscodeForcesTranscode() {
        #expect(JellyfinAPIClient.buildVLCTranscodeProfile().directPlayProfiles?.isEmpty == true)
    }

    // MARK: - Seek-heavy containers

    @Test("seek-heavy containers are recognised, including joined container lists")
    func seekHeavy() {
        for c in ["avi", "AVI", "divx", "wmv", "asf", "flv", "vob", "mpg", "mpeg", "mpe", "m2v", "mkv,avi", "mov avi"] {
            #expect(JellyfinAPIClient.isSeekHeavyContainer(c), "\(c)")
        }
        for c in ["mkv", "mp4", "m4v", "mov", "ts", "webm", "", "aviary"] {
            #expect(!JellyfinAPIClient.isSeekHeavyContainer(c), "\(c)")
        }
        #expect(!JellyfinAPIClient.isSeekHeavyContainer(nil))
    }
}
