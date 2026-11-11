import SwiftUI
import CinemaxKit
import JellyfinAPI

/// One place in a season's episode list: an episode the server has, or one
/// it lacks (Seerr). The fiche draws both in the same row / carousel, the
/// missing ones at their place in the order (owner 2026-11-11, mockup A).
enum MediaDetailEpisodeSlot: Identifiable {
    case owned(BaseItemDto)
    case missing(SeerrMissingEpisode)

    var id: String {
        switch self {
        case .owned(let episode): "owned-" + (episode.id ?? "")
        case .missing(let episode): episode.id
        }
    }

    /// Pure: the owned episodes in the server's order, each missing episode
    /// slipped in before the first owned one with a higher number; the rest
    /// at the end. An owned episode without a number keeps its place.
    nonisolated static func interleave(owned: [BaseItemDto], missing: [SeerrMissingEpisode]) -> [Self] {
        let pending = missing.sorted { $0.episodeNumber < $1.episodeNumber }
        var next = 0
        var slots: [Self] = []
        slots.reserveCapacity(owned.count + pending.count)
        for episode in owned {
            if let number = episode.indexNumber {
                while next < pending.count, pending[next].episodeNumber < number {
                    slots.append(.missing(pending[next]))
                    next += 1
                }
            }
            slots.append(.owned(episode))
        }
        slots.append(contentsOf: pending[next...].map { .missing($0) })
        return slots
    }
}

/// What a missing episode looks like, on both platforms: the language of a
/// missing title in the search (`MissingTitleCard`) — its image under the same
/// dim, the same dashed outline — so « not on the server » reads at a glance.
enum MissingEpisodeLook {
    /// The search card's dim, unchanged.
    static let dim = CinemaColor.surfaceContainerLowest.opacity(0.62)

    /// The design system's one dashed outline (Shared/DesignSystem/CLAUDE.md).
    static func outline(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(CinemaColor.onSurfaceMuted, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
    }

    /// TMDb's still, dimmed; the bare surface when it has none.
    @MainActor
    static func still(_ url: URL?) -> some View {
        ZStack {
            CinemaColor.surfaceContainerLow
            if let url {
                CinemaLazyImage(url: url, fallbackIcon: nil, fallbackBackground: .clear)
            }
            dim
        }
        .accessibilityHidden(true)
    }

    /// « 8 mai 2011 », in the app's language; nil when the date is unreadable.
    /// Read AND written in GMT: a calendar day, not an instant — shown in the
    /// device's zone, « 8 mai » read « 7 mai » west of UTC.
    nonisolated static func airDate(_ raw: String?, locale: Locale) -> String? {
        guard let raw, let date = try? Date(raw, strategy: Date.ISO8601FormatStyle().year().month().day()) else {
            return nil
        }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().year().locale(locale)
        style.timeZone = .gmt
        return date.formatted(style)
    }
}

#if os(iOS)
/// A missing episode in the iPhone / iPad carousel, the size of the owned
/// cards beside it. Tapping it opens the report — only for an account that
/// may report (`onReport` nil otherwise, and the card is then not a button).
struct MediaDetailMissingEpisodeCard: View {
    let episode: SeerrMissingEpisode
    let stillURL: URL?
    let episodeTitleFontSize: CGFloat
    let onReport: (() -> Void)?

    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        if let onReport {
            Button(action: onReport) { content }
                .buttonStyle(.plain)
                .accessibilityHint(loc.localized("seerr.episodes.report.title"))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { MissingEpisodeLook.still(stillURL) }
                .overlay(alignment: .bottomLeading) {
                    Text(loc.localized("seerr.episodes.missing.row"))
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurface)
                        .padding(.horizontal, CinemaSpacing.spacing2)
                        .padding(.vertical, 5)
                        .background(CinemaColor.surfaceContainerHigh.opacity(0.9))
                        .clipShape(Capsule())
                        .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
                .overlay { MissingEpisodeLook.outline(cornerRadius: CinemaRadius.medium) }
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.localized("detail.episode", episode.episodeNumber))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Text(episode.name)
                    .font(.system(size: episodeTitleFontSize, weight: .bold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(2)
                if let date = MissingEpisodeLook.airDate(episode.airDate, locale: loc.locale) {
                    Text(date)
                        .font(CinemaFont.label(.medium))
                        .foregroundStyle(CinemaColor.onSurfaceMuted)
                }
            }
        }
        .contentShape(Rectangle())
        .layoutBoundDynamicType()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc.localized(
            "seerr.missing.a11y", MediaDetailMissingEpisodesBlock.title(episode), loc.localized("seerr.episodes.missing.row")))
    }
}
#endif

