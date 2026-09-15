import Foundation
import OSLog
import CinemaxKit

private let logger = Logger(subsystem: "com.cinemax", category: "Diagnostics")

/// The floor between two uploads, at file scope so the pure `shouldUpload` can
/// carry it as a default argument without naming its own type — and so a test
/// can pass a different one explicitly.
private let diagnosticsUploadFloor: TimeInterval = 300

/// Sends a diagnostic document to the user's OWN Jellyfin server when the app
/// hits a fault nobody would otherwise be able to report.
///
/// **The problem it solves is delivery, not logging.** The player already
/// writes everything worth knowing to OSLog — but the diagnostics EXPORT is
/// iOS-only (tvOS has neither a share sheet nor MetricKit), so on an Apple TV
/// those lines are written where no one can reach them. A log nobody can read
/// is not a diagnostic. Jellyfin has accepted client-side documents since 10.7
/// (`POST /ClientLog/Document`); they land in the server's own log directory and
/// `GET /System/Logs` lists them, so the person who owns the server can fetch
/// the file — or hand it over — without pairing anything to a Mac.
///
/// **Never on the happy path.** The only callers are faults: the picture-stall
/// recovery and the case where its budget is spent, an open that outlives its
/// watchdog, and the terminal « Lecture impossible ». The upload is throttled
/// per reason on top of that, so even a pathological loop cannot fill someone's
/// log directory, and it is fire-and-forget — a diagnostic must never be able to
/// delay, or break, the recovery it is describing.
///
/// **Consent lives server-side, which is where it belongs**: an administrator
/// who turns `AllowClientLogUpload` off gets a 403 and nothing is stored. The
/// document carries what the manual export carries — scrubbed of tokens by
/// `DiagnosticsReport.document`, but otherwise including titles and user names —
/// onto a server the user administers.
@MainActor
enum DiagnosticsUploader {
    /// Shorter than the manual export's 30 min: the fault has just happened, so
    /// the minutes before it are what matters, and the document travels into
    /// somebody's log directory rather than onto their own disk.
    nonisolated static let logWindowMinutes = 10

    /// The floor between two uploads of the SAME reason in one process. The
    /// stall detector is already bounded to 2 recoveries, but it is not the only
    /// caller, and the cost of being wrong here is paid by the user's server.
    ///
    /// Per reason, not global: one failed open produces an `open-timeout` at the
    /// watchdog and, a retry later, a `playback-failed` — a single floor would
    /// throttle the second, which is the one that says how the retry went.
    nonisolated static let minimumInterval: TimeInterval = diagnosticsUploadFloor

    /// The full client, injected once at the app root.
    ///
    /// **RULE — this seam exists because the presenters hold a NARROWED slice**
    /// (`any LibraryAPI & PlaybackAPI`), on purpose: a leaf controller does not
    /// get the whole API surface, which is what keeps `AdminAPI` and the rest
    /// out of a video player's reach. Widening the player's type just so it
    /// could call one server-wide route would undo exactly the narrowing the
    /// slice split exists for — so the channel is injected instead, the same
    /// shape `AppNavigation.sharedAppState` takes for headless contexts.
    ///
    /// `nil` ⇒ nothing is ever sent, which is also what every test gets by
    /// default: a suite has to opt in before anything could leave the process.
    static var client: (any ServerAPI)?

    private static var lastUploadAt: [String: Date] = [:]

    /// Pure, so the throttle is testable without a server or a clock.
    nonisolated static func shouldUpload(
        last: Date?,
        now: Date,
        minimumInterval: TimeInterval = diagnosticsUploadFloor
    ) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= minimumInterval
    }

    /// The same floor, kept per reason.
    nonisolated static func shouldUpload(
        reason: String,
        history: [String: Date],
        now: Date,
        minimumInterval: TimeInterval = diagnosticsUploadFloor
    ) -> Bool {
        shouldUpload(last: history[reason], now: now, minimumInterval: minimumInterval)
    }

    /// Fire-and-forget. Reads the app-state facts on the main actor, then hands
    /// a `Sendable` snapshot to a detached task — enumerating the log store
    /// blocks, and this is called from the player's 1 s heartbeat.
    static func send(reason: String, engine: String, now: Date = Date()) {
        guard let client else { return }
        guard shouldUpload(reason: reason, history: lastUploadAt, now: now) else {
            logger.debug("diagnostics upload skipped (throttled: \(reason, privacy: .public))")
            return
        }
        lastUploadAt[reason] = now
        let facts = DiagnosticsFacts.current(
            serverVersion: client.knownServerVersion()?.description,
            engine: engine,
            lastPlayback: PlaybackDiagnostics.last,
            reason: reason
        )
        Task.detached(priority: .utility) {
            let document = buildDocument(facts: facts)
            _ = await client.uploadDiagnostics(document)
        }
    }

    /// The same document the manual export writes, minus the MetricKit payloads
    /// (iOS-only, and a fault that just happened is not in one) and over a
    /// shorter window. Scrubbing stays where it has always been — inside
    /// `DiagnosticsReport.document`, the single point no caller can forget.
    nonisolated static func buildDocument(facts: DiagnosticsFacts, now: Date = Date()) -> String {
        var lines: [String] = []
        var note: String?
        do {
            lines = try DiagnosticsLogCollector.collect(
                since: now.addingTimeInterval(-Double(logWindowMinutes) * 60)
            )
        } catch {
            // A document without its log still carries the header — which names
            // the app version, the device, the engine and the last playback —
            // and that is far better than sending nothing.
            note = "(log store unavailable: \(error.localizedDescription))"
        }
        var complete = facts
        complete.generatedAt = now
        complete.logWindowMinutes = logWindowMinutes
        complete.logEntryCount = lines.count
        return DiagnosticsReport.document(facts: complete, logLines: lines, logNote: note)
    }
}
