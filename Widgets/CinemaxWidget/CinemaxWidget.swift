import WidgetKit
import SwiftUI

// Two home-screen widgets sharing one provider/view pipeline:
// "Continue Watching" (resume items) and "Favorites" (hearted items). Both
// read the session snapshot the app publishes to the shared Keychain group, fetch posters
// over the network, and label themselves with a header so the user can tell
// the rails apart. Layout is a 4-column poster grid whose LAST cell is a
// "See all" tile deep-linking to the app's Home tab (cinemax://home); each
// poster deep-links to its item (cinemax://item/{id}).

enum CinemaxRailKind: String {
    case continueWatching
    case favorites
    case nextUp
    case recentlyAdded

    var headerIcon: String {
        switch self {
        case .continueWatching: return "play.fill"
        case .favorites: return "heart.fill"
        case .nextUp: return "forward.end.fill"
        case .recentlyAdded: return "sparkles"
        }
    }

    func headerTitle(french: Bool) -> String {
        switch self {
        case .continueWatching: return french ? "En cours" : "Continue Watching"
        case .favorites: return french ? "Favoris" : "Favorites"
        case .nextUp: return french ? "À suivre" : "Next Up"
        case .recentlyAdded: return french ? "Récemment ajoutés" : "Recently Added"
        }
    }

    func emptyMessage(french: Bool) -> String {
        switch self {
        case .continueWatching: return french ? "Rien à reprendre" : "Nothing to resume"
        case .favorites: return french ? "Aucun favori" : "No favorites yet"
        case .nextUp: return french ? "Rien à suivre" : "Nothing up next"
        case .recentlyAdded: return french ? "Rien de récent" : "Nothing new"
        }
    }
}

struct PosterRailEntry: TimelineEntry {
    struct Poster: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let imageData: Data?
    }

    enum State {
        case ok
        case notConnected   // no session snapshot (logged out / first run)
        case unreachable    // session present but the server didn't answer
    }

    let date: Date
    let kind: CinemaxRailKind
    let posters: [Poster]
    let state: State

    static func placeholder(kind: CinemaxRailKind) -> PosterRailEntry {
        PosterRailEntry(
            date: .now,
            kind: kind,
            posters: (0..<3).map { .init(id: "placeholder-\($0)", title: " ", subtitle: nil, imageData: nil) },
            state: .ok
        )
    }
}

struct PosterRailProvider: TimelineProvider {
    let kind: CinemaxRailKind

    /// Carries the framework's completion into the fetch Task. WidgetKit's
    /// completion annotations differ across SDK versions (Xcode 26.2 vs 26.5
    /// disagree), so an `@unchecked Sendable` box + a minimal Task body is
    /// the only shape that satisfies every toolchain's region-isolation
    /// checker. Safe: invoked exactly once, no documented queue affinity.
    private final class HandlerBox<Value>: @unchecked Sendable {
        let call: (Value) -> Void
        init(_ call: @escaping (Value) -> Void) { self.call = call }
    }

    func placeholder(in context: Context) -> PosterRailEntry { .placeholder(kind: kind) }

