# Menus contextuels sur vignettes — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Faire de l'appui long sur une vignette un vrai raccourci d'action — lancer la lecture, l'envoyer sur l'Apple TV, atteindre la série parente — depuis toutes les surfaces qui affichent des vignettes.

**Architecture:** Un `CardActionPresenter` `@Observable` hébergé à la racine (`AppNavigation`) porte les requêtes que les menus contextuels ne peuvent pas présenter eux-mêmes (RULE conteneur-lazy) ; sur tvOS la lecture délègue au `VideoPlayerCoordinator` existant, sur iOS elle passe par un `.fullScreenCover` racine. « Aller à la série » utilise l'autre patron du projet — un rappel remonté à un écran hôte qui héberge son `navigationDestination` hors du conteneur lazy.

**Tech Stack:** SwiftUI (iOS 26 / tvOS 26), Swift 6 strict concurrency, CinemaxKit, swift-testing.

Spec de référence : [docs/superpowers/specs/2026-08-06-card-context-menus-design.md](../specs/2026-08-06-card-context-menus-design.md)

> **Statut (2026-08-06, revue finale de branche) :** toutes les tâches ont été exécutées — voir l'historique de commits `feat(cards)`/`feat(home)`/`chore(cards)`/`docs` sur `feat/card-context-menus`. Les cases sont cochées en conséquence, **sauf** les étapes de vérification manuelle sur simulateur/matériel (le dernier "vérifier à la main" / "vérifier le focus tvOS" de chaque tâche, et l'étape 4 du scénario PiP en Task 7), qui restent non cochées et sont **reportées à une vérification humaine sur matériel réel** — aucun outil automatisé de cette session ne pilote un simulateur interactif.

## Global Constraints

- **Swift 6 strict concurrency.** `BaseItemDto` n'est **pas** `Sendable` : ne jamais le passer en paramètre d'un appel `async` nonisolated depuis le `@MainActor` (transfert de région d'une valeur que l'acteur principal détient encore). Extraire les scalaires côté main actor, puis appeler.
- **`@Observable` sans `didSet`/`willSet`** sur les propriétés stockées.
- **Menu contextuel accroché au bouton focusable, jamais à son label** — sinon le focus tvOS casse.
- **Aucune chaîne en dur** : tout passe par `loc.localized("clé")`, clés présentes dans `Resources/fr.lproj/Localizable.strings` **et** `Resources/en.lproj/Localizable.strings`.
- **Les commentaires de code s'écrivent en ANGLAIS** — convention du projet, vérifiée sur `LibrarySearchRanker`, `HomeViewModel`, `MediaDetailViewModel`, `AppNavigation`. Les commentaires français des blocs de code de ce plan sont **illustratifs** : les traduire en anglais au moment de les écrire, en gardant le même contenu et le même niveau de détail. Seules les chaînes destinées à l'utilisateur restent françaises, et uniquement dans `fr.lproj/Localizable.strings`.
- **Jamais de `error.localizedDescription` à l'écran** : `loc.userFacingMessage(for: error)`. L'erreur brute part dans le `Logger`.
- **`@Environment` d'un `@Observable` lu en optionnel** dans `MediaCardContextMenu` — un lecture non-optionnelle **piège à l'exécution** quand la valeur est absente, et ces cartes vivent aussi dans des hôtes modaux qui réinjectent l'environnement à la main.
- **Ajout d'un fichier sous `Shared/`** ⇒ relancer `cd Cinemax && xcodegen generate` avant de compiler, sinon « cannot find type X in scope ».
- **Builds jamais en parallèle** iOS + tvOS (course sur `build.db`). Toujours `set -o pipefail` avec un pipe.
- **`-only-testing` n'exécute silencieusement aucun test swift-testing** — lancer la suite complète et grepper `Suite "…"` / `✔`.

**Commandes de référence :**

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -30
```

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | tail -30
```

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'Suite "|✘|✔|error:' | head -60
```

---

### Task 1 : `CardPlayTarget` — la résolution de la position de reprise

**Files:**
- Create: `Shared/ViewModels/CardPlayTarget.swift`
- Create: `Tests/CinemaxKitTests/CardPlayTargetTests.swift`
- Modify: `Tests/CinemaxKitTests/MockAPIClient.swift` (ajout d'un drapeau d'erreur dédié à `getNextUp`)

**Interfaces:**
- Consumes: `any LibraryAPI` (`getNextUp(seriesId:userId:) async throws -> BaseItemDto?`), `Int.jellyfinSeconds` (CinemaxKit).
- Produces:
  - `struct CardPlayTarget: Sendable, Equatable { let itemId: String; let title: String; let startSeconds: Double? }`
  - `enum CardPlayTargetResolver { static func resolve(itemId:type:title:positionTicks:isPlayed:api:userId:) async -> CardPlayTarget }`

Le résolveur est **nonisolated** et prend des scalaires, jamais un `BaseItemDto` — c'est la contrainte Swift 6 énoncée plus haut. Il ne choisit **pas** quel épisode lire quand l'information manque : `getPlaybackInfo` résout déjà Série → Épisode côté CinemaxKit ([JellyfinAPIClient+Playback.swift:277](../../../Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift)). Il ne sert qu'à connaître l'offset de reprise, et l'id d'épisode quand il l'a sous la main.

- [x] **Step 1 : ajouter le drapeau d'erreur dédié au mock**

Dans `Tests/CinemaxKitTests/MockAPIClient.swift`, remplacer la déclaration existante de `getNextUp` (vers la ligne 453) par :

```swift
    var stubbedNextUp: BaseItemDto?
    /// Drapeau **dédié**, distinct de `shouldThrow` : plusieurs suites existantes
    /// activent `shouldThrow` tout en laissant `getNextUp` réussir, et les faire
    /// basculer d'un coup changerait leur comportement sans rapport avec ce lot.
    var nextUpShouldThrow = false
    private(set) var getNextUpCallCount = 0
    func getNextUp(seriesId: String, userId: String) async throws -> BaseItemDto? {
        recordLock.withLock { getNextUpCallCount += 1 }
        if nextUpShouldThrow { throw stubbedError }
        return stubbedNextUp
    }
```

- [x] **Step 2 : écrire les tests qui échouent**

Créer `Tests/CinemaxKitTests/CardPlayTargetTests.swift` :

```swift
import Testing
import Foundation
import JellyfinAPI
import CinemaxKit
@testable import Cinemax

@Suite("CardPlayTarget")
struct CardPlayTargetTests {

    private func makeEpisode(id: String, name: String, positionTicks: Int, isPlayed: Bool) -> BaseItemDto {
        var ep = BaseItemDto()
        ep.id = id
        ep.name = name
        var data = UserItemDataDto()
        data.playbackPositionTicks = positionTicks
        data.isPlayed = isPlayed
        ep.userData = data
        return ep
    }

    // MARK: - Film / épisode : tout est local, aucun appel réseau

