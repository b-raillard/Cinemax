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
        //
        // Subscribed at `.debug`, not `.warning`: the core's module-selection
        // lines (`using video decoder module "videotoolbox"`) are debug-level,
        // and they are the only ground truth for whether playback runs on the
        // hardware path (videotoolbox vs avcodec, which vout, which interop).
        // The C shim formats every message before the level filter anyway (see
        // header note), so the widened subscription only adds the Swift-side
        // triage below — two `hasPrefix` checks on the fast path.
        Task.detached(priority: .utility) {
            for await entry in VLCInstance.shared.logStream(minimumLevel: .debug) {
                if entry.level >= .warning {
                    let module = entry.module ?? "?"
                    let message = scrubbed(entry.message)
                    if entry.level == .error {
                        logger.error("libVLC [\(module, privacy: .public)] \(message, privacy: .public)")
                    } else {
                        logger.notice("libVLC [\(module, privacy: .public)] \(message, privacy: .public)")
                    }
                    continue
                }
                // Debug/notice tier: only the module-selection lines matter.
                guard let selection = parseModuleSelection(entry.message) else { continue }
                // Mirror to OSLog so a Console.app capture answers "which
                // decoder ran" without the on-screen HUD. Module names are
                // plugin identifiers — nothing to scrub.
                logger.notice("libVLC module ▸ \(selection.capability, privacy: .public) = \(selection.module, privacy: .public)")
                Task { @MainActor in
                    VLCEngineFacts.shared.record(capability: selection.capability, module: selection.module)
                }
            }
        }
        return true
    }()

    /// Parses the core's module-selection lines:
    /// `using video decoder module "videotoolbox"` → `("video decoder", "videotoolbox")`
    /// `no vout display modules matched` → `("vout display", "∅")`
    /// Anything else → nil. Pure + static for unit testing.
    static func parseModuleSelection(_ message: String) -> (capability: String, module: String)? {
        if message.hasPrefix("using ") {
            guard let quoteStart = message.firstIndex(of: "\"") else { return nil }
            let head = message[message.index(message.startIndex, offsetBy: "using ".count)..<quoteStart]
            guard head.hasSuffix("module ") else { return nil }
            let capability = head.dropLast("module ".count).trimmingCharacters(in: .whitespaces)
            let tail = message[message.index(after: quoteStart)...]
            guard let quoteEnd = tail.firstIndex(of: "\"") else { return nil }
            let module = String(tail[..<quoteEnd])
            guard !capability.isEmpty, !module.isEmpty, isTrackedCapability(capability) else { return nil }
            return (capability, module)
        }
        if message.hasPrefix("no "), message.hasSuffix(" modules matched") {
            let capability = String(message.dropFirst("no ".count).dropLast(" modules matched".count))
            guard !capability.isEmpty, isTrackedCapability(capability) else { return nil }
            return (capability, "∅")
        }
        return nil
    }

    /// Which capabilities are worth surfacing. Video-side selections plus the
    /// demuxer and every decoder tier; deliberately not audio filters/outputs
    /// (chatty, and the audio path is not what stutter diagnosis needs).
    static func isTrackedCapability(_ capability: String) -> Bool {
        if capability.hasPrefix("vout window") { return false } // windowing noise, not rendering
        return capability.hasPrefix("video") || capability.hasPrefix("vout")
            || capability == "demux" || capability.contains("decoder") || capability.contains("interop")
    }

    /// Compact per-capability label for the stats HUD line.
    static func shortLabel(for capability: String) -> String {
        switch capability {
        case "video decoder": "vdec"
        case "audio decoder": "adec"
        case "spu decoder": "sdec"
        case "decoder device": "dev"
        case "vout display": "vout"
        case "glinterop": "interop"
        case "video converter": "vconv"
        case "video filter": "vfilt"
        default: capability
        }
    }

    /// libVLC logs the URLs it opens, and ours carry the account token as an
    /// `ApiKey` query item (libVLC can't reliably inject the auth header), so a
    /// raw message would write that token into the system log. Same rule as
    /// `redactedURL` on the API side — strip it before anything is emitted.
    ///
    /// Both spellings, case-insensitively: `authedURL` appends `ApiKey`, the
    /// server writes `&ApiKey=` into every `TranscodingUrl` itself, and the
    /// legacy `api_key` may still appear in a URL we didn't author. Until
    /// 2026-09 the marker was `api_key=` alone, so the token of every
    /// forced-transcode HLS open reached the system log in clear.
    static func scrubbed(_ message: String) -> String {
        guard let first = nextMarker(in: Substring(message)) else { return message }
        var result = ""
        var rest = Substring(message)
        var marker: Range<Substring.Index>? = first
        while let found = marker {
            result += String(rest[..<found.upperBound])
            result += "***"
            let value = rest[found.upperBound...]
            let end = value.firstIndex { valueTerminators.contains($0) } ?? value.endIndex
            rest = value[end...]
            marker = nextMarker(in: rest)
        }
        return result + String(rest)
    }

    private static let tokenMarkers = ["ApiKey=", "api_key="]

    /// The earliest token marker in `text`, whichever spelling it uses.
    private static func nextMarker(in text: Substring) -> Range<Substring.Index>? {
        tokenMarkers
            .compactMap { text.range(of: $0, options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    /// Where a token value stops. Deliberately a deny-list of characters a
    /// Jellyfin token (alphanumeric) can never contain: a missing entry only
    /// swallows some surrounding log text, whereas an over-eager terminator
    /// would end the value mid-token and leave the tail in the log.
    private static let valueTerminators: Set<Character> = [
        "&", "#", " ", "\t", "\n", "\r", "'", "\"", "`",
        "(", ")", "[", "]", "{", "}", "<", ">", ",", ";", "|", "\\",
    ]
}

/// The engine facts the log stream has learned about the CURRENT media: which
/// module libVLC actually selected per capability (hardware `videotoolbox` vs
/// software `avcodec` decode, which vout, whether a CPU converter was inserted).
/// Rendered as the `Modules` line of the player's stats HUD; reset by
/// `VLCStreamPresenter.beginOpenLoading()` at every fresh open so facts from
/// the previous media can't linger. Plain stored state, tick-repainted by
/// `refreshStats` — no @Observable needed.
@MainActor
final class VLCEngineFacts {
    static let shared = VLCEngineFacts()
    private init() {}

    private(set) var modules: [String: String] = [:]

    func record(capability: String, module: String) {
        modules[capability] = module
    }

    func reset() {
        modules = [:]
    }

    /// Fixed presentation order — decode chain first, render chain last —
    /// then any untabled capability alphabetically.
    private static let displayOrder = [
        "demux", "video decoder", "decoder device", "audio decoder", "spu decoder",
        "vout display", "glinterop", "video converter", "video filter",
    ]

    var summary: String? {
        guard !modules.isEmpty else { return nil }
        let ordered = Self.displayOrder.compactMap { cap in
            modules[cap].map { (cap, $0) }
        }
        let rest = modules.keys
            .filter { !Self.displayOrder.contains($0) }
            .sorted()
            .map { ($0, modules[$0]!) }
        return (ordered + rest)
            .map { "\(VLCEngineLog.shortLabel(for: $0.0)) \($0.1)" }
            .joined(separator: " · ")
    }
}
