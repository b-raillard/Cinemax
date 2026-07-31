import Foundation
import OSLog
import SwiftVLC

private let logger = Logger(subsystem: "com.cinemax", category: "libVLC")

/// Routes libVLC's own log output into OSLog instead of stderr.
///
/// libVLC writes through a default *console* logger that goes straight to
/// stderr, and its volume is proportional to the number of HTTP transactions it
/// runs: a DirectPlay MKV opens one long connection and then goes quiet, while
/// an HLS transcode — what seek-heavy containers like AVI are forced into — runs
/// a full access/TLS/demux cycle per segment, every few seconds, for the whole
/// film. That is the entire reason an AVI is noisy and a 4K MKV isn't; none of
/// it comes from the app's own logging, which is event-driven and never fires on
/// the 1s tick.
///
/// Installing a log callback (`libvlc_log_set`, which is what `logStream` does
/// under the hood) *replaces and destroys* that console logger — so subscribing
/// is itself what silences stderr. Messages emitted while the instance is being
/// created still reach stderr; that's a documented libVLC limitation.
///
/// If the cost of libVLC *formatting* messages we then drop ever matters, the
/// next lever is a dedicated `VLCInstance(arguments: defaultArguments +
/// ["--verbose=0"])` injected via `Player(instance:)` — the shim's `vsnprintf`
/// runs before the level filter, so only reduced verbosity avoids it.
enum VLCEngineLog {
    /// Idempotent — the `static let` body runs once per process.
    static func installOnce() { _ = installed }

    private static let installed: Bool = {
        // The stream must be consumed for the process's lifetime: its
        // `onTermination` calls `libvlc_log_unset`, which would hand stderr back.
        Task.detached(priority: .utility) {
            for await entry in VLCInstance.shared.logStream(minimumLevel: .warning) {
                let module = entry.module ?? "?"
                let message = scrubbed(entry.message)
                if entry.level == .error {
                    logger.error("libVLC [\(module, privacy: .public)] \(message, privacy: .public)")
                } else {
                    logger.notice("libVLC [\(module, privacy: .public)] \(message, privacy: .public)")
                }
            }
        }
        return true
    }()

    /// libVLC logs the URLs it opens, and ours carry the account token as an
    /// `api_key` query item (libVLC can't reliably inject the auth header), so a
    /// raw message would write that token into the system log. Same rule as
    /// `redactedURL` on the API side — strip it before anything is emitted.
    static func scrubbed(_ message: String) -> String {
        guard message.contains(tokenMarker) else { return message }
        var result = ""
        var rest = Substring(message)
        while let marker = rest.range(of: tokenMarker) {
            result += String(rest[..<marker.upperBound])
            result += "***"
            let value = rest[marker.upperBound...]
            let end = value.firstIndex { valueTerminators.contains($0) } ?? value.endIndex
            rest = value[end...]
        }
        return result + String(rest)
    }

    private static let tokenMarker = "api_key="

    /// Where a token value stops. Deliberately a deny-list of characters a
    /// Jellyfin token (alphanumeric) can never contain: a missing entry only
    /// swallows some surrounding log text, whereas an over-eager terminator
    /// would end the value mid-token and leave the tail in the log.
    private static let valueTerminators: Set<Character> = [
        "&", "#", " ", "\t", "\n", "\r", "'", "\"", "`",
        "(", ")", "[", "]", "{", "}", "<", ">", ",", ";", "|", "\\",
    ]
}
