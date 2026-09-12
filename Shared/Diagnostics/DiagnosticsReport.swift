import Foundation
import OSLog
import CinemaxKit

// MARK: - Last playback negotiation

/// What the most recent media open negotiated, kept so an exported report can
/// answer "how did that film play?" without a Mac attached. The equivalent log
/// lines (`CINEMAX-PLAYBACK`, `iOS play: …`) are `#if DEBUG` and never exist in
/// a TestFlight build, and the proxy route was not logged at all.
struct PlaybackSnapshot: Sendable, Equatable {
    enum Route: String, Sendable {
        case direct
        case proxy
    }

    let engine: String          // "vlc" | "native"
    let playMethod: String      // `PlayMethod.rawValue`
    let container: String?      // server-reported source container (DirectPlay/DirectStream only)
    let route: Route?           // VLC only — the AVPlayer path has no loopback proxy
    let openedAt: Date
}

/// Process-lifetime holder of the last `PlaybackSnapshot`. Written by the two
/// presenters at the point they hand a URL to their engine (every fresh open,
/// retry, episode swap and wake re-resolve), read by the export.
@MainActor
enum PlaybackDiagnostics {
    private(set) static var last: PlaybackSnapshot?

    static func record(engine: String, playMethod: PlayMethod, container: String?, route: PlaybackSnapshot.Route?) {
        last = PlaybackSnapshot(
            engine: engine, playMethod: playMethod.rawValue,
            container: container, route: route, openedAt: Date()
        )
    }
}

// MARK: - Report

/// Everything the export header states. Assembled in two halves: the caller
/// (main actor) supplies what only the app state knows — server version,
/// engine setting, last playback — and `DiagnosticsExporter` fills in the
/// window, counts and timestamp once it has read the log.
struct DiagnosticsFacts: Sendable, Equatable {
    var generatedAt: Date
    var appVersion: String
    var appBuild: String
    var deviceModel: String
    var osDescription: String
    /// `nil` ⇒ the client has not learned it yet (every cold launch starts so).
    var serverVersion: String?
    var engine: String
    var lastPlayback: PlaybackSnapshot?
    var logWindowMinutes: Int
    var logEntryCount: Int
    /// `nil` ⇒ MetricKit does not exist on this platform (tvOS).
    var metricKit: MetricKitSummary?

    /// The app-state half, with the device facts every report carries.
    static func current(serverVersion: String?, engine: String, lastPlayback: PlaybackSnapshot?) -> DiagnosticsFacts {
        DiagnosticsFacts(
            generatedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            deviceModel: DiagnosticsEnvironment.deviceModel,
            osDescription: DiagnosticsEnvironment.osDescription,
            serverVersion: serverVersion,
            engine: engine,
            lastPlayback: lastPlayback,
            logWindowMinutes: 0,
            logEntryCount: 0,
            metricKit: nil
        )
    }
}

/// The export's text. Deliberately NOT localized: it is read by whoever
/// debugs the report and grepped by key, so `server_version:` must read the
/// same whatever language the tester's phone runs in. Every line goes through
/// `LogScrubber` here — the one place the document is assembled — so no
/// caller can forget to.
enum DiagnosticsReport {
    static let title = "# Cinemax diagnostics"

    static func header(_ facts: DiagnosticsFacts) -> [String] {
        [
            title,
            "generated_at: \(timestamp(facts.generatedAt))",
            "app_version: \(facts.appVersion) (\(facts.appBuild))",
            "device: \(facts.deviceModel)",
            "os: \(facts.osDescription)",
            "server_version: \(facts.serverVersion ?? "unknown")",
            "playback_engine: \(facts.engine)",
            "last_playback: \(describe(facts.lastPlayback))",
            "log_window: last \(facts.logWindowMinutes) min of this launch, subsystem \(DiagnosticsLogCollector.subsystem), \(facts.logEntryCount) entries",
            "metrickit: \(describe(facts.metricKit))",
        ]
    }

    static func describe(_ snapshot: PlaybackSnapshot?) -> String {
        guard let snapshot else { return "none this launch" }
        return [
            timestamp(snapshot.openedAt),
            "engine=\(snapshot.engine)",
            "method=\(snapshot.playMethod)",
            "container=\(snapshot.container ?? "n/a")",
            "route=\(snapshot.route?.rawValue ?? "n/a")",
        ].joined(separator: " ")
    }

    static func describe(_ summary: MetricKitSummary?) -> String {
        guard let summary else { return "unavailable on this platform" }
        return "\(summary.diagnosticFiles) diagnostic payload(s) (crashes \(summary.crashes), hangs \(summary.hangs)), "
            + "\(summary.metricFiles) metric payload(s)"
    }