    func getSnapshot(in context: Context, completion: @escaping (PosterRailEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder(kind: kind))
            return
        }
        let handler = HandlerBox(completion)
        let railKind = kind
        let posterCap = Self.maxPosters(for: context.family)
        Task { await Self.deliverSnapshot(kind: railKind, maxPosters: posterCap, handler: handler) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PosterRailEntry>) -> Void) {
        let handler = HandlerBox(completion)
        let railKind = kind
        let posterCap = Self.maxPosters(for: context.family)
        Task { await Self.deliverTimeline(kind: railKind, maxPosters: posterCap, handler: handler) }
    }

    private static func deliverSnapshot(kind: CinemaxRailKind, maxPosters: Int, handler: HandlerBox<PosterRailEntry>) async {
        handler.call(await loadEntry(kind: kind, maxPosters: maxPosters))
    }

    private static func deliverTimeline(kind: CinemaxRailKind, maxPosters: Int, handler: HandlerBox<Timeline<PosterRailEntry>>) async {
        let entry = await loadEntry(kind: kind, maxPosters: maxPosters)
        // Content only changes when the user watches/hearts something — a
        // half-hour cadence keeps the widget fresh without burning the
        // extension's refresh budget (the app also force-reloads on session
        // changes via WidgetCenter).
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date) ?? entry.date
        handler.call(Timeline(entries: [entry], policy: .after(next)))
    }

    /// 4-column grid; the last cell is always the "See all" tile, so fetch
    /// one less poster than the grid holds.
    private static func maxPosters(for family: WidgetFamily) -> Int {
        switch family {
        // Lock Screen / StandBy: one item, and no "See all" tile to make room
        // for — a rectangular accessory fits a title and a line under it, and a
        // circular one fits a glyph. Without this case they fell into the `3`
        // branch and paid two poster downloads nothing would ever render.
        case .accessoryRectangular, .accessoryCircular, .accessoryInline: 1
        case .systemLarge: 7
        default: 3
        }
    }

    /// "Recently Added" from two sources, matching the app's Home row.
    ///
    /// New titles alone (`includeItemTypes=Movie,Series`) can never surface a
    /// long-owned show that just got a new season: a series carries its own
    /// creation date, not the date of the episode that made it interesting. So
    /// shows-with-new-episodes lead, capped to roughly a third of the grid, and
    /// new titles fill the rest.
    ///
    /// The cap is what keeps this a signal rather than the content — an active
    /// TV library produces new episodes far faster than new titles, and this
    /// grid only holds 3 or 7 posters.
    ///
    /// Returns nil only when BOTH sources fail, so one unreachable query still
    /// renders a populated widget instead of the "unreachable" state.
    private static func loadRecentlyAdded(session: JellyfinLite.Session, maxPosters: Int) async -> [JellyfinLite.ResumeItem]? {
        let showsCap = max(1, maxPosters / 3)
        let newTitles = await JellyfinLite.fetchRecentlyAdded(session: session, limit: maxPosters)
        let showsWithNewEpisodes = await JellyfinLite.fetchSeriesWithRecentEpisodes(session: session, limit: showsCap)
        if newTitles == nil && showsWithNewEpisodes == nil { return nil }

        var seen = Set<String>()
        var merged: [JellyfinLite.ResumeItem] = []
        for item in (showsWithNewEpisodes ?? []).prefix(showsCap) + (newTitles ?? []) {
            guard seen.insert(item.id).inserted else { continue }
            merged.append(item)
            if merged.count == maxPosters { break }
        }
        return merged
    }

    private static func loadEntry(kind: CinemaxRailKind, maxPosters: Int) async -> PosterRailEntry {
        guard let session = JellyfinLite.readSession() else {
            return PosterRailEntry(date: .now, kind: kind, posters: [], state: .notConnected)
        }
        let fetched: [JellyfinLite.ResumeItem]?
        switch kind {
        case .continueWatching:
            fetched = await JellyfinLite.fetchResumeItems(session: session, limit: maxPosters)
        case .favorites:
            fetched = await JellyfinLite.fetchFavorites(session: session, limit: maxPosters)
        case .nextUp:
            fetched = await JellyfinLite.fetchNextUp(session: session, limit: maxPosters)
        case .recentlyAdded:
            fetched = await loadRecentlyAdded(session: session, maxPosters: maxPosters)
        }
        guard let items = fetched else {
            return PosterRailEntry(date: .now, kind: kind, posters: [], state: .unreachable)
        }
        var posters: [PosterRailEntry.Poster] = []
        for item in items {
            let data = await JellyfinLite.fetchImage(
                JellyfinLite.posterURL(session: session, itemId: item.posterItemId, maxWidth: 300),
                token: session.accessToken
            )
            posters.append(.init(id: item.id, title: item.title, subtitle: item.subtitle, imageData: data))
        }
        return PosterRailEntry(date: .now, kind: kind, posters: posters, state: .ok)
    }
}

struct PosterRailWidgetView: View {
    var entry: PosterRailEntry
    @Environment(\.widgetFamily) private var family

    private var isFrench: Bool {
        Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
    }

    private let columns = 4