    @Test("Film à demi vu : reprise appliquée, sans appel réseau")
    func movieWithResume() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "m1", type: .movie, title: "Film",
            positionTicks: 6_000_000_000, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "m1")
        #expect(target.title == "Film")
        #expect(target.startSeconds == 600)
        #expect(api.getNextUpCallCount == 0)
    }

    @Test("Film marqué vu : la position résiduelle ne déclenche pas de reprise")
    func moviePlayedIgnoresPosition() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "m1", type: .movie, title: "Film",
            positionTicks: 6_000_000_000, isPlayed: true,
            api: api, userId: "u1"
        )
        #expect(target.startSeconds == nil)
    }

    @Test("Film jamais lancé : aucune reprise, aucun appel réseau")
    func movieWithoutResume() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "m1", type: .movie, title: "Film",
            positionTicks: 0, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.startSeconds == nil)
        #expect(api.getNextUpCallCount == 0)
    }

    @Test("Épisode à demi vu : reprise locale, aucun appel réseau")
    func episodeWithResume() async {
        let api = MockAPIClient()
        let target = await CardPlayTargetResolver.resolve(
            itemId: "e1", type: .episode, title: "S01E03",
            positionTicks: 3_000_000_000, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "e1")
        #expect(target.startSeconds == 300)
        #expect(api.getNextUpCallCount == 0)
    }

    // MARK: - Série : un getNextUp, et seulement pour l'offset

    @Test("Série : cible l'épisode next-up et hérite de sa position")
    func seriesResolvesNextUp() async {
        let api = MockAPIClient()
        api.stubbedNextUp = makeEpisode(id: "e7", name: "Épisode 7", positionTicks: 1_200_000_000, isPlayed: false)
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "e7")
        #expect(target.title == "Épisode 7")
        #expect(target.startSeconds == 120)
        #expect(api.getNextUpCallCount == 1)
    }

    @Test("Série dont le next-up est vu : on cible l'épisode, sans reprise")
    func seriesNextUpPlayed() async {
        let api = MockAPIClient()
        api.stubbedNextUp = makeEpisode(id: "e7", name: "Épisode 7", positionTicks: 1_200_000_000, isPlayed: true)
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "e7")
        #expect(target.startSeconds == nil)
    }

    @Test("Série sans next-up : on retombe sur l'id de série, getPlaybackInfo tranchera")
    func seriesWithoutNextUp() async {
        let api = MockAPIClient()
        api.stubbedNextUp = nil
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "s1")
        #expect(target.title == "Ma série")
        #expect(target.startSeconds == nil)
    }

    @Test("Série dont le sondage next-up échoue : dégrade sans jeter")
    func seriesNextUpThrows() async {
        let api = MockAPIClient()
        api.nextUpShouldThrow = true
        let target = await CardPlayTargetResolver.resolve(
            itemId: "s1", type: .series, title: "Ma série",
            positionTicks: 0, isPlayed: false,
            api: api, userId: "u1"
        )
        #expect(target.itemId == "s1")
        #expect(target.startSeconds == nil)
    }
}
```

- [x] **Step 3 : vérifier que les tests échouent**

Run:
```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'Suite "CardPlayTarget|error:' | head -20
```
Expected: échec de compilation, `cannot find 'CardPlayTargetResolver' in scope`.

- [x] **Step 4 : écrire l'implémentation**

Créer `Shared/ViewModels/CardPlayTarget.swift` :

```swift
import Foundation
import CinemaxKit
import JellyfinAPI

/// Ce qu'une carte doit connaître pour lancer une lecture : quoi ouvrir, sous
/// quel titre, et à quelle seconde reprendre.
struct CardPlayTarget: Sendable, Equatable {
    let itemId: String
    let title: String
    /// `nil` ⇒ lecture depuis le début.
    let startSeconds: Double?
}

/// Résout la cible de lecture d'une vignette.
///
/// **Ce que ce résolveur ne fait PAS** : choisir l'épisode d'une série quand
/// l'information manque. `getPlaybackInfo` résout déjà Series/Season → Episode
/// côté CinemaxKit (`resolvePlayableEpisode` — next-up d'abord, sinon premier
/// épisode de la première saison), et dupliquer cette décision créerait deux
/// autorités qui peuvent diverger. Il ne sert qu'à récupérer **la position de
/// reprise**, plus l'id de l'épisode quand le sondage next-up le donne — auquel
/// cas on cible directement l'épisode, pour que l'offset et l'item décrivent
/// forcément le même média.
///
/// Volontairement `nonisolated` et paramétré par des **scalaires** : passer un
/// `BaseItemDto` (non-`Sendable`) dans un appel async nonisolated depuis le
/// `@MainActor` est un transfert de région d'une valeur que l'acteur principal
/// détient toujours. L'appelant extrait les champs côté main actor.
enum CardPlayTargetResolver {

    static func resolve(
        itemId: String,
        type: BaseItemKind?,
        title: String,
        positionTicks: Int,
        isPlayed: Bool,
        api: any LibraryAPI,
        userId: String
    ) async -> CardPlayTarget {
        guard type == .series else {
            return CardPlayTarget(
                itemId: itemId,
                title: title,
                startSeconds: resumeSeconds(positionTicks: positionTicks, isPlayed: isPlayed)
            )
        }

        // Une carte de série ne porte pas la userData de son épisode next-up :
        // c'est le seul cas qui coûte un aller-retour. L'appel est mis en cache
        // 10 s côté client (préfixe `nextup-`), donc il est le plus souvent servi
        // localement juste après un affichage de fiche.
        guard let episode = try? await api.getNextUp(seriesId: itemId, userId: userId),
              let episodeId = episode.id else {
            return CardPlayTarget(itemId: itemId, title: title, startSeconds: nil)
        }

        return CardPlayTarget(
            itemId: episodeId,
            title: episode.name ?? title,
            startSeconds: resumeSeconds(
                positionTicks: episode.userData?.playbackPositionTicks ?? 0,
                isPlayed: episode.userData?.isPlayed ?? false
            )
        )
    }

    /// Même règle que `MediaDetailScreen.resolvedPlayTarget` : une position
    /// résiduelle sur un média déjà marqué vu ne vaut pas reprise.
    private static func resumeSeconds(positionTicks: Int, isPlayed: Bool) -> Double? {
        guard positionTicks > 0, !isPlayed else { return nil }
        return positionTicks.jellyfinSeconds
    }
}
```

- [x] **Step 5 : régénérer le projet Xcode**

Le fichier est nouveau sous `Shared/`, donc il n'existe pas encore dans la cible.

Run:
```bash
cd /Users/braillard/projets/perso/jellyfin/Cinemax && xcodegen generate
```

- [x] **Step 6 : vérifier que les tests passent**

Run:
```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'Suite "|✘|error:' | head -40
```
Expected: `Suite "CardPlayTarget" passed with 8 tests.`, aucun `✘`, aucune suite préexistante en échec.

- [x] **Step 7 : commit**

```bash
git add Shared/ViewModels/CardPlayTarget.swift Tests/CinemaxKitTests/CardPlayTargetTests.swift Tests/CinemaxKitTests/MockAPIClient.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(cards): résolveur de cible de lecture pour les vignettes

Ne choisit pas l'épisode d'une série — getPlaybackInfo le fait déjà — mais
récupère la position de reprise, et l'id d'épisode quand le next-up le donne.
Nonisolated + paramètres scalaires : un BaseItemDto ne peut pas traverser.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2 : `CardActionPresenter` + l'entrée « Lecture »

**Files:**
- Create: `Shared/Screens/CardActionPresenter.swift`
- Modify: `Shared/Screens/MediaCardContextMenu.swift`
- Modify: `Shared/Navigation/AppNavigation.swift:757` (déclaration `@State`) et `:849-859` (injection + modificateur)
- Modify: `Shared/Screens/Settings/SettingsScreen.swift:404-414` (`watchedHistorySheet` — réinjection)
- Modify: `Resources/fr.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`
- Modify: `CLAUDE.md` (amendement de la RULE `PlayLink`)

