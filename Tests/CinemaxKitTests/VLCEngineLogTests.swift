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
