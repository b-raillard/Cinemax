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
/// French answered « Siri and Shortcuts are part of JellyGlass Pro »
/// (recette 2026-10-23, DEF-IOS3).
enum CinemaxIntentError: Error, CaseIterable, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case nothingToResume
    case itemUnavailable
    case notEpisodic
    case proRequired

    var key: String {
        switch self {
        case .notSignedIn:     "intent.error.notSignedIn"
        case .nothingToResume: "intent.error.nothingToResume"
        case .itemUnavailable: "intent.error.itemUnavailable"
        case .notEpisodic:     "intent.error.notEpisodic"
        case .proRequired:     "intent.error.proRequired"
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

/// Siri, Shortcuts and the Control Center « Reprendre » are ONE Pro feature
/// (`ProFeatureID.shortcuts`, spec 2026-10-22). Asked FIRST in every
/// `perform()` — before the session, so a free user hears « fonction Pro »,
/// not « connectez-vous ». Refused ⇒ `proRequired`, and `admit` has raised the
/// Pro sheet, which the root presents on the app `openAppWhenRun` has already
/// opened. Before the Pro launches everybody passes (`ProFeatureGate`).
@MainActor
enum IntentProGate {
    static func admit(_ access: ProFeatureAccess) throws {
        guard access.admit(.shortcuts) else { throw CinemaxIntentError.proRequired }
    }

    /// The app's own gate — a process singleton readable without a scene: the
    /// entitlement comes from UserDefaults + the iCloud KVS and the founder
    /// facts from the Keychain cache, all read synchronously at init.
    static func admit() throws {
        try admit(AppNavigation.sharedProAccess)
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
///
/// Reads the active context alone: it needs the server id, not a client, so it
/// builds none (and runs no route probe).
private func activeServerItemId(for entity: MediaItemEntity) throws -> String {
    guard let context = IntentSessionProvider.resolveContext(keychain: KeychainService()) else {
        throw CinemaxIntentError.notSignedIn
    }
    guard let parsed = entity.entityID, parsed.belongs(to: context.serverId) else {
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
        try IntentProGate.admit()
        guard let session = await IntentSessionProvider.makeSession() else {
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

    /// Shortcuts app only — deliberately NO Siri phrase (see `CinemaxShortcuts`).
    @Parameter(title: "intent.param.item")
    var item: MediaItemEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentProGate.admit()
        IntentRouter.play(itemId: try activeServerItemId(for: item))
        return .result()
    }
}

/// Plays the library's best match for a title said to Siri.
///
/// Same search, ranking and parental filter as the Shortcuts picker. No match
/// opens the search screen on what Siri heard, so a misheard title can be
/// corrected rather than dead-ending.
@MainActor
private func playBestMatch(for spokenTitle: String) async throws {
    // A signed-in check only: the context alone, no client, no route probe
    // (the query below builds its own session).
    guard IntentSessionProvider.resolveContext(keychain: KeychainService()) != nil else {
        throw CinemaxIntentError.notSignedIn
    }
    if let best = try await MediaItemQuery().entities(matching: spokenTitle).first {
        IntentRouter.play(itemId: try activeServerItemId(for: best))
    } else {
        let cleaned = LibrarySearchRanker.sanitize(spokenTitle)
        guard !cleaned.isEmpty else { throw CinemaxIntentError.itemUnavailable }
        IntentRouter.search(query: cleaned)
    }
}

// MARK: - Play a title said after the phrase

/// « Lis quelque chose dans JellyGlass » → « Quel titre ? » → any title in
/// the library.
///
/// **Why a `String` and not a `MediaItemEntity`:** on the new Siri (iOS 27.2),
/// the answer to an ENTITY parameter's prompt is matched against
/// `suggestedEntities()` only — `entities(matching:)` is never called, so a
/// title outside « Reprendre » / « À suivre » made Siri ask again every ~5 s
/// until it gave up (device logs, 2026-11-01). A `String` answer reaches
/// `perform()` as said, and the library search runs here.
struct PlaySpokenTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.playTitle.title"
    static let description = IntentDescription("intent.playTitle.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.param.item", requestValueDialog: IntentDialog("intent.param.item.prompt"))
    var spokenTitle: String

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentProGate.admit()
        try await playBestMatch(for: spokenTitle)
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
        try IntentProGate.admit()
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
        try IntentProGate.admit()
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
        try IntentProGate.admit()
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
        // Playing a title by voice has ONE path: a phrase with no title, then
        // « Quel titre ? », answered as free text and searched in the whole
        // library. « Lis ${item} dans JellyGlass » was removed: on iOS 27.2 a
        // title outside the 12 suggested entities left the slot empty, Siri
        // re-asked every ~5 s and gave up (device logs, 2026-11-01).
        AppShortcut(
            intent: PlaySpokenTitleIntent(),
            phrases: [
                "Lis quelque chose dans \(.applicationName)",
                "Regarder un film dans \(.applicationName)",
                "Regarder une série dans \(.applicationName)",
                "Lance un film sur \(.applicationName)"
            ],
            shortTitle: "intent.playTitle.shortTitle",
            systemImageName: "play.rectangle.fill"
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