**Interfaces:**
- Consumes: `CardPlayTarget` / `CardPlayTargetResolver.resolve` (Task 1), `VideoPlayerCoordinator.play(itemId:title:startTime:previousEpisode:nextEpisode:episodeNavigator:mediaSourceId:using:)`, `VideoPlayerView(itemId:title:startTime:previousEpisode:nextEpisode:episodeNavigator:mediaSourceId:)`, `EpisodeRef`, `EpisodeNavigator`.
- Produces:
  - `@MainActor @Observable final class CardActionPresenter` avec `var playback: CardPlaybackRequest?`, `var remotePlay: RemotePlayIntent?` (utilisé en Task 3), `var knownRemoteTargetCount: Int?` (Task 3), et `func present(playback:)`.
  - `struct CardPlaybackRequest: Identifiable` — `id`, `itemId`, `title`, `startTime`, `previousEpisode`, `nextEpisode`, `episodeNavigator`.
  - `struct CardPlaybackNavigation` — `previous: EpisodeRef?`, `next: EpisodeRef?`, `navigator: EpisodeNavigator?`.
  - `struct CardPlaybackPresentation: ViewModifier`.
  - `mediaCardContextMenu(item:navigation:)` — le paramètre `navigation` a pour défaut `nil`, donc les 3 appels existants ne bougent pas.

- [x] **Step 1 : créer le présentateur et sa présentation racine**

Créer `Shared/Screens/CardActionPresenter.swift` :

```swift
import SwiftUI
import CinemaxKit

/// Ce qu'une lecture lancée depuis une vignette doit transporter — exactement
/// les arguments de `VideoPlayerView`. Pas de `mediaSourceId` : le choix de
/// version est une décision de la fiche détail (sa rangée « Version »), une
/// carte n'en a aucune.
struct CardPlaybackRequest: Identifiable {
    let id = UUID()
    let itemId: String
    let title: String
    let startTime: Double?
    let previousEpisode: EpisodeRef?
    let nextEpisode: EpisodeRef?
    let episodeNavigator: EpisodeNavigator?
}

/// Le trio prev / next / navigateur que `PlayLink` prend déjà, regroupé pour ne
/// pas propager trois paramètres à travers le modificateur de menu. Les rangées
/// de l'accueil le possèdent (`resumeNavigation` / `nextUpNavigation`) ; partout
/// ailleurs il est `nil` et le lecteur n'affiche pas ses boutons épisode —
/// dégradation déjà en vigueur pour les rangées qui les omettent.
struct CardPlaybackNavigation {
    let previous: EpisodeRef?
    let next: EpisodeRef?
    let navigator: EpisodeNavigator?
}

/// Porte les requêtes qu'un menu contextuel ne peut pas présenter lui-même.
///
/// Un `contextMenu` est accroché à une carte vivant dans un `LazyVGrid` /
/// `LazyHStack` : SwiftUI y ignore silencieusement `navigationDestination(item:)`
/// et une présentation attachée à un enfant lazy meurt avec la cellule recyclée.
/// Même raison et même forme que `AddToPlaylistPresenter` — un modèle minimal,
/// hébergé une seule fois sur `AppNavigation`.
///
/// **iOS seulement pour `playback`** : sur tvOS le menu appelle directement
/// `VideoPlayerCoordinator`, qui est déjà un présentateur racine.
@MainActor
@Observable
final class CardActionPresenter {
    var playback: CardPlaybackRequest?
    var remotePlay: RemotePlayIntent?
    /// Nombre de cibles « Lire sur… » connu du dernier sondage réel, `nil` tant
    /// qu'aucun n'a eu lieu. Aucun sondage spéculatif n'est déclenché ici.
    var knownRemoteTargetCount: Int?

    func present(playback request: CardPlaybackRequest) {
        playback = request
    }

    func present(remotePlay intent: RemotePlayIntent) {
        remotePlay = intent
    }
}

#if os(iOS)
/// Héberge le lecteur à la racine. `VideoPlayerView` n'est qu'une coquille de
/// chargement : le lecteur réel est présenté par-dessus en modal UIKit, et sa
/// fermeture appelle `dismiss()` — ce qui referme ce cover aussi bien que cela
/// dépilerait un push. Les objets d'environnement sont réinjectés, comme pour
/// `AddToPlaylistPresentation`.
struct CardPlaybackPresentation: ViewModifier {
    @Binding var request: CardPlaybackRequest?
    let appState: AppState
    let themeManager: ThemeManager
    let loc: LocalizationManager
    let toast: ToastCenter

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $request) { request in
            VideoPlayerView(
                itemId: request.itemId,
                title: request.title,
                startTime: request.startTime,
                previousEpisode: request.previousEpisode,
                nextEpisode: request.nextEpisode,
                episodeNavigator: request.episodeNavigator
            )
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toast)
        }
    }
}
#endif
```

- [x] **Step 2 : héberger le présentateur à la racine**

Dans `Shared/Navigation/AppNavigation.swift`, après la ligne 757 (`@State private var playlistPresenter = AddToPlaylistPresenter()`), ajouter :

```swift
    @State private var cardActions = CardActionPresenter()
```

Puis, juste après le bloc `.modifier(AddToPlaylistPresentation(...))` (qui se termine ligne 859), insérer :

```swift
        .environment(cardActions)
        // Même raison que la feuille playlists : la lecture est lancée depuis des
        // menus contextuels dans des grilles lazy, où une présentation attachée à
        // la cellule meurt avec elle. tvOS n'a rien à héberger ici — le menu y
        // appelle directement `VideoPlayerCoordinator`.
        #if os(iOS)
        .modifier(CardPlaybackPresentation(
            request: $cardActions.playback,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toasts
        ))
        #endif
```

- [x] **Step 3 : réinjecter dans la feuille « Historique de visionnage »**

`WatchedHistoryScreen` est présenté modalement depuis les réglages et **ne reçoit pas** l'environnement racine — c'est déjà pourquoi `toasts` et `playlists` y sont réinjectés à la main. Sans cet ajout, la nouvelle entrée « Lecture » disparaîtrait silencieusement de ses cartes (et sur tvOS, faute de coordinator, aussi).

Dans `Shared/Screens/Settings/SettingsScreen.swift`, ajouter la lecture d'environnement à côté des autres `@Environment` de la vue :

```swift
    @Environment(CardActionPresenter.self) private var cardActions
    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var playerCoordinator
    #endif
```

Puis étendre `watchedHistorySheet` (ligne 404) :

```swift
    private var watchedHistorySheet: some View {
        WatchedHistoryScreen()
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toasts)
            // Its cards carry `mediaCardContextMenu`, whose "add to a playlist"
            // entry reads this presenter. A modal doesn't inherit the root's
            // environment here — same reason `toasts` is re-injected above.
            .environment(playlists)
            // Same reason, for the menu's play / "play on…" entries.
            .environment(cardActions)
            #if os(tvOS)
            .environment(playerCoordinator)
            #endif
    }
```

- [x] **Step 4 : ajouter les entrées de lecture au menu**

Dans `Shared/Screens/MediaCardContextMenu.swift`, remplacer l'extension et l'en-tête du `ViewModifier` :

```swift
extension View {
    func mediaCardContextMenu(
        item: BaseItemDto,
        navigation: CardPlaybackNavigation? = nil
    ) -> some View {
        modifier(MediaCardContextMenu(item: item, navigation: navigation))
    }
}
```

Dans `private struct MediaCardContextMenu`, ajouter aux lectures d'environnement (toutes **optionnelles**, même règle que `playlists`) et aux propriétés :

```swift
    @Environment(CardActionPresenter.self) private var cardActions: CardActionPresenter?
    #if os(tvOS)
    @Environment(VideoPlayerCoordinator.self) private var coordinator: VideoPlayerCoordinator?
    #endif

    let item: BaseItemDto
    let navigation: CardPlaybackNavigation?
```

Puis, en **tête** du `contextMenu { … }` (avant le bouton « marquer vu »), insérer le groupe lecture. `localResume` n'est calculé que pour les types dont la carte porte la userData utile — une carte de série ne connaît pas celle de son épisode next-up, donc son libellé reste « Lecture » et « Lire depuis le début » ne s'affiche pas :