    @ViewBuilder
    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular:
            // Accessory renders are vibrant / monochrome and the system paints
            // the ground: an opaque background here comes out as a grey slab.
            accessoryBody.containerBackground(.clear, for: .widget)
        default:
            systemBody.containerBackground(.black.gradient, for: .widget)
        }
    }

    private var systemBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let stateMessage {
                message(stateMessage)
            } else {
                grid
            }
        }
    }

    /// Lock Screen / StandBy. One item, no header, no "See all" tile — the whole
    /// view is the tap target (`widgetURL`), because a per-cell `Link` is what
    /// the grid uses and accessory families do not honour it.
    @ViewBuilder
    private var accessoryBody: some View {
        let poster = entry.posters.first
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: poster == nil ? "play.slash" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.kind.headerTitle(french: isFrench).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                    if let poster {
                        Text(poster.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let subtitle = poster.subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                    } else {
                        Text(stateMessage ?? "")
                            .font(.system(size: 11))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Nothing to resume ⇒ the Home tab, which is where the lists live.
        .widgetURL(URL(string: poster.map { "cinemax://item/\($0.id)" } ?? "cinemax://home"))
    }

    /// The ONE place the three degraded messages are written — the accessory
    /// families print the same strings, and two copies would drift.
    /// `nil` means "there is content to show".
    private var stateMessage: String? {
        switch entry.state {
        case .notConnected:
            isFrench ? "Connectez-vous dans Cinemax" : "Sign in to Cinemax"
        case .unreachable:
            isFrench ? "Serveur Jellyfin inaccessible" : "Jellyfin server unreachable"
        case .ok:
            entry.posters.isEmpty ? entry.kind.emptyMessage(french: isFrench) : nil
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: entry.kind.headerIcon)
                .font(.system(size: 10, weight: .bold))
            Text(entry.kind.headerTitle(french: isFrench).uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
            Spacer()
        }
        .foregroundStyle(.white.opacity(0.65))
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Posters + a trailing "See all" tile, 4 cells per row.
    private var grid: some View {
        let cellCount = entry.posters.count + 1 // + "See all"
        let rows: [[Int]] = stride(from: 0, to: cellCount, by: columns).map {
            Array($0..<min($0 + columns, cellCount))
        }
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r], id: \.self) { index in
                        if index < entry.posters.count {
                            posterCell(entry.posters[index])
                        } else {
                            seeAllCell
                        }
                    }
                    ForEach(0..<(columns - rows[r].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func posterCell(_ poster: PosterRailEntry.Poster) -> some View {
        Link(destination: URL(string: "cinemax://item/\(poster.id)") ?? URL(fileURLWithPath: "/")) {
            VStack(spacing: 3) {
                Group {
                    if let data = poster.imageData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(poster.subtitle.map { "\(poster.title) · \($0)" } ?? poster.title)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }

    /// Last grid cell: opens the app on the Home tab (full lists live there).
    private var seeAllCell: some View {
        Link(destination: URL(string: "cinemax://home") ?? URL(fileURLWithPath: "/")) {
            VStack(spacing: 3) {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(isFrench ? "Voir tout" : "See all")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(" ") // keeps the tile's height in step with poster cells
                    .font(.system(size: 8, weight: .medium))
            }
        }
    }
}

struct CinemaxContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CinemaxContinueWatching", provider: PosterRailProvider(kind: .continueWatching)) { entry in
            PosterRailWidgetView(entry: entry)
        }
        .configurationDisplayName(
            Locale.preferredLanguages.first?.hasPrefix("fr") ?? true ? "Reprendre la lecture" : "Continue Watching"
        )
        .description(
            Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
                ? "Reprenez vos films et séries en cours."
                : "Jump back into what you were watching."
        )
        // Continue Watching is the ONLY rail that earns the Lock Screen: one
        // item is all an accessory fits, and "the thing I was watching" is the
        // one rail whose first item is worth a glance. The other three stay
        // system-sized — a lock screen showing one arbitrary favourite says
        // nothing. StandBy inherits these families for free.
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
    }
}

struct CinemaxFavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CinemaxFavorites", provider: PosterRailProvider(kind: .favorites)) { entry in
            PosterRailWidgetView(entry: entry)
        }
        .configurationDisplayName(
            Locale.preferredLanguages.first?.hasPrefix("fr") ?? true ? "Favoris" : "Favorites"
        )
        .description(
            Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
                ? "Vos films et séries favoris."
                : "Your favorite movies and shows."
        )
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct CinemaxNextUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CinemaxNextUp", provider: PosterRailProvider(kind: .nextUp)) { entry in
            PosterRailWidgetView(entry: entry)
        }
        .configurationDisplayName(
            Locale.preferredLanguages.first?.hasPrefix("fr") ?? true ? "À suivre" : "Next Up"
        )
        .description(
            Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
                ? "Le prochain épisode à regarder de vos séries en cours."
                : "The next episode to watch from your shows."
        )
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct CinemaxRecentlyAddedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CinemaxRecentlyAdded", provider: PosterRailProvider(kind: .recentlyAdded)) { entry in
            PosterRailWidgetView(entry: entry)
        }
        .configurationDisplayName(
            Locale.preferredLanguages.first?.hasPrefix("fr") ?? true ? "Récemment ajoutés" : "Recently Added"
        )
        .description(
            Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
                ? "Les derniers films et séries ajoutés à votre serveur."
                : "The latest movies and shows added to your server."
        )
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct CinemaxWidgetBundle: WidgetBundle {
    var body: some Widget {
        CinemaxContinueWatchingWidget()
        CinemaxFavoritesWidget()
        CinemaxNextUpWidget()
        CinemaxRecentlyAddedWidget()
        // Control Center / Action button / Lock Screen control — see
        // ResumeControl.swift for why its intent is shared by source.
        CinemaxResumeControl()
        // Playback Live Activity (Lock Screen + Dynamic Island) — views and
        // configuration live in PlaybackLiveActivityWidget.swift.
        #if canImport(ActivityKit)
        CinemaxPlaybackLiveActivity()
        #endif
    }
}