    /// The whole file. Scrubbing is per LINE (and per payload), never over the
    /// joined document: the scrubber re-searches every marker from its last
    /// hit, so one pass over a megabyte of log with many hits would be
    /// quadratic, while per-line it stays linear.
    static func document(
        facts: DiagnosticsFacts,
        logLines: [String],
        logNote: String? = nil,
        payloads: [(name: String, body: String)] = []
    ) -> String {
        var out = header(facts).map(LogScrubber.scrubbed)
        out.append("")
        out.append("== LOG (oldest first) ==")
        if let logNote { out.append(LogScrubber.scrubbed(logNote)) }
        if logLines.isEmpty && logNote == nil { out.append("(no entries)") }
        out.append(contentsOf: logLines.map(LogScrubber.scrubbed))
        for payload in payloads {
            out.append("")
            out.append("== METRICKIT \(payload.name) ==")
            out.append(LogScrubber.scrubbed(payload.body))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// ISO 8601, UTC, milliseconds. `ISO8601FormatStyle` rather than
    /// `ISO8601DateFormatter`, which is not `Sendable` (see `SyncPlayDateParser`).
    static func timestamp(_ date: Date) -> String {
        date.formatted(timestampStyle)
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

// MARK: - Device facts

enum DiagnosticsEnvironment {
    /// `iPhone17,1`-style hardware identifier (what crash reports name), or
    /// the simulated one plus a marker on the simulator, where `uname` would
    /// only say `arm64`.
    static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var osDescription: String {
        #if os(tvOS)
        let name = "tvOS"
        #else
        let name = "iOS"
        #endif
        return "\(name) \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

// MARK: - Log collection

/// Reads back this process's own `com.cinemax` OSLog entries.
///
/// `OSLogStore(scope: .currentProcessIdentifier)` sees THIS LAUNCH only — a
/// crash takes its log with it, which is what the MetricKit half of the export
/// is for. Measured on the iOS 26.5 simulator (device not yet checked): it
/// returns debug and info entries too, and interpolations logged WITHOUT
/// `privacy: .public` come back IN CLEAR — the in-process reader is not subject
/// to the `<private>` redaction a Console capture shows. Log privacy levels
/// therefore do not keep a secret out of the export; `LogScrubber`, applied to
/// every line by `DiagnosticsReport.document`, does (`DiagnosticsTests` locks a
/// token logged through a private interpolation).
enum DiagnosticsLogCollector {
    static let subsystem = "com.cinemax"
    /// Newest lines kept when a window is unusually chatty; bounds the file.
    static let maxLines = 10_000

    static func collect(since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: start)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        var lines: [String] = []
        for entry in try store.getEntries(at: position, matching: predicate) {
            guard let log = entry as? OSLogEntryLog, log.date >= start else { continue }
            lines.append(format(date: log.date, category: log.category, level: log.level, message: log.composedMessage))
        }
        return lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
    }

    static func format(date: Date, category: String, level: OSLogEntryLog.Level, message: String) -> String {
        "\(DiagnosticsReport.timestamp(date)) [\(category)] \(label(for: level)) \(message)"
    }

    static func label(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:  "DEBUG"
        case .info:   "INFO"
        case .notice: "NOTICE"
        case .error:  "ERROR"
        case .fault:  "FAULT"
        case .undefined: "-"
        @unknown default: "?"
        }
    }
}

// MARK: - Export

/// Builds the shareable `.txt`. Runs off the main actor: enumerating the log
/// store and writing the file both block.
enum DiagnosticsExporter {
    static let logWindowMinutes = 30

    struct Result: Sendable, Equatable {
        let url: URL
        let logLineCount: Int
    }

    static func export(facts: DiagnosticsFacts) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try build(facts: facts)
        }.value
    }

    static func build(
        facts: DiagnosticsFacts,
        now: Date = Date(),
        metricKitDirectory: URL? = DiagnosticsStore.defaultDirectory(),
        outputDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    ) throws -> Result {
        let since = now.addingTimeInterval(-Double(logWindowMinutes) * 60)
        var lines: [String] = []
        var note: String?
        do {
            lines = try DiagnosticsLogCollector.collect(since: since)
        } catch {
            // A report without its log still carries the header and the
            // MetricKit payloads — better than no report at all.
            note = "(log store unavailable: \(error.localizedDescription))"
        }

        var complete = facts
        complete.generatedAt = now
        complete.logWindowMinutes = logWindowMinutes
        complete.logEntryCount = lines.count
        var payloads: [(name: String, body: String)] = []
        #if os(iOS)
        complete.metricKit = DiagnosticsStore.summary(in: metricKitDirectory)
        payloads = DiagnosticsStore.storedPayloads(in: metricKitDirectory)
        #endif

        let text = DiagnosticsReport.document(facts: complete, logLines: lines, logNote: note, payloads: payloads)
        let fm = FileManager.default
        // One report at a time: a previous export is superseded, not kept.
        try? fm.removeItem(at: outputDirectory)
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent(fileName(for: now))
        try Data(text.utf8).write(to: url, options: .atomic)
        return Result(url: url, logLineCount: lines.count)
    }

    /// `cinemax-diagnostics-20260911T101500123Z.txt`
    static func fileName(for date: Date) -> String {
        "cinemax-diagnostics-\(MetricKitFileName.stamp(for: date)).txt"
    }
}
