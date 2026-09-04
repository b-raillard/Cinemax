import Testing
@testable import Cinemax

/// `VLCEngineLog.scrubbed` is the guard between libVLC's own log messages and
/// OSLog. libVLC logs the URLs it opens and ours carry the account token as an
/// `api_key` query item, so any message reaching the system log must have that
/// value stripped — the `redactedURL` rule, applied to text we don't author.
@Suite("VLCEngineLog.scrubbed")
struct VLCEngineLogTests {

    @Test("message without a token is returned untouched")
    func passthrough() {
        let message = "main input error: Your input can't be opened"
        #expect(VLCEngineLog.scrubbed(message) == message)
    }

    @Test("token value is replaced, and the query items after it survive")
    func stripsTokenKeepingTrailingQuery() {
        let scrubbed = VLCEngineLog.scrubbed(
            "http debug: opening https://h/Videos/1/stream?api_key=abc123&static=true"
        )
        #expect(scrubbed == "http debug: opening https://h/Videos/1/stream?api_key=***&static=true")
        #expect(!scrubbed.contains("abc123"))
    }

    @Test("token at end of message is stripped")
    func stripsTokenAtEnd() {
        let scrubbed = VLCEngineLog.scrubbed("access error: https://h/s?api_key=deadbeef")
        #expect(scrubbed == "access error: https://h/s?api_key=***")
    }

    @Test("token followed by a space or quote ends at the delimiter")
    func stopsAtDelimiters() {
        #expect(
            VLCEngineLog.scrubbed("url 'https://h/s?api_key=tok' failed")
                == "url 'https://h/s?api_key=***' failed"
        )
        #expect(
            VLCEngineLog.scrubbed("api_key=tok some trailing words")
                == "api_key=*** some trailing words"
        )
    }

    @Test("every occurrence is scrubbed, not just the first")
    func stripsEveryOccurrence() {
        let scrubbed = VLCEngineLog.scrubbed(
            "retry https://h/a?api_key=one&x=1 after https://h/b?api_key=two"
        )
        #expect(scrubbed == "retry https://h/a?api_key=***&x=1 after https://h/b?api_key=***")
        #expect(!scrubbed.contains("one"))
        #expect(!scrubbed.contains("two"))
    }

    @Test("an empty token value stays scrubbed rather than dropping the marker")
    func handlesEmptyValue() {
        #expect(VLCEngineLog.scrubbed("s?api_key=&x=1") == "s?api_key=***&x=1")
    }

    // `ApiKey` is the query name Jellyfin keeps once legacy authorization is
    // off (12.0 default). It is what `authedURL` now appends AND what the
    // server itself writes into every `TranscodingUrl` (`StreamInfo.cs`:
    // `&ApiKey=`), so a scrubber that only knew `api_key=` let the token of
    // every forced-transcode HLS open through to the system log.

    @Test("the ApiKey spelling is scrubbed too")
    func stripsApiKeySpelling() {
        let scrubbed = VLCEngineLog.scrubbed(
            "http debug: opening https://h/Videos/1/stream?ApiKey=abc123&static=true"
        )
        #expect(scrubbed == "http debug: opening https://h/Videos/1/stream?ApiKey=***&static=true")
        #expect(!scrubbed.contains("abc123"))
    }

    @Test("the server-emitted transcode URL, which carries ApiKey mid-query, is scrubbed")
    func stripsServerTranscodeURL() {
        let scrubbed = VLCEngineLog.scrubbed(
            "opening https://h/videos/1/master.m3u8?DeviceId=d&MediaSourceId=m&ApiKey=tok&PlaySessionId=p"
        )
        #expect(scrubbed == "opening https://h/videos/1/master.m3u8?DeviceId=d&MediaSourceId=m&ApiKey=***&PlaySessionId=p")
    }

    @Test("both spellings in one message are scrubbed, whatever their order")
    func stripsMixedSpellings() {
        let scrubbed = VLCEngineLog.scrubbed("a?ApiKey=one&api_key=two b?api_key=three&ApiKey=four")
        #expect(scrubbed == "a?ApiKey=***&api_key=*** b?api_key=***&ApiKey=***")
    }

    @Test("marker match is case-insensitive, and the message's own spelling is kept")
    func caseInsensitiveMarker() {
        #expect(VLCEngineLog.scrubbed("s?APIKEY=tok&x=1") == "s?APIKEY=***&x=1")
        #expect(VLCEngineLog.scrubbed("s?Api_Key=tok") == "s?Api_Key=***")
    }
}

/// `parseModuleSelection` is what turns libVLC's debug stream into the stats
/// HUD's `Modules` line — the on-device answer to "is this decode hardware or
/// software". It must accept exactly the core's selection lines and nothing
/// else: a false positive would paint a bogus decode chain over a real one.
@Suite("VLCEngineLog.parseModuleSelection")
struct VLCEngineModuleParsingTests {

    @Test("video decoder selection is parsed")
    func videoDecoder() {
        let parsed = VLCEngineLog.parseModuleSelection("using video decoder module \"videotoolbox\"")
        #expect(parsed?.capability == "video decoder")
        #expect(parsed?.module == "videotoolbox")
    }

    @Test("vout display selection is parsed")
    func voutDisplay() {
        let parsed = VLCEngineLog.parseModuleSelection("using vout display module \"vout_ios\"")
        #expect(parsed?.capability == "vout display")
        #expect(parsed?.module == "vout_ios")
    }

    @Test("demux selection is parsed")
    func demux() {
        let parsed = VLCEngineLog.parseModuleSelection("using demux module \"mkv\"")
        #expect(parsed?.capability == "demux")
        #expect(parsed?.module == "mkv")
    }

    @Test("a failed match surfaces as ∅")
    func noModulesMatched() {
        let parsed = VLCEngineLog.parseModuleSelection("no vout display modules matched")
        #expect(parsed?.capability == "vout display")
        #expect(parsed?.module == "∅")
    }

    @Test("untracked capabilities are dropped even in selection shape")
    func untrackedCapability() {
        #expect(VLCEngineLog.parseModuleSelection("using audio filter module \"scaletempo\"") == nil)
        #expect(VLCEngineLog.parseModuleSelection("using vout window module \"uiview\"") == nil)
    }

    @Test("non-selection debug lines are rejected")
    func rejectsOtherLines() {
        #expect(VLCEngineLog.parseModuleSelection("using 4 threads for decoding") == nil)
        #expect(VLCEngineLog.parseModuleSelection("main debug: creating audio output") == nil)
        #expect(VLCEngineLog.parseModuleSelection("no access modules matched with name \"foo\"") == nil)
        #expect(VLCEngineLog.parseModuleSelection("") == nil)
    }

    @Test("audio and subtitle decoders stay tracked — they complete the chain")
    func audioAndSpuDecoders() {
        #expect(VLCEngineLog.parseModuleSelection("using audio decoder module \"avcodec\"")?.module == "avcodec")
        #expect(VLCEngineLog.parseModuleSelection("using spu decoder module \"subsdec\"")?.capability == "spu decoder")
    }
}