```swift
        let isPlayable = item.type == .movie || item.type == .series || item.type == .episode
        let localResume: Bool = {
            guard item.type == .movie || item.type == .episode else { return false }
            guard let ticks = item.userData?.playbackPositionTicks, ticks > 0 else { return false }
            return !(item.userData?.isPlayed ?? false)
        }()
```

```swift
            if isPlayable {
                Button {
                    Task { await startPlayback(fromStart: false) }
                } label: {
                    Label(
                        loc.localized(localResume ? "card.resume" : "card.play"),
                        systemImage: "play.fill"
                    )
                }
                if localResume {
                    Button {
                        Task { await startPlayback(fromStart: true) }
                    } label: {
                        Label(loc.localized("card.playFromStart"), systemImage: "gobackward")
                    }
                }
                Divider()
            }
```

Enfin, ajouter la méthode. Les scalaires sont extraits **avant** l'`await` : le résolveur est nonisolated et un `BaseItemDto` ne peut pas traverser.

```swift
    /// Lance la lecture. Sur tvOS via le `VideoPlayerCoordinator` (déjà un
    /// présentateur racine, exactement ce que fait `PlayLink`) ; sur iOS via le
    /// `fullScreenCover` hébergé par `AppNavigation`, parce qu'un bouton de menu
    /// dans un conteneur lazy ne peut pas pousser de `NavigationLink`.
    private func startPlayback(fromStart: Bool) async {
        guard let userId = appState.currentUserId, let id = item.id else { return }

        // Scalaires extraits ici, sur le main actor : `resolve` est nonisolated
        // et `BaseItemDto` n'est pas Sendable.
        let type = item.type
        let title = item.name ?? ""
        let ticks = item.userData?.playbackPositionTicks ?? 0
        let played = item.userData?.isPlayed ?? false

        let target = await CardPlayTargetResolver.resolve(
            itemId: id, type: type, title: title,
            positionTicks: ticks, isPlayed: played,
            api: appState.apiClient, userId: userId
        )
        let startTime = fromStart ? nil : target.startSeconds

        #if os(tvOS)
        coordinator?.play(
            itemId: target.itemId, title: target.title, startTime: startTime,
            previousEpisode: navigation?.previous, nextEpisode: navigation?.next,
            episodeNavigator: navigation?.navigator,
            using: appState
        )
        #else
        cardActions?.present(playback: CardPlaybackRequest(
            itemId: target.itemId, title: target.title, startTime: startTime,
            previousEpisode: navigation?.previous, nextEpisode: navigation?.next,
            episodeNavigator: navigation?.navigator
        ))
        #endif
    }
```

- [x] **Step 5 : ajouter les clés de localisation**

Dans `Resources/fr.lproj/Localizable.strings`, à côté du bloc `card.*` existant (vers la ligne 858) :

```
"card.play" = "Lecture";
"card.resume" = "Reprendre";
"card.playFromStart" = "Lire depuis le début";
```

Dans `Resources/en.lproj/Localizable.strings`, au même endroit relatif :

```
"card.play" = "Play";
"card.resume" = "Resume";
"card.playFromStart" = "Play from beginning";
```

- [x] **Step 6 : amender la RULE dans CLAUDE.md**

Sans cet amendement, le prochain lecteur de CLAUDE.md prendra ce lot pour une violation. Dans la section « Navigation », remplacer la ligne :

```
- **RULE — All play buttons use `PlayLink<Label>`** (Button+coordinator on tvOS, `NavigationLink` on iOS) — never direct `NavigationLink` to `VideoPlayerView`.
```

par :

```
- **RULE — All play buttons use `PlayLink<Label>`** (Button+coordinator on tvOS, `NavigationLink` on iOS) — never direct `NavigationLink` to `VideoPlayerView`. **One exception: context-menu playback**, which cannot push a `NavigationLink` (the menu hangs off a card inside a lazy container — see the lazy-container RULE). It routes through `CardActionPresenter` instead: tvOS calls the same `VideoPlayerCoordinator` `PlayLink` would, iOS raises a root-hosted `.fullScreenCover` onto the same `VideoPlayerView`. Both engines and every controller are therefore identical; only the SwiftUI host differs.
```

- [x] **Step 7 : régénérer et compiler les deux plateformes**

Run:
```bash
cd /Users/braillard/projets/perso/jellyfin/Cinemax && xcodegen generate
```
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -30
```
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **` pour les deux, lancées **séquentiellement** (course sur `build.db` sinon).

- [ ] **Step 8 : vérifier à la main sur simulateur iOS**

Lancer l'app, aller dans la bibliothèque Films, appui long sur une affiche.
Attendu : « Lecture » en tête du menu ; le toucher ouvre le lecteur en plein écran ; le fermer ramène **sur la grille**, pas sur un écran intermédiaire. Sur un film à demi vu, le libellé est « Reprendre » et « Lire depuis le début » apparaît juste dessous.

- [x] **Step 9 : commit**

```bash
git add Shared/Screens/CardActionPresenter.swift Shared/Screens/MediaCardContextMenu.swift Shared/Navigation/AppNavigation.swift Shared/Screens/Settings/SettingsScreen.swift Resources/fr.lproj/Localizable.strings Resources/en.lproj/Localizable.strings CLAUDE.md Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(cards): lancer la lecture depuis le menu contextuel

CardActionPresenter hébergé à la racine — un bouton de menu dans un conteneur
lazy ne peut ni pousser un NavigationLink ni héberger sa présentation. tvOS
délègue au VideoPlayerCoordinator existant, iOS à un fullScreenCover racine.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3 : « Lire sur… » depuis le menu

**Files:**
- Modify: `Shared/Screens/MediaCardContextMenu.swift`
- Modify: `Shared/Navigation/AppNavigation.swift` (montage de `RemotePlayPresentation` à la racine)
- Modify: `Shared/Screens/MediaDetailScreen.swift:54` et `:147-153` (adoption du présentateur)
- Modify: `Shared/ViewModels/MediaDetailViewModel.swift:375-390` (`loadRemoteTargets` publie le compteur)

**Interfaces:**
- Consumes: `CardActionPresenter.remotePlay` / `.knownRemoteTargetCount` / `present(remotePlay:)` (Task 2), `RemotePlayIntent(itemId:title:startPositionTicks:mediaSourceId:)`, `RemotePlayPresentation(sheet:appState:themeManager:loc:toast:)`.
- Produces: `MediaDetailViewModel.loadRemoteTargets(using:cardActions:)` — nouveau second paramètre optionnel `CardActionPresenter?`.

- [x] **Step 1 : monter `RemotePlayPresentation` à la racine**

Dans `Shared/Navigation/AppNavigation.swift`, juste après le bloc `CardPlaybackPresentation` ajouté en Task 2 (et **hors** de son `#if os(iOS)` — celui-ci est cross-plateforme) :

```swift
        // « Lire sur… » est désormais aussi levé depuis les menus contextuels,
        // donc la feuille est hébergée ici plutôt que par la fiche détail. Le
        // modificateur prend déjà un binding : c'est un déplacement, pas une
        // réécriture.
        .modifier(RemotePlayPresentation(
            sheet: $cardActions.remotePlay,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toasts
        ))
```

- [x] **Step 2 : faire adopter le présentateur par la fiche détail**

Dans `Shared/Screens/MediaDetailScreen.swift`, supprimer la ligne 54 :

```swift
    @State private var remotePlaySheet: RemotePlayIntent?
```

et le bloc `.modifier(RemotePlayPresentation(...))` des lignes 147-153. Ajouter la lecture du présentateur à côté des autres `@Environment` :

```swift
    @Environment(CardActionPresenter.self) private var cardActions: CardActionPresenter?
```

