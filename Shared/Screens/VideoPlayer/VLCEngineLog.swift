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
    /// Installs the log bridge on ONE libVLC instance, at most once per instance.
    ///
    /// **RULE — this takes the instance the player actually uses, and is NOT a
    /// once-per-process install.** `libvlc_log_set` is per instance, so a player
    /// built with a dedicated `VLCInstance` (which subtitle styling does — see
    /// `SubtitleStyleOptions`) would be covered by nothing if this stayed bound
    /// to `VLCInstance.shared`: the loss is silent and costs `VLCEngineFacts`
    /// (the HUD's hardware-vs-software decode line, the only ground truth for
    /// stutter diagnosis) **and** the stderr capture that keeps tokens out of the
    /// system log via `LogScrubber`. On the default path the argument still IS
    /// `VLCInstance.shared`, so nothing changes for anybody who has not touched
    /// the appearance settings.
    @MainActor
    static func install(on instance: VLCInstance) {
        guard installedInstances.insert(ObjectIdentifier(instance)).inserted else { return }
        // The stream is obtained HERE, on the main actor, and only the stream is
        // captured by the task below: `AsyncStream` of a Sendable element is
        // itself Sendable, whereas capturing the instance would be a region
        // transfer of a non-Sendable class (same discipline as `JellyfinSocket`).
        consume(instance.logStream(minimumLevel: .debug))
    }

    /// Instances already bridged. Never pruned: an instance whose player is gone
    /// has released its stream (whose `onTermination` calls `libvlc_log_unset`),
    /// and an `ObjectIdentifier` of a freed object can only collide with a new
    /// instance allocated at the same address — which would merely skip a second
    /// subscription for a stream that is already being consumed. The set holds at
    /// most one entry per distinct styling configuration used in a session.
    @MainActor
    private static var installedInstances: Set<ObjectIdentifier> = []

    private static func consume(_ stream: AsyncStream<LogEntry>) {
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
            for await entry in stream {
                if entry.level >= .warning {
                    let module = entry.module ?? "?"
                    let message = LogScrubber.scrubbed(entry.message)
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
    }

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

    // Token scrubbing lives in `LogScrubber` (Shared/Diagnostics), the SSOT
    // shared with the diagnostics export — never re-implement it here.
}

/// Owns ONE libVLC instance together with its player.
///
/// It exists because SwiftVLC keeps `Player.instance` internal to its own
/// module: the app cannot ask a player which instance it runs on, and
/// `VLCEngineLog.install(on:)` needs exactly that. Creating both here also means
/// the log bridge can never be forgotten — it is installed in this initialiser,
/// beside the instance it belongs to.
///
/// **RULE — no styling ⇒ `VLCInstance.shared`.** `SubtitleStyleOptions`
/// deliberately emits no arguments while the user has changed nothing, and this
/// initialiser turns that into "reuse the shared instance", so the default path
/// pays neither libVLC's plugin scan nor a second log subscription. A failed
/// instance creation also falls back to the shared one: losing a styling
/// preference is an acceptable outcome, losing playback is not.
@MainActor
final class StyledVLCEngine {
    let instance: VLCInstance
    let player: Player

    init(style: SubtitleStyleOptions = .current()) {
        let arguments = style.libVLCArguments
        if arguments.isEmpty {
            instance = .shared
        } else {
            instance = (try? VLCInstance(arguments: VLCInstance.defaultArguments + arguments)) ?? .shared
        }
        player = Player(instance: instance)
        VLCEngineLog.install(on: instance)
    }
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
