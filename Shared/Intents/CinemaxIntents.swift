#if os(iOS)
import AppIntents
import Foundation
import CinemaxKit
import JellyfinAPI

// MARK: - Errors

/// What an intent can tell the user when it can't act.
///
/// These deliberately do **not** go through `LocalizationManager.userFacingMessage(for:)`:
/// that manager is part of the app's UI layer and doesn't exist in a headless
/// intent context. The text is read from the APP's own table, in the app's
/// language (`appLanguage`, as `IntentSessionProvider.preferredLanguage`
/// reads it), and handed over already resolved: a bare key was resolved by
/// the system in the DEVICE's language — an English phone running the app in
/// French answered its errors in English
/// (recette 2026-10-23, DEF-IOS3).
enum CinemaxIntentError: Error, CaseIterable, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case nothingToResume
    case itemUnavailable
    case notEpisodic

    var key: String {
        switch self {
        case .notSignedIn:     "intent.error.notSignedIn"
        case .nothingToResume: "intent.error.nothingToResume"
        case .itemUnavailable: "intent.error.itemUnavailable"
        case .notEpisodic:     "intent.error.notEpisodic"
        }
    }

    var localizedStringResource: LocalizedStringResource {
        localizedStringResource(defaults: .standard)
    }

    func localizedStringResource(defaults: UserDefaults) -> LocalizedStringResource {
        let language = IntentSessionProvider.preferredLanguage(defaults: defaults)
        let text = Bundle.localizedBundle(for: language).localizedString(forKey: key, value: nil, table: nil)
        // Interpolated, the value's key is `%@` — found in no table — so it
        // resolves to `text` verbatim, in whichever process shows it.
        return LocalizedStringResource("\(text)", locale: Locale(identifier: language))
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

    /// Asked for when the phrase named no title (« Lis quelque chose dans
    /// JellyGlass »): the answer goes through `MediaItemQuery.entities(matching:)`,
    /// i.e. the whole library — a title IN the phrase can only be one of the
    /// suggested entities.
    @Parameter(title: "intent.param.item", requestValueDialog: IntentDialog("intent.param.item.prompt"))
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
                "Lis \(\.$item) dans \(.applicationName)",
                "Joue \(\.$item) dans \(.applicationName)",
                "Regarder \(\.$item) dans \(.applicationName)",
                "Lance \(\.$item) sur \(.applicationName)",
                // No title: Siri asks « Quel titre ? » and the answer is
                // searched in the whole library (`requestValueDialog`). A
                // title spoken IN the phrase only matches the suggested ones.
                "Lis quelque chose dans \(.applicationName)",
                "Regarder un film dans \(.applicationName)",
                "Regarder une série dans \(.applicationName)",
                "Lance un film sur \(.applicationName)"
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