Remplacer les deux affectations (lignes ~980 et ~1057) :

```swift
                    remotePlaySheet = remotePlayIntent(for: item)
```

par :

```swift
                    cardActions?.present(remotePlay: remotePlayIntent(for: item))
```

- [x] **Step 3 : publier le compteur de cibles**

Dans `Shared/ViewModels/MediaDetailViewModel.swift`, changer la signature de `loadRemoteTargets` (ligne 375) et publier le compteur après la résolution :

```swift
    func loadRemoteTargets(using appState: AppState, cardActions: CardActionPresenter? = nil) async {
        guard let userId = appState.currentUserId else { return }
        do {
            let sessions = try await appState.apiClient.getControllableSessions(userId: userId)
            remoteTargets = RemotePlayTarget.resolve(
                sessions: sessions,
                currentUserId: userId,
                excludingDeviceId: KeychainService.getOrCreateDeviceID()
            )
            // Le menu contextuel ne peut pas sonder avant de se dessiner : il lit
            // ce compteur, écrit uniquement par un sondage réel. Aucune requête
            // spéculative n'est ajoutée.
            cardActions?.knownRemoteTargetCount = remoteTargets.count
        } catch {
            // Inchangé : ne pas avoir de cible est le cas ordinaire, un échec de
            // sondage dégrade en « pas de bouton », jamais en écran d'erreur.
            // `knownRemoteTargetCount` n'est délibérément PAS remis à 0 ici — un
            // échec réseau ne prouve pas l'absence de cible, et l'écraser ferait
            // disparaître l'entrée du menu après un simple hoquet.
            logger.debug("Remote targets probe failed: \(error.localizedDescription, privacy: .public)")
            remoteTargets = []
        }
    }
```

Seules la signature et la ligne `cardActions?.knownRemoteTargetCount` sont des ajouts ; le reste du corps est repris à l'identique.

Répercuter l'appelant ligne 136 :

```swift
        Task { await loadRemoteTargets(using: appState, cardActions: cardActions) }
```

`load(using:)` doit donc recevoir le présentateur. Ajouter le paramètre à sa signature (`func load(using appState: AppState, cardActions: CardActionPresenter? = nil) async`) et le passer depuis `MediaDetailScreen` à ses appels de `load` : `await viewModel.load(using: appState, cardActions: cardActions)`.

- [x] **Step 4 : ajouter l'entrée au menu**

Dans `Shared/Screens/MediaCardContextMenu.swift`, à l'intérieur du bloc `if isPlayable { … }`, après le bouton « Lire depuis le début » et **avant** le `Divider()` :

```swift
                // Cache froid ⇒ on affiche l'entrée (optimiste). C'est ce qui
                // évite une entrée morte permanente pour qui n'a pas d'Apple TV
                // sans ajouter de sondage à chaque ouverture de menu — un
                // `contextMenu` se construit de façon synchrone et ne peut pas
                // attendre. La feuille re-sonde à l'ouverture et possède déjà son
                // état vide (`remote.noTargets.*`).
                if let cardActions, cardActions.knownRemoteTargetCount ?? 1 > 0 {
                    Button {
                        Task { await startRemotePlay() }
                    } label: {
                        Label(loc.localized("remote.title"), systemImage: "tv.badge.wifi")
                    }
                }
```

Et la méthode, qui réutilise le même résolveur pour envoyer **ce que Lecture aurait ouvert** :

```swift
    /// Envoie vers une autre session ce que « Lecture » aurait lancé ici, en
    /// passant par le même résolveur — donc une série envoie son épisode next-up
    /// et un film à demi vu reprend où il s'était arrêté.
    private func startRemotePlay() async {
        guard let userId = appState.currentUserId, let id = item.id else { return }
        let type = item.type
        let title = item.name ?? ""
        let ticks = item.userData?.playbackPositionTicks ?? 0
        let played = item.userData?.isPlayed ?? false

        let target = await CardPlayTargetResolver.resolve(
            itemId: id, type: type, title: title,
            positionTicks: ticks, isPlayed: played,
            api: appState.apiClient, userId: userId
        )
        cardActions?.present(remotePlay: RemotePlayIntent(
            itemId: target.itemId,
            title: target.title,
            startPositionTicks: target.startSeconds.map { Int($0 * 10_000_000) },
            // Une carte n'a pas de choix de version — c'est une décision de la
            // rangée « Version » de la fiche détail.
            mediaSourceId: nil
        ))
    }
```

- [x] **Step 5 : compiler les deux plateformes**

Run:
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -30
```
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **` pour les deux.

- [ ] **Step 6 : vérifier la non-régression de la fiche détail**

Sur simulateur iOS : ouvrir une fiche de film, toucher la puce « Lire sur… » du bloc d'actions secondaires. La feuille doit s'ouvrir exactement comme avant le déplacement (liste ou état vide `remote.noTargets.*`). C'est le seul chemin que ce lot déplace.

- [x] **Step 7 : commit**

```bash
git add Shared/Screens/MediaCardContextMenu.swift Shared/Navigation/AppNavigation.swift Shared/Screens/MediaDetailScreen.swift Shared/ViewModels/MediaDetailViewModel.swift
git commit -m "feat(cards): « Lire sur… » depuis le menu contextuel

La feuille passe de la fiche détail à la racine (le modificateur prenait déjà
un binding). L'entrée lit un compteur de cibles écrit par les sondages réels —
un contextMenu se construit de façon synchrone et ne peut pas sonder.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4 : le rail « Reprendre » adopte le menu partagé

**Files:**
- Modify: `Shared/Screens/MediaCardContextMenu.swift` (entrée « Retirer de Reprendre »)
- Modify: `Shared/Screens/HomeScreen.swift:764-786` (`continueWatchingPlayLink`)

**Interfaces:**
- Consumes: `CardPlaybackNavigation` (Task 2), `HomeViewModel.resumeNavigation`, `HomeViewModel.removeResumeItem(_:using:toast:loc:)`.
- Produces: `mediaCardContextMenu(item:navigation:onRemoveFromResume:)` — troisième paramètre, défaut `nil`.

Le rail « Reprendre » possède aujourd'hui son **propre** menu (marquer vu + retirer), sans favori ni playlist. Lui donner le menu partagé sans reprendre « Retirer de Reprendre » serait une **régression** : c'est pourquoi l'entrée arrive ici.

- [x] **Step 1 : ajouter le rappel et l'entrée destructive au menu**

Dans `Shared/Screens/MediaCardContextMenu.swift`, étendre l'extension :

```swift
extension View {
    func mediaCardContextMenu(
        item: BaseItemDto,
        navigation: CardPlaybackNavigation? = nil,
        onRemoveFromResume: (() -> Void)? = nil
    ) -> some View {
        modifier(MediaCardContextMenu(
            item: item, navigation: navigation, onRemoveFromResume: onRemoveFromResume
        ))
    }
}
```

Ajouter la propriété au `ViewModifier` :

```swift
    let onRemoveFromResume: (() -> Void)?
```

Puis, **en queue** du `contextMenu { … }` (après « Ajouter à une playlist ») :

```swift
            // La présence du rappel prouve que l'écran hôte sait retirer la carte
            // de sa rangée ; le rail « Reprendre » de l'accueil est le seul à le
            // fournir. La position de reprise est la condition métier : sans
            // elle, l'item n'est pas dans la rangée.
            if let onRemoveFromResume, (item.userData?.playbackPositionTicks ?? 0) > 0 {
                Divider()
                Button(role: .destructive) {
                    onRemoveFromResume()
                } label: {
                    Label(loc.localized("home.continueWatching.remove"), systemImage: "minus.circle")
                }
            }
