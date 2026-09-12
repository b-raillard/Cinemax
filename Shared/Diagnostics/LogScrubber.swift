import Foundation

/// The ONE place that strips secrets out of free text before it is logged or
/// exported. Two consumers, one rule:
///
/// - `VLCEngineLog` — libVLC logs the URLs it opens, and ours carry the account
///   token as an `ApiKey` query item (libVLC can't reliably inject the auth
///   header), so a raw message would write that token into the system log.
/// - The diagnostics export (`DiagnosticsExporter`) — it re-reads the app's own
///   OSLog entries and hands them to whoever the user shares the file with, so
///   anything that slipped into a log line must not leave the device.
///
/// Same intent as `redactedURL` on the API side, but for text we did not
/// author, where no `URLComponents` parse is possible.
///
/// Markers, all case-insensitive:
/// - `ApiKey=` / `api_key=` — `authedURL` appends `ApiKey`, the server writes
///   `&ApiKey=` into every `TranscodingUrl` itself, and the legacy `api_key`
///   may still appear in a URL we didn't author. Until 2026-09 the marker was
///   `api_key=` alone, so the token of every forced-transcode HLS open reached
///   the system log in clear.
/// - `token=` — the `Token="…"` field of a `MediaBrowser …` Authorization
///   header, an `X-Emby-Token=` query item, an `access_token=` — anything whose
///   name ENDS in "token". Deliberately broad: a false positive only masks some
///   harmless text, a false negative ships a credential.
/// - `X-Emby-Token:` / `X-MediaBrowser-Token:` — the header forms, where a
///   colon and optional spaces precede the value.
///
/// A value opening with a quote runs to the matching quote (`Token="abc"` →
/// `Token="***"`); otherwise it runs to the first `valueTerminators` character.
enum LogScrubber {
    static func scrubbed(_ message: String) -> String {
        guard let first = nextMarker(in: Substring(message)) else { return message }
        var result = ""
        var rest = Substring(message)
        var marker: Range<Substring.Index>? = first
        while let found = marker {
            var valueStart = found.upperBound
            // Header forms (`X-Emby-Token: abc`) put spaces before the value.
            if rest[found].hasSuffix(":") {
                while valueStart < rest.endIndex, rest[valueStart] == " " || rest[valueStart] == "\t" {
                    valueStart = rest.index(after: valueStart)
                }
            }
            // A quoted value keeps its quotes and loses only what they enclose.
            var closingQuote: Character?
            if valueStart < rest.endIndex, rest[valueStart] == "\"" || rest[valueStart] == "'" {
                closingQuote = rest[valueStart]
                valueStart = rest.index(after: valueStart)
            }
            result += String(rest[..<valueStart])
            result += "***"
            let value = rest[valueStart...]
            let end: Substring.Index
            if let quote = closingQuote {
                end = value.firstIndex { $0 == quote || $0 == "\n" || $0 == "\r" } ?? value.endIndex
            } else {
                end = value.firstIndex { valueTerminators.contains($0) } ?? value.endIndex
            }
            rest = value[end...]
            marker = nextMarker(in: rest)
        }
        return result + String(rest)
    }

    /// Order is irrelevant — the earliest match in the text wins.
    private static let tokenMarkers = [
        "ApiKey=", "api_key=", "token=", "X-Emby-Token:", "X-MediaBrowser-Token:",
    ]

    /// The earliest token marker in `text`, whichever spelling it uses.
    private static func nextMarker(in text: Substring) -> Range<Substring.Index>? {
        tokenMarkers
            .compactMap { text.range(of: $0, options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    /// Where an unquoted token value stops. Deliberately a deny-list of
    /// characters a Jellyfin token (alphanumeric) can never contain: a missing
    /// entry only swallows some surrounding log text, whereas an over-eager
    /// terminator would end the value mid-token and leave the tail in the log.
    private static let valueTerminators: Set<Character> = [
        "&", "#", " ", "\t", "\n", "\r", "'", "\"", "`",
        "(", ")", "[", "]", "{", "}", "<", ">", ",", ";", "|", "\\",
    ]
}
