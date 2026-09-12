import Testing
import Foundation
import OSLog
@testable import Cinemax

// MARK: - Fixtures

private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, ms: Int = 500) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // 500 ms is exact in binary floating point; a value like 123 ms can
    // round-trip as 122.999… and truncate to the wrong stamp.
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second,
        nanosecond: ms * 1_000_000
    ))!
}

private func diagnosticName(second: Int, crashes: Int = 0, hangs: Int = 0) -> String {
    MetricKitFileName(date: utcDate(2026, 9, 11, 10, 0, second), nonce: "n\(second)", kind: .diagnostic, crashes: crashes, hangs: hangs).fileName
}

private func metricsName(second: Int) -> String {
    MetricKitFileName(date: utcDate(2026, 9, 11, 10, 0, second), nonce: "m\(second)", kind: .metrics).fileName
}

// MARK: - Scrubber: the markers the export adds

/// The export hands the app's own log lines to whoever the tester shares the
/// file with. Beyond the `ApiKey`/`api_key` query forms (locked in
/// `VLCEngineLogTests`), a token can travel in an Authorization header or an
/// `X-Emby-Token` — both must come out masked.
@Suite("LogScrubber — header and quoted forms")
struct LogScrubberExportMarkerTests {

    @Test("MediaBrowser Authorization header: only the Token value is masked")
    func mediaBrowserHeader() {
        let scrubbed = LogScrubber.scrubbed(
            #"Authorization: MediaBrowser Client="Cinemax", Device="iPhone", DeviceId="dev-1", Version="2.0.0", Token="s3cr3t""#
        )
        #expect(scrubbed == #"Authorization: MediaBrowser Client="Cinemax", Device="iPhone", DeviceId="dev-1", Version="2.0.0", Token="***""#)
        #expect(!scrubbed.contains("s3cr3t"))
    }

    @Test("X-Emby-Token / X-MediaBrowser-Token header forms, with or without a space")
    func headerForms() {
        #expect(LogScrubber.scrubbed("X-Emby-Token: abc123 next") == "X-Emby-Token: *** next")
        #expect(LogScrubber.scrubbed("x-mediabrowser-token:abc123") == "x-mediabrowser-token:***")
    }

    @Test("token query items: X-Emby-Token=, access_token=")
    func tokenQueryItems() {
        #expect(LogScrubber.scrubbed("GET /Items?X-Emby-Token=abc&Limit=5") == "GET /Items?X-Emby-Token=***&Limit=5")
        #expect(LogScrubber.scrubbed("cb?access_token=abc#frag") == "cb?access_token=***#frag")
    }

    @Test("an unquoted Token value stops at the comma of the next field")
    func unquotedTokenStopsAtComma() {
        #expect(LogScrubber.scrubbed("Token=abc, Version=2") == "Token=***, Version=2")
    }

    @Test("a quoted value runs to its matching quote, and no further than the line")
    func quotedValues() {
        #expect(LogScrubber.scrubbed("token='abc def' tail") == "token='***' tail")
        #expect(LogScrubber.scrubbed("Token=\"abc\nnext line") == "Token=\"***\nnext line")
        #expect(LogScrubber.scrubbed("api_key=\"abc\"&x=1") == "api_key=\"***\"&x=1")
    }

    @Test("text that merely mentions tokens is left alone")
    func mentionsAreUntouched() {
        let message = "session tokens are refreshed on foreground"
        #expect(LogScrubber.scrubbed(message) == message)
    }
}

// MARK: - File names (retention metadata)

@Suite("MetricKitFileName")
struct MetricKitFileNameTests {

    @Test("stamp is fixed-width UTC with milliseconds")
    func stampFormat() {
        #expect(MetricKitFileName.stamp(for: utcDate(2026, 9, 11, 10, 15, 0)) == "20260911T101500500Z")
    }