```

- [x] **Step 2 : basculer le rail Reprendre sur le menu partagé**

Dans `Shared/Screens/HomeScreen.swift`, remplacer le bloc `.contextMenu { … }` de `continueWatchingPlayLink` (lignes ~764-786, du commentaire « Long-press (iOS) / long-press-select (tvOS) context menu » jusqu'à la fermeture du `.contextMenu`) par :

```swift
            // Menu partagé (`MediaCardContextMenu`) : lecture, « Lire sur… »,
            // vu, favori, playlist — plus « Retirer de Reprendre », propre à
            // cette rangée et fourni par le rappel ci-dessous. Accroché au
            // PlayLink, pas à son label, pour ne pas perturber le focus tvOS.
            .mediaCardContextMenu(
                item: item,
                navigation: CardPlaybackNavigation(
                    previous: nav?.previous, next: nav?.next, navigator: nav?.navigator
                ),
                onRemoveFromResume: {
                    Task { await viewModel.removeResumeItem(item, using: appState, toast: toast, loc: loc) }
                }
            )
```

`markResumeItemPlayed` n'est plus appelé depuis ici — le menu partagé fait le marquage vu et publie la notification tier-2 `.cinemaxItemUserDataChanged`, que l'accueil consomme déjà via `refreshUserDataRails()`. Vérifier avec un `grep -rn "markResumeItemPlayed" Shared` si la méthode devient orpheline ; si oui, la supprimer de `HomeViewModel` dans le même commit.

- [x] **Step 3 : compiler les deux plateformes**

Run:
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -30
```
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **` pour les deux.

- [x] **Step 4 : lancer la suite de tests**

`HomeViewModelTests` couvre `removeResumeItem` et les rails ; une suppression de méthode orpheline peut le casser.

Run:
```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'Suite "|✘|error:' | head -40
```
Expected: aucune ligne `✘`.

- [ ] **Step 5 : vérifier à la main**

Sur simulateur iOS, appui long sur une carte « Reprendre » de l'accueil.
Attendu : « Reprendre » en tête (la carte a une position), « Lire depuis le début », « Lire sur… », puis vu / favori / playlist, puis « Retirer de Reprendre » en rouge tout en bas. Le toucher retire la carte de la rangée.

- [x] **Step 6 : commit**

```bash
git add Shared/Screens/MediaCardContextMenu.swift Shared/Screens/HomeScreen.swift Shared/ViewModels/HomeViewModel.swift
git commit -m "feat(home): le rail Reprendre adopte le menu contextuel partagé

Gagne lecture, « Lire sur… », favori et playlist ; « Retirer de Reprendre »
devient une entrée conditionnelle du menu partagé pour ne pas la perdre.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5 : couvrir les cinq surfaces restantes

**Files:**
- Modify: `Shared/Screens/HomeScreen.swift` (`nextUpPlayLink` ~844-862, `recentlyAddedCard` ~915-940)
- Modify: `Shared/Screens/FavoritesScreen.swift:202-215`
- Modify: `Shared/Screens/PersonDetailScreen.swift:113-130`
- Modify: `Shared/Screens/MediaDetailSimilarSection.swift:40-60`

**Interfaces:**
- Consumes: `mediaCardContextMenu(item:navigation:onRemoveFromResume:)` (Tasks 2-4), `HomeViewModel.nextUpNavigation`.
- Produces: rien de nouveau.

`recentlyAddedCard` est partagé par **trois** rangées de l'accueil (Ajouts récents, Favoris, genres) : une seule édition les couvre toutes. `LibraryFolderBrowseScreen` reste volontairement exclu — il liste des dossiers, pas des médias.

- [x] **Step 1 : rail Next Up**

Dans `Shared/Screens/HomeScreen.swift`, dans `nextUpPlayLink`, après la ligne `.accessibilityLabel(item.seriesName ?? item.name ?? "")` :

```swift
            .mediaCardContextMenu(
                item: item,
                navigation: CardPlaybackNavigation(
                    previous: nav?.previous, next: nav?.next, navigator: nav?.navigator
                )
            )
```

- [x] **Step 2 : Ajouts récents / Favoris / genres**

Dans `recentlyAddedCard`, après la ligne `.accessibilityLabel([item.name, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: ", "))` :

```swift
        .mediaCardContextMenu(item: item)
```

- [x] **Step 3 : écran Favoris**

Dans `Shared/Screens/FavoritesScreen.swift`, sur le `NavigationLink` de la carte (ligne ~202), après son `.accessibilityLabel(...)` :

```swift
            .mediaCardContextMenu(item: item)
```

Accroché au `NavigationLink`, jamais à son `label` — règle de focus tvOS.

- [x] **Step 4 : filmographie**

Dans `Shared/Screens/PersonDetailScreen.swift`, sur le `NavigationLink` de la carte (ligne ~113), après son `.accessibilityLabel(...)` :

```swift
            .mediaCardContextMenu(item: item)
```

- [x] **Step 5 : titres similaires**

Dans `Shared/Screens/MediaDetailSimilarSection.swift`, sur le `NavigationLink` (ligne ~40), après son `.accessibilityLabel(...)` :

```swift
            .mediaCardContextMenu(item: item)
```

- [x] **Step 6 : compiler les deux plateformes**

Run:
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -30
```
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **` pour les deux.

- [ ] **Step 7 : vérifier le focus tvOS**

Sur simulateur Apple TV : parcourir l'accueil, appui long (select maintenu) sur une carte de chaque rangée. Le menu s'ouvre et, **à sa fermeture, le focus revient sur la carte d'origine** — pas sur la pastille d'onglet actif en haut. Un focus qui saute signale que le menu a été accroché au label au lieu du bouton.

- [x] **Step 8 : commit**

```bash
git add Shared/Screens/HomeScreen.swift Shared/Screens/FavoritesScreen.swift Shared/Screens/PersonDetailScreen.swift Shared/Screens/MediaDetailSimilarSection.swift
git commit -m "feat(cards): menu contextuel sur les sept surfaces orphelines

Next Up, Ajouts récents, Favoris et genres de l'accueil (une seule édition,
les trois dernières partagent recentlyAddedCard), écran Favoris, filmographie
et titres similaires.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6 : « Aller à la série »

**Files:**
- Modify: `Shared/Screens/MediaCardContextMenu.swift`
- Modify: `Shared/Screens/HomeScreen.swift` (état hôte + destination + les deux rails à épisodes)
- Modify: `Shared/Screens/SearchScreen.swift` (état hôte + destination + `SearchResultCard`)
- Modify: `Shared/Screens/WatchedHistoryScreen.swift` (état hôte + destination + carte, ligne ~283)
- Modify: `Resources/fr.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `mediaCardContextMenu(item:navigation:onRemoveFromResume:)` (Tasks 2-4), `MediaDetailScreen(itemId:itemType:)`.
- Produces: `mediaCardContextMenu(item:navigation:onRemoveFromResume:onGoToSeries:)` — quatrième paramètre, défaut `nil`. Le rappel reçoit l'**id de la série** (`String`), pas le DTO.

C'est l'approche C : la destination est hébergée par l'écran, hors du conteneur lazy, exactement comme `AdminItemMenu.onSelectDestination`. La présence du rappel est ce qui **fait apparaître** l'entrée — une grille qui oublie la plomberie n'affiche simplement rien, au lieu d'offrir un bouton mort.

- [x] **Step 1 : ajouter le paramètre et l'entrée au menu**

Dans `Shared/Screens/MediaCardContextMenu.swift`, étendre l'extension :