#if os(tvOS)
/// A missing episode in the Apple TV list, the height of the owned rows.
/// FOCUSABLE even with nothing to do: seven unfocusable rows in a row left the
/// focus engine no way back up from « Titres similaires » to the episodes
/// (measured on the tvOS simulator 2026-11-11, an account without the report
/// right). Selecting it opens the report when the account may report.
struct MediaDetailMissingEpisodeRow: View {
    let episode: SeerrMissingEpisode
    let stillURL: URL?
    let episodeThumbnailWidth: CGFloat
    let episodeTitleFontSize: CGFloat
    let onReport: (() -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Button { onReport?() } label: { content }
            .buttonStyle(TVEpisodeZoneButtonStyle(accent: themeManager.accent))
            .accessibilityLabel(loc.localized(
                "seerr.missing.a11y", MediaDetailMissingEpisodesBlock.title(episode), subtitle))
    }

    private var content: some View {
        HStack(spacing: 12) {
            MissingEpisodeLook.still(stillURL)
                .frame(width: episodeThumbnailWidth, height: episodeThumbnailWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.medium))
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.localized("detail.episode", episode.episodeNumber))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                Text(episode.name)
                    .font(.system(size: episodeTitleFontSize, weight: .semibold))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .lineLimit(2)
                Text(subtitle)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { MissingEpisodeLook.outline(cornerRadius: CinemaRadius.large) }
    }

    /// « Pas sur le serveur • 8 mai 2011 ».
    private var subtitle: String {
        let missing = loc.localized("seerr.episodes.missing.row")
        guard let date = MissingEpisodeLook.airDate(episode.airDate, locale: loc.locale) else { return missing }
        return missing + " • " + date
    }
}
#endif

/// In place of the missing episodes once the user hid them for this series
/// (owner 2026-11-11, option A): one quiet line, « Afficher » brings them back.
struct MediaDetailHiddenMissingEpisodesLine: View {
    let onShow: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CinemaSpacing.spacing2) {
            Text(loc.localized("seerr.episodes.hiddenLine"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
            Text("·")
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceMuted)
                .accessibilityHidden(true)
            Button(action: onShow) {
                Text(loc.localized("seerr.episodes.show"))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(themeManager.accent)
                    .frame(minHeight: 44)
                    #if os(tvOS)
                    .padding(.horizontal, CinemaSpacing.spacing3)
                    #endif
            }
            #if os(tvOS)
            .buttonStyle(TVEpisodeZoneButtonStyle(accent: themeManager.accent))
            #else
            .buttonStyle(.plain)
            #endif
            .fixedSize()
        }
    }
}

/// Under the season's episodes, whose missing ones are drawn in place:
/// « Signaler » for an account that may report a problem (« Signalé à ton
/// admin » once sent), then « Masquer pour cette série » for a numbering the
/// automatic check cannot see through. Seerr cannot REQUEST them (a partly
/// available season is refused, and it has no per-episode request), so
/// nothing here is a request.
struct MediaDetailMissingEpisodesBlock: View, Equatable {
    let episodes: [SeerrMissingEpisode]
    let canReport: Bool
    let isReported: Bool
    let onReport: () -> Void
    let onHide: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.episodes == rhs.episodes && lhs.canReport == rhs.canReport && lhs.isReported == rhs.isReported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            // Mockup C (owner 2026-11-11): the count says what « Masquer »
            // hides, the action sits at its right in the accent — the same
            // language as « Demander les 5 » under the missing seasons.
            // Side by side when it fits; at large text sizes the action goes
            // under the count rather than squeezing it onto three lines.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: CinemaSpacing.spacing3) {
                    countTitle.fixedSize()
                    Spacer(minLength: CinemaSpacing.spacing2)
                    hideButton
                }
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                    countTitle
                    hideButton
                }
            }
            if isReported {
                Label(loc.localized("seerr.episodes.reported"), systemImage: "checkmark.circle.fill")
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(themeManager.accent)
            } else if canReport {
                CinemaButton(
                    title: loc.counted("seerr.episodes.report", episodes.count),
                    style: .ghost, icon: "flag", wrapsTitle: true, action: onReport
                )
            }
        }
    }

    private var countTitle: some View {
        Text(loc.counted("seerr.episodes.missing", episodes.count))
            .font(CinemaFont.label(.large))
            .foregroundStyle(CinemaColor.onSurface)
            .accessibilityAddTraits(.isHeader)
    }

    private var hideButton: some View {
        Button(action: onHide) {
            Text(loc.localized("seerr.episodes.hide.short"))
                .font(CinemaFont.label(.large))
                .foregroundStyle(themeManager.accent)
                .frame(minHeight: 44)
                #if os(tvOS)
                .padding(.horizontal, CinemaSpacing.spacing3)
                #endif
        }
        #if os(tvOS)
        .buttonStyle(TVEpisodeZoneButtonStyle(accent: themeManager.accent))
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(loc.localized("seerr.episodes.hide"))
        .fixedSize()
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
