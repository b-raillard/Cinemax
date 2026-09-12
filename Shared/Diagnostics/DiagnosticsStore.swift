import Foundation
import OSLog
#if os(iOS)
import MetricKit
#endif

private let logger = Logger(subsystem: "com.cinemax", category: "Diagnostics")

/// Counts shown in Settings → Lecture → Débogage and written into the export
/// header. `crashes` / `hangs` are summed over every stored diagnostic payload
/// (one payload can carry several of each).
struct MetricKitSummary: Sendable, Equatable {
    var diagnosticFiles = 0
    var crashes = 0
    var hangs = 0
    var metricFiles = 0

    var isEmpty: Bool { diagnosticFiles == 0 && metricFiles == 0 }
}

/// The name of one persisted MetricKit payload — and the only metadata the
/// store keeps about it.
///
/// The TIMESTAMP COMES FIRST so a plain lexicographic sort is chronological:
/// retention never has to read a file's modification date, which would be a
/// required-reason API (`NSPrivacyAccessedAPICategoryFileTimestamp`). The crash
/// and hang counts ride in the name for the same kind of reason: they come from
/// the TYPED payload at persist time, so the Settings count never depends on
/// the key names of Apple's `jsonRepresentation()`, which are undocumented.
struct MetricKitFileName: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case diagnostic
        case metrics
    }

    /// `yyyyMMdd'T'HHmmssSSS'Z'` in UTC — fixed width, no separator.
    let stamp: String
    /// Disambiguates two payloads persisted in the same millisecond (a
    /// callback delivers an ARRAY of payloads). Carries no ordering meaning.
    let nonce: String
    let kind: Kind
    let crashes: Int
    let hangs: Int

    static let stampLength = 19 // "20260911T101500123Z"

    init(date: Date, nonce: String, kind: Kind, crashes: Int = 0, hangs: Int = 0) {
        self.stamp = Self.stamp(for: date)
        self.nonce = nonce
        self.kind = kind
        self.crashes = kind == .diagnostic ? max(0, crashes) : 0
        self.hangs = kind == .diagnostic ? max(0, hangs) : 0
    }

    /// Parses a name this store wrote; `nil` for anything else, which the
    /// store then neither counts nor ever deletes.
    init?(parsing name: String) {
        guard name.hasSuffix(".json") else { return nil }
        let parts = name.dropLast(".json".count).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              parts[0].count == Self.stampLength, parts[0].hasSuffix("Z"),
              !parts[1].isEmpty,
              let kind = Kind(rawValue: parts[2]) else { return nil }
        switch kind {
        case .metrics:
            guard parts.count == 3 else { return nil }
            self.crashes = 0
            self.hangs = 0
        case .diagnostic:
            guard parts.count == 5,
                  parts[3].hasPrefix("c"), let crashes = Int(parts[3].dropFirst()), crashes >= 0,
                  parts[4].hasPrefix("h"), let hangs = Int(parts[4].dropFirst()), hangs >= 0 else { return nil }
            self.crashes = crashes
            self.hangs = hangs
        }
        self.stamp = parts[0]
        self.nonce = parts[1]
        self.kind = kind
    }

    var fileName: String {
        switch kind {
        case .metrics:    "\(stamp)-\(nonce)-metrics.json"
        case .diagnostic: "\(stamp)-\(nonce)-diagnostic-c\(crashes)-h\(hangs).json"
        }
    }

    /// Built from calendar components rather than a `DateFormatter`, which is
    /// neither `Sendable` nor cheap, and whose output a locale can bend.
    static func stamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%04d%02d%02dT%02d%02d%02d%03dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms
        )
    }
}

/// On-disk home of the MetricKit payloads: `Application Support/Diagnostics/`,
/// excluded from backups. Nothing here ever leaves the device on its own — the
/// only way out is the user sharing the export (`DiagnosticsExporter`).
///
/// Retention keeps the newest `maxFilesPerKind` of EACH kind, i.e. at most 20
/// files in all. Per kind rather than 20 overall because metric payloads arrive
/// daily and diagnostic ones (crashes, hangs) rarely: a shared cap would let
/// three weeks of routine metrics evict the one crash report that matters.
enum DiagnosticsStore {
    static let maxFilesPerKind = 10
    static let directoryName = "Diagnostics"

    static func defaultDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: Pure

