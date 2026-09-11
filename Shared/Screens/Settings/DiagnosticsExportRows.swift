#if os(iOS)
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.cinemax", category: "Diagnostics")

/// Settings → Lecture → Débogage (iOS): export this launch's last 30 minutes of
/// `com.cinemax` log plus the stored MetricKit payloads as one `.txt`, and show
/// how many MetricKit reports the device holds.
///
/// Two steps — prepare, then share — on purpose. `ShareLink` needs its item up
/// front, and reading the log store takes a visible moment; a lazily-built
/// `Transferable` would hide that wait inside the share sheet with no feedback,
/// and the ready row is where the tester sees how much is about to be sent.
/// Nothing leaves the device until they pick a destination in the share sheet.
///
/// A standalone `View` (own `@State` + `@Environment`) rather than a
/// `SettingsScreen` extension: the Playback page is pushed through
/// `navigationDestination`, where only a standalone view re-renders on its own
/// state (see the iOS `NavigationStack` RULE).
struct DiagnosticsExportRows: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalizationManager.self) private var loc
    @AppStorage(SettingsKey.forceNativeAVPlayer) private var forceNativeAVPlayer: Bool = SettingsKey.Default.forceNativeAVPlayer

    private enum Phase: Equatable {
        case idle
        case preparing
        case ready(URL, lines: Int)
        case failed
    }

    @State private var phase: Phase = .idle
    @State private var summary = MetricKitSummary()

    var body: some View {
        VStack(spacing: 0) {
            exportRow
            iOSSettingsDivider
            metricKitRow
        }
        .task { summary = await Self.loadSummary() }
        // A revisit re-reads the log instead of re-sharing a stale file.
        .onDisappear { if phase != .preparing { phase = .idle } }
    }

    // MARK: Rows

    @ViewBuilder
    private var exportRow: some View {
        switch phase {
        case .ready(let url, let lines):
            ShareLink(item: url) {
                rowContent(
                    icon: "square.and.arrow.up",
                    title: loc.localized("settings.debug.exportDiagnostics.share"),
                    subtitle: loc.localized("settings.debug.exportDiagnostics.ready", lines)
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: CinemaScale.pt(13), weight: .semibold))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
            }
            .buttonStyle(.plain)
        default:
            Button(action: prepare) {
                rowContent(
                    icon: "doc.text.magnifyingglass",
                    title: loc.localized("settings.debug.exportDiagnostics"),
                    subtitle: exportSubtitle
                ) {
                    if phase == .preparing { ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(phase == .preparing)
        }
    }

    private var exportSubtitle: String {
        switch phase {
        case .preparing: loc.localized("settings.debug.exportDiagnostics.preparing")
        case .failed:    loc.localized("settings.debug.exportDiagnostics.failed")
        default:         loc.localized("settings.debug.exportDiagnostics.subtitle")
        }
    }

    private var metricKitRow: some View {
        rowContent(
            icon: "exclamationmark.triangle",
            title: loc.localized("settings.debug.metricKit"),
            subtitle: summary.isEmpty
                ? loc.localized("settings.debug.metricKit.none")
                : loc.localized("settings.debug.metricKit.summary", summary.crashes, summary.hangs, summary.metricFiles)
        ) { EmptyView() }
            .accessibilityElement(children: .combine)
    }

    private func rowContent<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        iOSSettingsRow {
            HStack {
                iOSRowIcon(systemName: icon, color: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CinemaFont.dynamicLabel(.large))
                        .foregroundStyle(CinemaColor.onSurface)
                    Text(subtitle)
                        .font(CinemaFont.dynamicLabel(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                }
                Spacer()
                trailing()
            }
        }
        // A full-width row label draws nothing under its `Spacer` — without a
        // shape only the text would take the tap (Image Patterns RULE).
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func prepare() {
        guard phase != .preparing else { return }
        phase = .preparing
        let facts = DiagnosticsFacts.current(
            serverVersion: appState.apiClient.knownServerVersion()?.description,
            engine: forceNativeAVPlayer ? "native" : "vlc",
            lastPlayback: PlaybackDiagnostics.last
        )
        Task {
            do {
                let result = try await DiagnosticsExporter.export(facts: facts)
                phase = .ready(result.url, lines: result.logLineCount)
                summary = await Self.loadSummary()
                Haptics.success()
            } catch {
                logger.error("Diagnostics export failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed
                Haptics.error()
            }
        }
    }

    private static func loadSummary() async -> MetricKitSummary {
        await Task.detached(priority: .utility) { DiagnosticsStore.summary() }.value
    }
}
#endif