    @Test("a diagnostic name round-trips with its counts")
    func diagnosticRoundTrip() {
        let name = MetricKitFileName(date: utcDate(2026, 9, 11, 10, 15, 0), nonce: "abcd1234", kind: .diagnostic, crashes: 2, hangs: 1)
        #expect(name.fileName == "20260911T101500500Z-abcd1234-diagnostic-c2-h1.json")
        #expect(MetricKitFileName(parsing: name.fileName) == name)
    }

    @Test("a metrics name round-trips and carries no counts")
    func metricsRoundTrip() {
        let name = MetricKitFileName(date: utcDate(2026, 9, 11, 10, 15, 0), nonce: "ffff0000", kind: .metrics, crashes: 3, hangs: 3)
        #expect(name.fileName == "20260911T101500500Z-ffff0000-metrics.json")
        #expect(name.crashes == 0 && name.hangs == 0)
        #expect(MetricKitFileName(parsing: name.fileName) == name)
    }

    @Test("names the store did not write are rejected")
    func foreignNames() {
        for name in [
            "notes.txt",
            "20260911T101500500Z-abcd-crash.json",
            "2026-abcd-metrics.json",
            "20260911T101500500Z--metrics.json",
            "20260911T101500500Z-abcd-diagnostic.json",
            "20260911T101500500Z-abcd-diagnostic-c-1-h0.json",
            "20260911T101500500Z-abcd-metrics-extra.json",
        ] {
            #expect(MetricKitFileName(parsing: name) == nil, "\(name)")
        }
    }
}

// MARK: - Retention + summary

@Suite("DiagnosticsStore retention")
struct DiagnosticsStoreRetentionTests {

    @Test("each kind keeps its newest 10; only the oldest excess goes")
    func keepsNewestPerKind() {
        let diagnostics = (0..<12).map { diagnosticName(second: $0) }
        let metrics = (0..<3).map { metricsName(second: $0) }
        let doomed = DiagnosticsStore.namesToPrune((diagnostics + metrics).shuffled())
        #expect(Set(doomed) == Set(diagnostics.prefix(2)))
    }

    @Test("routine metric payloads cannot evict a crash report")
    func metricsDoNotEvictCrashes() {
        let crash = diagnosticName(second: 0, crashes: 1)
        let metrics = (1...11).map { metricsName(second: $0) }
        let doomed = DiagnosticsStore.namesToPrune(metrics + [crash])
        #expect(doomed == [metrics[0]])
    }

    @Test("files the store did not write are never pruned")
    func foreignFilesSurvive() {
        let names = ["README.txt", "export.json"] + (0..<12).map { diagnosticName(second: $0) }
        let doomed = DiagnosticsStore.namesToPrune(names, maxPerKind: 0)
        #expect(!doomed.contains("README.txt") && !doomed.contains("export.json"))
        #expect(doomed.count == 12)
    }

    @Test("summary sums crashes and hangs over diagnostic payloads and ignores foreign files")
    func summaryCounts() {
        let names = [
            diagnosticName(second: 1, crashes: 2, hangs: 0),
            diagnosticName(second: 2, crashes: 0, hangs: 3),
            metricsName(second: 3),
            metricsName(second: 4),
            "stray.json",
        ]
        #expect(DiagnosticsStore.summary(of: names) == MetricKitSummary(diagnosticFiles: 2, crashes: 2, hangs: 3, metricFiles: 2))
        #expect(DiagnosticsStore.summary(of: []).isEmpty)
    }

    @Test("persist writes into the directory and enforces the cap on disk")
    func persistEnforcesCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for second in 0..<12 {
            DiagnosticsStore.persist(Data("{\"n\":\(second)}".utf8), kind: .diagnostic, crashes: 1, date: utcDate(2026, 9, 11, 10, 0, second), in: dir)
        }
        let stored = DiagnosticsStore.storedFileNames(in: dir)
        #expect(stored.count == DiagnosticsStore.maxFilesPerKind)
        // The two oldest (seconds 0 and 1) are the ones that went.
        #expect(stored.first?.hasPrefix(MetricKitFileName.stamp(for: utcDate(2026, 9, 11, 10, 0, 2))) == true)
        #expect(DiagnosticsStore.summary(in: dir).crashes == 10)
        let bodies = DiagnosticsStore.storedPayloads(in: dir).map(\.body)
        #expect(bodies.first == "{\"n\":2}" && bodies.last == "{\"n\":11}")
    }
}