```swift
extension View {
    func mediaCardContextMenu(
        item: BaseItemDto,
        navigation: CardPlaybackNavigation? = nil,
        onRemoveFromResume: (() -> Void)? = nil,
        onGoToSeries: ((String) -> Void)? = nil
    ) -> some View {
        modifier(MediaCardContextMenu(
            item: item, navigation: navigation,
            onRemoveFromResume: onRemoveFromResume, onGoToSeries: onGoToSeries
        ))
    }
}
```

Ajouter la propriété :

```swift
    let onGoToSeries: ((String) -> Void)?
```

Déclarer aussi le jeton de destination **en portée de fichier** dans ce même fichier — les trois écrans hôtes le partagent, donc il ne peut pas être imbriqué dans l'un d'eux (`HomeScreen.FavoritesDestination` est un `private struct` **imbriqué**, ne pas le prendre pour modèle ici) :

```swift
/// Jeton de destination pour « Aller à la série ». Déclaré ici, avec le rappel
/// qui produit son id, parce que les trois écrans hôtes (accueil, recherche,
/// historique) l'utilisent tous.
struct SeriesDestination: Identifiable, Hashable {
    let id: String
}
```

Puis, **après** le `Divider()` du groupe lecture et **avant** « Marquer comme vu » :

```swift
            // Le rappel est fourni par les seuls écrans qui hébergent la
            // destination hors de leur conteneur lazy (SwiftUI y ignorerait
            // silencieusement `navigationDestination`) — même contrat que
            // `AdminItemMenu.onSelectDestination`. Sa présence est ce qui fait
            // apparaître l'entrée, donc pas de bouton mort possible.
            if let onGoToSeries, item.type == .episode, let seriesId = item.seriesID {
                Button {
                    onGoToSeries(seriesId)
                } label: {
                    Label(loc.localized("card.goToSeries"), systemImage: "rectangle.stack")
                }
                Divider()
            }
```

- [x] **Step 2 : clés de localisation**

`Resources/fr.lproj/Localizable.strings` :

```
"card.goToSeries" = "Aller à la série";
```

`Resources/en.lproj/Localizable.strings` :

```
"card.goToSeries" = "Go to series";
```

- [x] **Step 3 : hôte de l'accueil**

Dans `Shared/Screens/HomeScreen.swift`, ajouter le jeton d'état à côté des autres `@State` de l'écran :

```swift
    /// Cible de « Aller à la série », levée depuis un menu contextuel de carte.
    /// L'état vit ici et la destination est accrochée au corps de l'écran :
    /// SwiftUI ignore `navigationDestination(item:)` à l'intérieur d'un
    /// `LazyHStack`, où vivent les cartes qui l'émettent.
    @State private var seriesDestination: SeriesDestination?
```

Le type `SeriesDestination` est déclaré à l'étape 1, dans `MediaCardContextMenu.swift` — pas ici.

Accrocher la destination sur le corps de l'écran, **au même niveau** que le `navigationDestination` existant de `favoritesDestination` :

```swift
        .navigationDestination(item: $seriesDestination) { destination in
            MediaDetailScreen(itemId: destination.id, itemType: .series)
        }
```

Passer le rappel dans les deux rails à épisodes. Dans `continueWatchingPlayLink`, compléter l'appel posé en Task 4 :

```swift
                onGoToSeries: { seriesDestination = SeriesDestination(id: $0) }
```

et dans `nextUpPlayLink`, compléter l'appel posé en Task 5 avec le même argument.

- [x] **Step 4 : hôte de la recherche**

Dans `Shared/Screens/SearchScreen.swift`, ajouter le même `@State private var seriesDestination: SeriesDestination?` sur l'écran, le même `.navigationDestination(item:)` sur son corps (hors du `LazyVGrid` des résultats), puis compléter l'appel ligne ~760 :

```swift
        .mediaCardContextMenu(
            item: item,
            onGoToSeries: { seriesDestination = SeriesDestination(id: $0) }
        )
```

La recherche renvoie des épisodes (`includeItemTypes` par défaut `[.movie, .series, .episode]`), donc l'entrée y est utile.

- [x] **Step 5 : hôte de l'historique**

Dans `Shared/Screens/WatchedHistoryScreen.swift`, même triptyque — `@State`, `.navigationDestination(item:)` sur le corps hors de la grille, puis ligne ~283 :

```swift
        .mediaCardContextMenu(
            item: item,
            onGoToSeries: { seriesDestination = SeriesDestination(id: $0) }
        )
```

L'écran est présenté modalement avec son propre `NavigationStack` (iOS `.sheet` / tvOS `.fullScreenCover`), donc la destination se pousse à l'intérieur de la feuille — comportement voulu.

- [x] **Step 6 : compiler les deux plateformes**

Run:
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -30
```
```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **` pour les deux.

- [ ] **Step 7 : vérifier à la main**

Sur simulateur iOS : appui long sur une carte « Reprendre » **d'épisode** → « Aller à la série » est présent et pousse la fiche de la série. Appui long sur une carte de **film** → l'entrée est absente. Dans la bibliothèque Films (aucun rappel fourni) → absente aussi, même pour un épisode.

- [x] **Step 8 : commit**

```bash
git add Shared/Screens/MediaCardContextMenu.swift Shared/Screens/HomeScreen.swift Shared/Screens/SearchScreen.swift Shared/Screens/WatchedHistoryScreen.swift Resources/fr.lproj/Localizable.strings Resources/en.lproj/Localizable.strings
git commit -m "feat(cards): « Aller à la série » depuis un épisode

Rappel remonté à l'écran hôte, qui héberge la destination hors du conteneur
lazy — même contrat qu'AdminItemMenu. Trois hôtes : accueil, recherche,
historique. Sa présence conditionne l'entrée, donc pas de bouton mort.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7 : vérification finale et mise à jour de CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (section Media Library — description du menu partagé)

**Interfaces:**
- Consumes: tout le lot.
- Produces: rien.

- [x] **Step 0 : traduire les commentaires de `CardPlayTarget.swift` en anglais**

Le fichier a été écrit en Task 1 avant que la contrainte « commentaires en anglais » ne soit explicitée dans ce plan, et il est le seul du lot à y déroger. Traduire chaque bloc `///` et chaque commentaire inline de `Shared/ViewModels/CardPlayTarget.swift` en anglais, **sans changer le contenu ni le niveau de détail** — les explications sur la non-isolation, sur le fait de ne PAS choisir l'épisode, et sur la règle de reprise sont la valeur du fichier, pas de la décoration. Aucune ligne de code exécutable ne change.

- [x] **Step 0b : nettoyer les deux résidus de la suppression de `markResumeItemPlayed` (Task 4)**

La suppression a laissé deux orphelins que la revue de Task 4 a relevés :

1. **Clé de localisation orpheline** — `home.continueWatching.markedWatched` n'a plus aucun appelant Swift (son seul consommateur était la méthode supprimée). La retirer de `Resources/fr.lproj/Localizable.strings` **et** de `Resources/en.lproj/Localizable.strings`. Vérifier d'abord par `grep -rn "home.continueWatching.markedWatched" Shared Widgets TopShelf Tests` que le résultat est bien vide — si une référence existe, ne pas supprimer et le signaler.
2. **`HomeViewModel.mutateResumeItem`** — son commentaire (« Shared body for both Continue Watching mutations ») est devenu faux : `removeResumeItem` en est le seul appelant et passe toujours `markPlayed: false`, si bien que la branche `if markPlayed { markItemPlayed }` est morte. Supprimer le paramètre `markPlayed` et sa branche, et réécrire le commentaire pour décrire ce que la méthode fait réellement maintenant. La suite de tests doit rester verte (`HomeViewModelTests` couvre `removeResumeItem`).

- [x] **Step 0c : commenter les cinq accroches ajoutées en Task 5**

