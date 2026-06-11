import WidgetKit
import SwiftUI

// Continue-Watching home-screen widget. The timeline provider reads the
// session snapshot the app publishes to the App Group, fetches resume items
// + poster bytes over the network, and each poster deep-links into the app
// via cinemax://item/{id} (handled by AppState.handleDeepLink → Home push).

struct ContinueWatchingEntry: TimelineEntry {
    struct Poster: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let imageData: Data?
    }

    let date: Date
    let posters: [Poster]
    /// False when no session snapshot exists (logged out / first run).
    let isConnected: Bool

    static let placeholder = ContinueWatchingEntry(
        date: .now,
        posters: (0..<3).map { .init(id: "placeholder-\($0)", title: " ", subtitle: nil, imageData: nil) },
        isConnected: true
    )
}

struct ContinueWatchingProvider: TimelineProvider {
    /// Carries the framework's completion into the fetch Task. Same pattern as
    /// the Top Shelf provider: WidgetKit's completion annotations differ
    /// across SDK versions (Xcode 26.2 vs 26.5 disagree), so an
    /// `@unchecked Sendable` box + a minimal Task body is the only shape that
    /// satisfies every toolchain's region-isolation checker. Safe: invoked
    /// exactly once, WidgetKit documents no queue affinity.
    private final class HandlerBox<Value>: @unchecked Sendable {
        let call: (Value) -> Void
        init(_ call: @escaping (Value) -> Void) { self.call = call }
    }

    func placeholder(in context: Context) -> ContinueWatchingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        let handler = HandlerBox(completion)
        let posterCap = Self.maxPosters(for: context.family)
        Task { await Self.deliverSnapshot(maxPosters: posterCap, handler: handler) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        let handler = HandlerBox(completion)
        let posterCap = Self.maxPosters(for: context.family)
        Task { await Self.deliverTimeline(maxPosters: posterCap, handler: handler) }
    }

    private static func deliverSnapshot(maxPosters: Int, handler: HandlerBox<ContinueWatchingEntry>) async {
        handler.call(await loadEntry(maxPosters: maxPosters))
    }

    private static func deliverTimeline(maxPosters: Int, handler: HandlerBox<Timeline<ContinueWatchingEntry>>) async {
        let entry = await loadEntry(maxPosters: maxPosters)
        // Resume positions only change when the user watches something — a
        // half-hour cadence keeps the widget fresh without burning the
        // extension's refresh budget.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date) ?? entry.date
        handler.call(Timeline(entries: [entry], policy: .after(next)))
    }

    private static func maxPosters(for family: WidgetFamily) -> Int {
        family == .systemLarge ? 6 : 3
    }

    private static func loadEntry(maxPosters: Int) async -> ContinueWatchingEntry {
        guard let session = JellyfinLite.readSession() else {
            return ContinueWatchingEntry(date: .now, posters: [], isConnected: false)
        }
        let items = await JellyfinLite.fetchResumeItems(session: session, limit: maxPosters)
        var posters: [ContinueWatchingEntry.Poster] = []
        for item in items {
            let data = await JellyfinLite.fetchImage(
                JellyfinLite.posterURL(session: session, itemId: item.posterItemId, maxWidth: 300)
            )
            posters.append(.init(id: item.id, title: item.title, subtitle: item.subtitle, imageData: data))
        }
        return ContinueWatchingEntry(date: .now, posters: posters, isConnected: true)
    }
}

struct ContinueWatchingWidgetView: View {
    var entry: ContinueWatchingEntry
    @Environment(\.widgetFamily) private var family

    private var isFrench: Bool {
        Locale.preferredLanguages.first?.hasPrefix("fr") ?? true
    }

    var body: some View {
        Group {
            if !entry.isConnected {
                message(isFrench ? "Connectez-vous dans Cinemax" : "Sign in to Cinemax")
            } else if entry.posters.isEmpty {
                message(isFrench ? "Rien à reprendre" : "Nothing to resume")
            } else {
                posterRows
            }
        }
        .containerBackground(.black.gradient, for: .widget)
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var posterRows: some View {
        let columns = 3
        let rows: [[ContinueWatchingEntry.Poster]] = stride(from: 0, to: entry.posters.count, by: columns).map {
            Array(entry.posters[$0..<min($0 + columns, entry.posters.count)])
        }
        return VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 10) {
                    ForEach(rows[r]) { poster in
                        posterCell(poster)
                    }
                    // Pad short rows so posters keep their column width.
                    ForEach(0..<(columns - rows[r].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(2)
    }

    private func posterCell(_ poster: ContinueWatchingEntry.Poster) -> some View {
        Link(destination: URL(string: "cinemax://item/\(poster.id)") ?? URL(fileURLWithPath: "/")) {
            VStack(spacing: 4) {
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
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(poster.subtitle.map { "\(poster.title) · \($0)" } ?? poster.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }
}

struct CinemaxContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CinemaxContinueWatching", provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingWidgetView(entry: entry)
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

@main
struct CinemaxWidgetBundle: WidgetBundle {
    var body: some Widget {
        CinemaxContinueWatchingWidget()
    }
}