// MARK: - Report text

@Suite("DiagnosticsReport")
struct DiagnosticsReportTests {

    private func facts(
        server: String? = "12.0.0.0",
        playback: PlaybackSnapshot? = nil,
        metricKit: MetricKitSummary? = MetricKitSummary(diagnosticFiles: 1, crashes: 2, hangs: 1, metricFiles: 3)
    ) -> DiagnosticsFacts {
        DiagnosticsFacts(
            generatedAt: utcDate(2026, 9, 11, 10, 15, 0),
            appVersion: "2.0.0", appBuild: "42",
            deviceModel: "iPhone17,1", osDescription: "iOS Version 26.5 (Build 23F77)",
            serverVersion: server, engine: "vlc", lastPlayback: playback,
            logWindowMinutes: 30, logEntryCount: 412, metricKit: metricKit
        )
    }

    @Test("header states every fact on its own greppable key")
    func headerLines() {
        let playback = PlaybackSnapshot(
            engine: "vlc", playMethod: "DirectPlay", container: "mkv", route: .proxy,
            openedAt: utcDate(2026, 9, 11, 10, 12, 0)
        )
        #expect(DiagnosticsReport.header(facts(playback: playback)) == [
            "# Cinemax diagnostics",
            "generated_at: 2026-09-11T10:15:00.500Z",
            "app_version: 2.0.0 (42)",
            "device: iPhone17,1",
            "os: iOS Version 26.5 (Build 23F77)",
            "server_version: 12.0.0.0",
            "playback_engine: vlc",
            "last_playback: 2026-09-11T10:12:00.500Z engine=vlc method=DirectPlay container=mkv route=proxy",
            "log_window: last 30 min of this launch, subsystem com.cinemax, 412 entries",
            "metrickit: 1 diagnostic payload(s) (crashes 2, hangs 1), 3 metric payload(s)",
        ])
    }

    @Test("unknown server, no playback, no MetricKit read as such — never as blanks")
    func absentFacts() {
        let header = DiagnosticsReport.header(facts(server: nil, playback: nil, metricKit: nil))
        #expect(header.contains("server_version: unknown"))
        #expect(header.contains("last_playback: none this launch"))
        #expect(header.contains("metrickit: unavailable on this platform"))
        let native = PlaybackSnapshot(engine: "native", playMethod: "Transcode", container: nil, route: nil, openedAt: utcDate(2026, 9, 11, 10, 0, 0))
        #expect(DiagnosticsReport.describe(native).hasSuffix("engine=native method=Transcode container=n/a route=n/a"))
    }

    @Test("the document scrubs log lines AND MetricKit payloads")
    func documentScrubs() {
        let text = DiagnosticsReport.document(
            facts: facts(),
            logLines: ["t [API] NOTICE opening https://h/Videos/1/stream?ApiKey=leak1&static=true",
                       #"t [API] NOTICE header MediaBrowser Token="leak2""#],
            payloads: [("x-metrics.json", #"{"url":"https://h/a?api_key=leak3"}"#)]
        )
        for secret in ["leak1", "leak2", "leak3"] { #expect(!text.contains(secret), "\(secret)") }
        #expect(text.contains("== LOG (oldest first) =="))
        #expect(text.contains("== METRICKIT x-metrics.json =="))
    }

    @Test("an empty log says so, and a log-store failure is stated instead")
    func emptyAndFailedLog() {
        #expect(DiagnosticsReport.document(facts: facts(), logLines: []).contains("(no entries)"))
        let failed = DiagnosticsReport.document(facts: facts(), logLines: [], logNote: "(log store unavailable: boom)")
        #expect(failed.contains("(log store unavailable: boom)") && !failed.contains("(no entries)"))
    }

    @Test("log lines carry timestamp, category and level")
    func lineFormat() {
        let line = DiagnosticsLogCollector.format(date: utcDate(2026, 9, 11, 10, 0, 0), category: "libVLC", level: .error, message: "boom")
        #expect(line == "2026-09-11T10:00:00.500Z [libVLC] ERROR boom")
    }

    @Test("export file name is timestamped and a .txt")
    func exportFileName() {
        #expect(DiagnosticsExporter.fileName(for: utcDate(2026, 9, 11, 10, 15, 0)) == "cinemax-diagnostics-20260911T101500500Z.txt")
    }
}

// MARK: - The real log store, in-process

/// Proves the premise the export rests on: that `OSLogStore(scope:
/// .currentProcessIdentifier)` hands back this process's own `com.cinemax`
/// entries at all. The test host IS the app process, so this is the same read
/// the Settings row performs.
@Suite("DiagnosticsLogCollector — OSLogStore round-trip", .serialized)
struct DiagnosticsLogStoreRoundTripTests {
    private let logger = Logger(subsystem: DiagnosticsLogCollector.subsystem, category: "DiagnosticsTest")

    /// Entries can take a beat to become readable; poll briefly.
    private func collect(until marker: String, since: Date) async throws -> [String] {
        var lines: [String] = []
        for _ in 0..<20 {
            lines = try DiagnosticsLogCollector.collect(since: since)
            if lines.contains(where: { $0.contains(marker) }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return lines
    }

    @Test("a public notice logged by this process is read back, scrubbed in the export")
    func roundTrip() async throws {
        let start = Date().addingTimeInterval(-5)
        let marker = "diag-probe-\(UUID().uuidString.prefix(8))"
        let secret = "privsecret\(UUID().uuidString.prefix(6))"
        logger.notice("\(marker, privacy: .public) notice ApiKey=\("tokenleak", privacy: .public)")
        logger.info("\(marker, privacy: .public) info-level")
        logger.debug("\(marker, privacy: .public) debug-level")
        logger.notice("\(marker, privacy: .public) private=\(secret)")
        // In-process reads return private interpolations IN CLEAR (measured on
        // the simulator), so a token logged through one must still be scrubbed.
        let privateURL = "https://h/Videos/1/stream?ApiKey=privtoken\(secret)&static=true"
        logger.notice("\(marker, privacy: .public) opening \(privateURL)")

        let lines = try await collect(until: marker, since: start)
        let mine = lines.filter { $0.contains(marker) }
        // Informational: which levels / privacy the store actually returns on
        // this runtime (the export can only ever show what it keeps).
        print("DIAG-PROBE levels returned:", mine.map { $0.components(separatedBy: " ").dropFirst(2).first ?? "?" })
        print("DIAG-PROBE private interpolation came back as:", mine.first { $0.contains("private=") } ?? "(absent)")
        #expect(mine.contains { $0.contains("[DiagnosticsTest] NOTICE") && $0.contains("notice ApiKey=") })

        // And the full export built from that same store never carries the token.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("diag-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let facts = DiagnosticsFacts.current(serverVersion: nil, engine: "vlc", lastPlayback: nil)
        let result = try DiagnosticsExporter.build(facts: facts, metricKitDirectory: nil, outputDirectory: out)
        let text = try String(contentsOf: result.url, encoding: .utf8)
        print("DIAG-PROBE export head:\n" + text.components(separatedBy: "\n").prefix(12).joined(separator: "\n"))
        #expect(text.hasPrefix(DiagnosticsReport.title))
        #expect(text.contains(marker))
        #expect(!text.contains("tokenleak"))
        #expect(text.contains("opening https://h/Videos/1/stream?ApiKey=***&static=true"))
        #expect(!text.contains("privtoken"))
        #expect(result.logLineCount > 0)
    }
}