    /// Which of `names` to delete so each kind keeps only its newest
    /// `maxPerKind`. Names this store did not write are never selected.
    static func namesToPrune(_ names: [String], maxPerKind: Int = maxFilesPerKind) -> [String] {
        let parsed = names.compactMap { name in MetricKitFileName(parsing: name).map { (name, $0) } }
        var doomed: [String] = []
        for kind in MetricKitFileName.Kind.allCases {
            let chronological = parsed.filter { $0.1.kind == kind }.map(\.0).sorted()
            let excess = chronological.count - max(0, maxPerKind)
            if excess > 0 { doomed += chronological.prefix(excess) }
        }
        return doomed
    }

    static func summary(of names: [String]) -> MetricKitSummary {
        var summary = MetricKitSummary()
        for name in names {
            guard let parsed = MetricKitFileName(parsing: name) else { continue }
            switch parsed.kind {
            case .diagnostic:
                summary.diagnosticFiles += 1
                summary.crashes += parsed.crashes
                summary.hangs += parsed.hangs
            case .metrics:
                summary.metricFiles += 1
            }
        }
        return summary
    }

    // MARK: File system

    /// Payload file names this store wrote, oldest first.
    static func storedFileNames(in directory: URL? = defaultDirectory()) -> [String] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { MetricKitFileName(parsing: $0) != nil }.sorted()
    }

    static func summary(in directory: URL? = defaultDirectory()) -> MetricKitSummary {
        summary(of: storedFileNames(in: directory))
    }

    /// Every stored payload as text, oldest first — the export's MetricKit
    /// sections. A payload that no longer reads as UTF-8 is skipped.
    static func storedPayloads(in directory: URL? = defaultDirectory()) -> [(name: String, body: String)] {
        guard let directory else { return [] }
        return storedFileNames(in: directory).compactMap { name in
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path),
                  let body = String(data: data, encoding: .utf8) else { return nil }
            return (name, body)
        }
    }

    /// Writes one payload, then enforces retention. Thread-safe enough for its
    /// only caller (MetricKit's background callbacks): `FileManager.default`
    /// is thread-safe, and two overlapping prunes can at worst try to remove
    /// the same file twice, which fails harmlessly.
    static func persist(
        _ data: Data,
        kind: MetricKitFileName.Kind,
        crashes: Int = 0,
        hangs: Int = 0,
        date: Date = Date(),
        in directory: URL? = defaultDirectory()
    ) {
        guard var directory else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            let nonce = String(UUID().uuidString.prefix(8)).lowercased()
            let name = MetricKitFileName(date: date, nonce: nonce, kind: kind, crashes: crashes, hangs: hangs).fileName
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            logger.notice("MetricKit ▸ payload stored: \(name, privacy: .public)")
        } catch {
            logger.error("MetricKit ▸ could not store a \(kind.rawValue, privacy: .public) payload: \(error.localizedDescription, privacy: .public)")
            return
        }
        for name in namesToPrune(storedFileNames(in: directory)) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

#if os(iOS)
/// Receives MetricKit's payloads and hands them to `DiagnosticsStore`.
/// iOS only: the tvOS SDK ships `MetricKit.framework` but marks every one of
/// its classes `API_UNAVAILABLE(tvos)`.
///
/// Payloads arrive at most once per 24 h, and only for builds the App Store
/// distributed (TestFlight included) — a debug build run from Xcode receives
/// nothing unless Xcode's *Debug → Simulate MetricKit Payloads* is used.
///
/// Both callbacks run on a background queue MetricKit owns — the off-main
/// framework-callback rule (see the voice-search RULE in CLAUDE.md). The class
/// is therefore NOT `@MainActor`, holds no mutable state (which is what lets it
/// be `Sendable`), and converts each non-`Sendable` payload to `Data`
/// synchronously, inside the callback, before anything else touches it.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = MetricKitSubscriber()

    /// Idempotent at the call site — `AppNavigation` runs it from a `static let`.
    static func register() {
        MXMetricManager.shared.add(shared)
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            DiagnosticsStore.persist(payload.jsonRepresentation(), kind: .metrics)
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            DiagnosticsStore.persist(
                payload.jsonRepresentation(),
                kind: .diagnostic,
                crashes: payload.crashDiagnostics?.count ?? 0,
                hangs: payload.hangDiagnostics?.count ?? 0
            )
        }
    }
}
#endif
