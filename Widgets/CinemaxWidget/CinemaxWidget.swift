import WidgetKit
import SwiftUI

// Two home-screen widgets sharing one provider/view pipeline:
// "Continue Watching" (resume items) and "Favorites" (hearted items). Both
// read the session snapshot the app publishes to the App Group, fetch posters
// over the network, and label themselves with a header so the user can tell
// the rails apart. Layout is a 4-column poster grid whose LAST cell is a
// "See all" tile deep-linking to the app's Home tab (cinemax://home); each
// poster deep-links to its item (cinemax://item/{id}).

enum CinemaxRailKind: String {
    case continueWatching
    case favorites

    var headerIcon: String {
        self == .favorites ? "heart.fill" : "play.fill"
    }

    func headerTitle(french: Bool) -> String {
        switch self {
        case .continueWatching: return french ? "En cours" : "Continue Watching"
        case .favorites: return french ? "Favoris" : "Favorites"
        }
    }

    func emptyMessage(french: Bool) -> String {
        switch self {
        case .continueWatching: return french ? "Rien à reprendre" : "Nothing to resume"
        case .favorites: return french ? "Aucun favori" : "No favorites yet"
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
        family == .systemLarge ? 7 : 3
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
        }
        guard let items = fetched else {
            return PosterRailEntry(date: .now, kind: kind, posters: [], state: .unreachable)
        }
        var posters: [PosterRailEntry.Poster] = []
        for item in items {
            let data = await JellyfinLite.fetchImage(
                JellyfinLite.posterURL(session: session, itemId: item.posterItemId, maxWidth: 300)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch entry.state {
            case .notConnected:
                message(isFrench ? "Connectez-vous dans Cinemax" : "Sign in to Cinemax")
            case .unreachable:
                message(isFrench ? "Serveur Jellyfin inaccessible" : "Jellyfin server unreachable")
            case .ok where entry.posters.isEmpty:
                message(entry.kind.emptyMessage(french: isFrench))
            case .ok:
                grid
            }
        }
        .containerBackground(.black.gradient, for: .widget)
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
        .supportedFamilies([.systemMedium, .systemLarge])
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

@main
struct CinemaxWidgetBundle: WidgetBundle {
    var body: some Widget {
        CinemaxContinueWatchingWidget()
        CinemaxFavoritesWidget()
    }
}