Les quatre points d'accroche antérieurs au lot portent tous un commentaire court rappelant que le modificateur est posé sur la vue focusable et **non** sur son label (voir `LibraryPosterCard.swift`, `SearchScreen.swift`, `WatchedHistoryScreen.swift`). Les cinq ajouts de Task 5 n'en ont pas. Ce commentaire n'est pas décoratif : le placement est un invariant que **le compilateur ne vérifie pas** et dont la violation ne se voit qu'à l'usage, sur le focus tvOS. Ajouter une ligne ou deux, en anglais, au-dessus de chacun de : `HomeScreen.swift` (`nextUpPlayLink` et `recentlyAddedCard`), `FavoritesScreen.swift`, `PersonDetailScreen.swift`, `MediaDetailSimilarSection.swift`.

- [x] **Step 0d : corriger le sens de deux commentaires dans `SearchScreen.swift`**

Aux deux propriétés `onGoToSeries` (une sur `SearchResultsGrid`, une sur `SearchResultCard`), le commentaire dit « bubbled up » alors que c'est la **fermeture qui descend** l'arbre de vues ; seul l'**événement** remonte. Reformuler les deux pour décrire ce qui circule dans quel sens (par exemple « passed down to … » sur le conteneur, « invoked to bubble the event up to … » sur la carte). Un mot chacun.

- [x] **Step 1 : parité de localisation**

Run: invoquer la skill `localize-check`.
Expected: parité FR/EN sur les quatre nouvelles clés (`card.play`, `card.resume`, `card.playFromStart`, `card.goToSeries`), aucune chaîne en dur signalée dans les fichiers touchés.

- [x] **Step 2 : revue design system**

Run: invoquer la skill `design-system-review`.
Expected: aucune violation. Points de vigilance de ce lot : pas de `.font(.system(size: N))` nu (aucun ajouté ici), libellés de menu via `Label(loc.localized(...), systemImage:)`.

- [x] **Step 3 : suite de tests complète**

Run:
```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'Suite "|✘|error:' | head -60
```
Expected: `Suite "CardPlayTarget" passed with 8 tests.` présent, aucune ligne `✘`. Si le simulateur répond « preflight Busy », faire `xcrun simctl shutdown all` puis relancer une seule fois.

- [ ] **Step 4 : scénario PiP — la seule inconnue matérielle du lot**

C'est le risque nommé dans la spec : le lecteur devient un `fullScreenCover` racine au lieu d'un push, et `IOSPlayerDelegate.restoreUserInterface…` re-présente via un **nouveau** `PlayerHostingVC`.

Sur simulateur iOS (ou appareil) :
1. Lancer une lecture **depuis un menu contextuel** (pas depuis la fiche détail).
2. Déclencher le PiP (bouton PiP du lecteur, ou balayage vers l'accueil).
3. Vérifier que le lecteur se réduit et continue.
4. Toucher le bouton de restauration de la fenêtre PiP.

Attendu : le lecteur plein écran revient et la lecture continue au même endroit. Attendu en cas d'échec : rien ne se restaure, ou l'app revient sur une vue vide — auquel cas **arrêter et remonter le problème**, ne pas le contourner en catimini. Le repli documenté serait de router la lecture depuis les menus via l'approche C (rappel + `navigationDestination` par écran) au lieu du cover racine.

- [x] **Step 5 : mettre CLAUDE.md à jour**

Dans la section « Media Library », remplacer la RULE « Poster context menus » par une version décrivant le menu tel qu'il est désormais :

```
- **RULE — Poster context menus** (`MediaCardContextMenu.swift`, `.mediaCardContextMenu(item:navigation:onRemoveFromResume:onGoToSeries:)`): shared long-press (iOS) / long-press-select (tvOS) menu, attached to the card's focusable `NavigationLink`/`Button` — **never its label** (tvOS focus) — on every media-bearing surface: library grid + genre rows, search results, watched history, all four Home rails, Favorites, person filmography, similar titles. `LibraryFolderBrowseScreen` is excluded on purpose (it lists folders, not media). Entries, in order: **play group** (Play / Resume, Play from beginning, "Play on…"), **navigation** (Go to series), **state** (watched, favorite, add to playlist), **destructive** (Remove from Resume). The last three parameters all default to `nil`, and each one's presence is what renders its entry — a screen that skips the plumbing shows no entry instead of a dead button. State actions post the tier-2 `.cinemaxItemUserDataChanged` / `.cinemaxFavoritesChanged` as before. Reads `AppState`/`LocalizationManager`/`ToastCenter` from the environment, plus `AddToPlaylistPresenter`, `CardActionPresenter` and (tvOS) `VideoPlayerCoordinator` as **optionals** — a non-optional `@Environment(Type.self)` for an `@Observable` traps at runtime when absent, and these cards also live inside modally-presented hosts that re-inject the environment by hand (`SettingsScreen.watchedHistorySheet`).
  - **RULE — playback and "Play on…" go through the root-hosted `CardActionPresenter`** (`Shared/Screens/CardActionPresenter.swift`), never a local presentation: the menu hangs off a card inside a lazy container, where SwiftUI ignores `navigationDestination(item:)` and a presentation dies with the recycled cell. tvOS calls the same `VideoPlayerCoordinator` `PlayLink` would; iOS raises a root `.fullScreenCover` onto the same `VideoPlayerView`. `RemotePlayPresentation` moved from `MediaDetailScreen` to the root for the same reason, and the detail screen now raises it through the presenter too.
  - **RULE — the play target resolver takes ids and scalars, never a `BaseItemDto`** (`Shared/ViewModels/CardPlayTarget.swift`): it is `nonisolated`, so handing it the non-`Sendable` DTO from a `@MainActor` view would be a region transfer of a value the main actor still holds (same discipline as `LibraryAPI.fetchUserData`). It deliberately does **not** pick which episode of a series to play — `getPlaybackInfo` already resolves Series/Season → Episode server-side (`resolvePlayableEpisode`) and a second authority could diverge; it only fetches the **resume offset** (one cached `getNextUp` for a series, zero network for a movie or episode). Locked by `CardPlayTargetTests`.
  - **RULE — a series card's play entry is always labelled "Play", never "Resume"**: a `contextMenu` builds synchronously and cannot await the `getNextUp` that would reveal the offset. The resume is still applied at launch. Movie and episode cards carry their own `userData`, so they label correctly and additionally show "Play from beginning". Same reason "Play on…" reads `CardActionPresenter.knownRemoteTargetCount` (written only by real probes — detail-screen load, sheet open) instead of probing: a cold cache renders the entry optimistically, and the sheet re-probes with its own `remote.noTargets.*` empty state.
```

- [x] **Step 6 : commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md — menus contextuels de vignettes (couverture + actions)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Notes pour l'exécutant

**Pourquoi le menu ne fait pas de mise à jour optimiste sur la lecture.** Les deux bascules existantes (vu, favori) maintiennent des miroirs `@State` parce que leur libellé doit changer immédiatement. La lecture n'a pas de libellé d'état à maintenir : après le retour du lecteur, la notification tier-2 `.cinemaxItemUserDataChanged` (postée par `PlaybackReporter` via le flux existant) suffit à rafraîchir la rangée.

**Pourquoi `onRemoveFromResume` est un rappel et pas une condition sur le type.** L'action n'est pas « cet item a une position », c'est « cet écran sait retirer la carte de sa rangée ». Une grille de bibliothèque a des items à demi vus sans avoir de rangée « Reprendre » à mettre à jour.

**L'ordre des tâches est un ordre de dépendances, pas un ordre de préférence.** Chaque tâche compile et se teste seule. Task 4 doit passer après Task 2 (elle consomme `CardPlaybackNavigation`) et Task 6 après Task 4 (elle étend la même signature une troisième fois).
