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
