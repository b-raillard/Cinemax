import SwiftUI
import CinemaxKit

/// The aired episodes the season on screen lacks (series fiche, AFTER the
/// owned episodes — the Seerr RULE): one dashed line each, then « Signaler »
/// for an account that may report a problem. Seerr cannot REQUEST them (a
/// partly available season is refused, and it has no per-episode request),
/// so nothing here is a request.
struct MediaDetailMissingEpisodesBlock: View, Equatable {
    let episodes: [SeerrMissingEpisode]
    let canReport: Bool
    let isReported: Bool
    let onReport: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.episodes == rhs.episodes && lhs.canReport == rhs.canReport && lhs.isReported == rhs.isReported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            Text(loc.counted("seerr.episodes.missing", episodes.count))
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurface)
                .accessibilityAddTraits(.isHeader)
            ForEach(episodes) { episode in
                row(episode)
            }
            if isReported {
                Label(loc.localized("seerr.episodes.reported"), systemImage: "checkmark.circle.fill")
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(themeManager.accent)
                    .padding(.top, CinemaSpacing.spacing1)
            } else if canReport {
                CinemaButton(
                    title: loc.counted("seerr.episodes.report", episodes.count),
                    style: .ghost, icon: "flag", wrapsTitle: true, action: onReport
                )
                .padding(.top, CinemaSpacing.spacing1)
            }
        }
    }

    private func row(_ episode: SeerrMissingEpisode) -> some View {
        HStack(spacing: CinemaSpacing.spacing3) {
            Text(Self.title(episode))
                .font(CinemaFont.dynamicBody)
                .foregroundStyle(CinemaColor.onSurface)
                .multilineTextAlignment(.leading)
            Spacer(minLength: CinemaSpacing.spacing2)
            Text(loc.localized("seerr.episodes.missing.row"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(CinemaSpacing.spacing3)
        .overlay {
            RoundedRectangle(cornerRadius: CinemaRadius.large)
                .strokeBorder(CinemaColor.onSurfaceMuted, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
        .accessibilityElement(children: .combine)
    }

    /// « 8. Les Disparus », or « 8 » while TMDb has no name.
    nonisolated static func title(_ episode: SeerrMissingEpisode) -> String {
        episode.name.isEmpty ? String(episode.episodeNumber) : "\(episode.episodeNumber). \(episode.name)"
    }
}

/// The report to send: which episodes of which season.
struct SeerrEpisodeReportDraft: Identifiable, Equatable {
    let episodes: [SeerrMissingEpisode]
    var id: String { episodes.first?.id ?? "" }

    /// What Seerr's issue says — the numbers, then the user's own word.
    @MainActor
    static func message(numbers: [Int], note: String, loc: LocalizationManager) -> String {
        let list = numbers.sorted().map(String.init).joined(separator: ", ")
        let lead = loc.localized("seerr.episodes.report.message", list)
        let word = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return word.isEmpty ? lead : "\(lead)\n\(word)"
    }
}

/// Presents the report: a sheet on iOS, a confirmation on tvOS.
struct SeerrEpisodeReportPresentation: ViewModifier {
    @Binding var draft: SeerrEpisodeReportDraft?
    let loc: LocalizationManager
    let onSend: (_ episodes: [SeerrMissingEpisode], _ note: String) async -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.confirmationDialog(
            loc.counted("seerr.episodes.report.confirm", draft?.episodes.count ?? 0),
            isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } }),
            titleVisibility: .visible,
            presenting: draft
        ) { current in
            Button(loc.localized("seerr.episodes.report.send")) {
                Task { await onSend(current.episodes, "") }
            }
            Button(loc.localized("action.cancel"), role: .cancel) {}
        } message: { _ in
            Text(loc.localized("seerr.episodes.report.note"))
        }
        #else
        content.sheet(item: $draft) { current in
            SeerrEpisodeReportSheet(draft: current, onSend: onSend)
        }
        #endif
    }
}

#if os(iOS)
/// « Signaler des épisodes manquants »: tick the episodes, an optional word
/// for the admin, one send. Never a request (the note says so).
struct SeerrEpisodeReportSheet: View {
    let draft: SeerrEpisodeReportDraft
    let onSend: (_ episodes: [SeerrMissingEpisode], _ note: String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    @State private var selection: Set<Int>
    @State private var note = ""
    @State private var sending = false

    init(draft: SeerrEpisodeReportDraft, onSend: @escaping ([SeerrMissingEpisode], String) async -> Void) {
        self.draft = draft
        self.onSend = onSend
        _selection = State(initialValue: Set(draft.episodes.map(\.episodeNumber)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                    VStack(spacing: CinemaSpacing.spacing2) {
                        ForEach(draft.episodes) { episode in
                            tickRow(episode)
                        }
                    }
                    GlassTextField(
                        label: loc.localized("seerr.episodes.report.word"), text: $note,
                        placeholder: loc.localized("seerr.episodes.report.placeholder"))
                    Text(loc.localized("seerr.episodes.report.note"))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                    CinemaButton(
                        title: loc.localized("seerr.episodes.report.send"), style: .accent, isLoading: sending
                    ) { send() }
                    .disabled(selection.isEmpty || sending)
                }
                .padding(CinemaSpacing.spacing4)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(loc.localized("seerr.episodes.report.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.localized("action.cancel")) { dismiss() }.tint(themeManager.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        guard !sending else { return }
        sending = true
        let chosen = draft.episodes.filter { selection.contains($0.episodeNumber) }
        Task {
            await onSend(chosen, note)
            sending = false
            dismiss()
        }
    }

    private func tickRow(_ episode: SeerrMissingEpisode) -> some View {
        let isOn = selection.contains(episode.episodeNumber)
        return Button {
            if isOn { selection.remove(episode.episodeNumber) } else { selection.insert(episode.episodeNumber) }
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                    .foregroundStyle(isOn ? themeManager.accent : CinemaColor.onSurfaceMuted)
                    .accessibilityHidden(true)
                Text(MediaDetailMissingEpisodesBlock.title(episode))
                    .font(CinemaFont.dynamicBody)
                    .foregroundStyle(CinemaColor.onSurface)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(CinemaSpacing.spacing3)
            .glassPanel()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
#endif
