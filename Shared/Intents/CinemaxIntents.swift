#if os(iOS)
import AppIntents
import Foundation
import CinemaxKit
@preconcurrency import JellyfinAPI

// MARK: - Errors

/// What an intent can tell the user when it can't act.
///
/// These deliberately do **not** go through `LocalizationManager.userFacingMessage(for:)`:
/// that manager is part of the app's UI layer and doesn't exist in a headless
/// intent context. `LocalizedStringResource` keys resolve from
/// `Localizable.strings` at the system level instead.
enum CinemaxIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case nothingToResume
    case itemUnavailable
    case notEpisodic

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn:     "intent.error.notSignedIn"
        case .nothingToResume: "intent.error.nothingToResume"
        case .itemUnavailable: "intent.error.itemUnavailable"
        case .notEpisodic:     "intent.error.notEpisodic"
        }
    }
}

// MARK: - Shared routing

/// Posts an intent's navigation onto the running app.
///
/// Every intent here runs with `openAppWhenRun`, so `perform()` sets the
/// pending state and the app's own routing takes it from there. Playback in
/// particular goes through `MediaDetailScreen` rather than straight to the
/// player, which is what gives a spoken request the same fidelity as a tap —
/// series → next-up resolution, resume position, prev/next episode buttons.
@MainActor
private enum IntentRouter {

    static func open(itemId: String) {
        let appState = AppNavigation.sharedAppState
        appState.pendingDeepLinkItemId = itemId
    }

    static func play(itemId: String) {
        let appState = AppNavigation.sharedAppState
        appState.pendingIntentPlaybackItemId = itemId
        appState.pendingDeepLinkItemId = itemId
    }

    static func search(query: String) {
        let appState = AppNavigation.sharedAppState
        appState.pendingIntentSearchQuery = query
        appState.pendingDeepLinkTabId = MenuEntry.searchID
    }
}

/// Resolves an entity to an item id on the **active** server.
///
/// The cross-server guard, applied a second time at perform time: a shortcut
/// saved against another server must fail rather than act on whatever happens
/// to be active now.
private func activeServerItemId(for entity: MediaItemEntity) throws -> String {
    guard let session = IntentSessionProvider.makeSession() else {
        throw CinemaxIntentError.notSignedIn
    }
    guard let parsed = entity.entityID, parsed.belongs(to: session.context.serverId) else {
        throw CinemaxIntentError.itemUnavailable
    }
    return parsed.itemId
}

// MARK: - Resume

struct ResumePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.resume.title"
    static let description = IntentDescription("intent.resume.description")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let session = IntentSessionProvider.makeSession() else {
            throw CinemaxIntentError.notSignedIn
        }
        let resume = try? await session.api.getResumeItems(userId: session.context.userId, limit: 1)
        guard let item = resume?.first, let itemId = item.id else {
            throw CinemaxIntentError.nothingToResume
        }
        IntentRouter.play(itemId: itemId)
        return .result()
    }
}

// MARK: - Play a title

struct PlayMediaItemIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.play.title"
    static let description = IntentDescription("intent.play.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.param.item")
    var item: MediaItemEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.play(itemId: try activeServerItemId(for: item))
        return .result()
    }
}

// MARK: - Next episode

struct PlayNextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.nextEpisode.title"
    static let description = IntentDescription("intent.nextEpisode.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.param.series")
    var series: MediaItemEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        // Refused up front rather than opening a movie and doing nothing —
        // the entity carries its kind precisely so this costs no round-trip.
        guard series.isEpisodic else { throw CinemaxIntentError.notEpisodic }
        // The detail screen resolves the series to its next unwatched episode,
        // which is exactly what the Play button does for a series.
        IntentRouter.play(itemId: try activeServerItemId(for: series))
        return .result()
    }
}

// MARK: - Open a title

struct OpenMediaItemIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.open.title"
    static let description = IntentDescription("intent.open.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.param.item")
    var item: MediaItemEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.open(itemId: try activeServerItemId(for: item))
        return .result()
    }
}

// MARK: - Search

struct SearchLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.search.title"
    static let description = IntentDescription("intent.search.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.param.query")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        // Same hygiene the search field applies: a Shortcuts-supplied term is
        // as untrusted as a pasted one.
        let cleaned = LibrarySearchRanker.sanitize(query)
        guard !cleaned.isEmpty else { throw CinemaxIntentError.itemUnavailable }
        IntentRouter.search(query: cleaned)
        return .result()
    }
}

// MARK: - Siri phrases

/// **Phrases are localized in `AppShortcuts.strings`, not `Localizable.strings`** —
/// a separate table the system reads on its own. The literals below are the
/// French base (the project's development language); `en.lproj/AppShortcuts.strings`
/// carries the English.
struct CinemaxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Reprendre ma lecture dans \(.applicationName)",
                "Reprendre \(.applicationName)",
                "Continuer à regarder dans \(.applicationName)"
            ],
            shortTitle: "intent.resume.shortTitle",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: PlayMediaItemIntent(),
            phrases: [
                "Lire \(\.$item) dans \(.applicationName)",
                "Regarder \(\.$item) dans \(.applicationName)",
                "Lance \(\.$item) sur \(.applicationName)"
            ],
            shortTitle: "intent.play.shortTitle",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayNextEpisodeIntent(),
            phrases: [
                "Lire le prochain épisode de \(\.$series) dans \(.applicationName)",
                "Épisode suivant de \(\.$series) dans \(.applicationName)"
            ],
            shortTitle: "intent.nextEpisode.shortTitle",
            systemImageName: "forward.end.fill"
        )
        AppShortcut(
            intent: OpenMediaItemIntent(),
            phrases: [
                "Ouvrir \(\.$item) dans \(.applicationName)",
                "Afficher \(\.$item) dans \(.applicationName)"
            ],
            shortTitle: "intent.open.shortTitle",
            systemImageName: "info.circle.fill"
        )
        // No parameter token here: a phrase may only interpolate an `AppEntity`
        // or `AppEnum`, and the search term is free text. Siri prompts for it
        // after matching the phrase.
        AppShortcut(
            intent: SearchLibraryIntent(),
            phrases: [
                "Rechercher dans \(.applicationName)",
                "Chercher dans \(.applicationName)"
            ],
            shortTitle: "intent.search.shortTitle",
            systemImageName: "magnifyingglass"
        )
    }
}
#endif
