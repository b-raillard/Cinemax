# Menus contextuels sur les vignettes — couverture et actions

**Statut** : validé, prêt pour le plan d'implémentation
**Approche retenue** : A pour la lecture et « Lire sur… » (présentateur hébergé à la racine), C pour « Aller à la série » (rappel remonté par écran)

## Objectif

Faire de l'appui long sur une vignette de film ou de série un vrai raccourci d'action : lancer la lecture, l'envoyer sur l'Apple TV, atteindre la fiche de la série parente — depuis **toutes** les surfaces qui affichent des vignettes, pas trois d'entre elles.

## Problème

Le menu contextuel existe déjà mais il est limité sur deux axes indépendants.

**Couverture.** `mediaCardContextMenu` n'est accroché qu'à trois surfaces : la grille et les rangées de genres de la bibliothèque ([LibraryPosterCard.swift:146](../../../Shared/Screens/LibraryPosterCard.swift)), les résultats de recherche, l'historique de visionnage. Sept surfaces bâties sur le même `PosterCard` n'ont **aucun** menu : les quatre rangées de l'Accueil (Next Up, Ajouts récents, Favoris, genres), l'écran Favoris, la filmographie d'un acteur, « Titres similaires » sur la fiche.

**Actions.** Le menu propose trois entrées — marquer vu, favori, ajouter à une playlist. Aucune ne lance quoi que ce soit. L'action la plus attendue d'un appui long sur une affiche, lire, est absente.

S'y ajoutent deux mécanismes divergents : un menu bespoke sur le rail « Reprendre » de l'Accueil ([HomeScreen.swift:771](../../../Shared/Screens/HomeScreen.swift)) qui propose marquer-vu + retirer mais ni favori ni playlist, et une pastille ellipsis admin iOS-only posée en `ZStack` sur `LibraryPosterCard` uniquement.

## Périmètre

**Dans le périmètre**

- Trois nouvelles entrées : **Lecture / Reprendre** (+ « Lire depuis le début »), **« Lire sur… »**, **Aller à la série**.
- Une entrée conditionnelle **Retirer de Reprendre**, qui absorbe le menu bespoke de l'Accueil.
- Six nouveaux points d'accroche, couvrant les sept surfaces orphelines.

**Hors périmètre — décidé, pas oublié**

- **Actions admin dans le menu.** Écartées explicitement ; la pastille ellipsis iOS-only reste en l'état.
- **Aperçu riche `contextMenu(preview:)`** (backdrop + synopsis + badges qualité au lieu de la vignette floutée).
- **« Retirer de la playlist »**, qui suppose qu'une grille sache qu'elle est scopée à une playlist et charge via `getPlaylistItems` pour obtenir les `playlistItemID` — c'est le lot « playlists en écriture v2 », pas celui-ci.
- **Menu sur les dossiers** (`LibraryFolderBrowseScreen`) : il liste des collections et des playlists, pas des médias.

## Le mur commun : les conteneurs lazy

« Lire » et « Aller à la série » butent sur la même contrainte, et c'est elle qui dicte l'architecture. Un `contextMenu` accroché à une carte vit dans un `LazyVGrid` / `LazyHStack` ; SwiftUI y ignore silencieusement `navigationDestination(item:)`, et une présentation attachée à un enfant lazy meurt avec la cellule recyclée (RULE conteneur-lazy de CLAUDE.md). Un bouton de menu ne peut donc **ni** pousser un `NavigationLink`, **ni** héberger sa propre feuille.

Trois réponses étaient possibles :

| | Mécanisme | Verdict |
|---|---|---|
| **A** | Présentateur hébergé à la racine (précédent `AddToPlaylistPresenter`) | retenu pour la lecture et « Lire sur… » |
| **B** | Rebond par `MediaDetailScreen` via `pendingIntentPlaybackItemId` (chemin Siri / remote-control) | écarté : on voit passer la fiche détail avant le lecteur, et on y atterrit en quittant |
| **C** | Rappel remonté par écran (précédent `AdminItemMenu.onSelectDestination`) | retenu pour « Aller à la série » |

Le partage suit une asymétrie réelle, pas un compromis. **Lire ouvre un modal plein écran** : l'écran de dessous n'a aucune importance, l'héberger à la racine est plus correct qu'un push — et cela rend iOS symétrique de ce que tvOS fait déjà avec `VideoPlayerCoordinator`. **Aller à la série ouvre un écran de navigation ordinaire**, où le bouton Retour et la pile comptent ; et cette entrée ne concerne que les surfaces affichant des **épisodes** — Reprendre, Next Up, recherche, historique — soit **trois écrans hôtes** (l'Accueil en héberge deux), pas dix.

## Point établi : la résolution Série → Épisode existe déjà

Vérifié dans le code avant de figer le design, parce qu'il change la taille du lot. `getPlaybackInfo` résout déjà Series/Season → Épisode côté CinemaxKit ([JellyfinAPIClient+Playback.swift:277](../../../Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift), `resolvePlayableEpisode` — next-up d'abord, sinon premier épisode de la première saison). `PlayLink(itemId: serieId)` fonctionne donc tel quel.

Ce que `MediaDetailScreen.resolvedPlayTarget(for:)` ajoute par-dessus se réduit à **la position de reprise** (et au titre). Le « résolveur partagé » n'a donc pas à réimplémenter le choix de l'épisode — seulement à récupérer son offset.

## Architecture

### `CardActionPresenter` — nouveau, `Shared/Screens/CardActionPresenter.swift`

`@MainActor @Observable`, instancié sur `AppNavigation` et injecté dans l'environnement, calqué sur `AddToPlaylistPresenter` : un modèle minimal portant des requêtes optionnelles, plus un modificateur de présentation appliqué à la racine.

```
var playback: CardPlaybackRequest?       // iOS : pilote le fullScreenCover ; tvOS : jamais publié
var remotePlay: RemotePlayIntent?        // pilote RemotePlayPresentation, déplacé ici
var knownRemoteTargetCount: Int?         // nil = jamais sondé
```

Deux petits types accompagnent le presenter, tous deux de simples porteurs de valeurs :

- **`CardPlaybackRequest`** (`Identifiable`) — exactement les arguments que `VideoPlayerView` attend : `itemId`, `title`, `startTime`, `previousEpisode`, `nextEpisode`, `episodeNavigator`. Aucun `mediaSourceId` : le choix de version est une décision de la fiche détail, une carte n'en a pas.
- **`CardPlaybackNavigation`** — le trio prev / next / navigator que `PlayLink` prend déjà (`EpisodeRef?`, `EpisodeRef?`, `EpisodeNavigator?`), regroupé pour ne pas propager trois paramètres à travers le modificateur.

**Lecture.** `play(item:navigation:using:)` résout la cible (voir ci-dessous) puis, sur iOS, publie une `CardPlaybackRequest` que la racine présente en `.fullScreenCover(item:)` → `VideoPlayerView` ; sur tvOS, appelle directement `VideoPlayerCoordinator.play(...)`, qui est déjà un présentateur racine, et ne publie rien.

**« Lire sur… ».** `RemotePlayPresentation` prend déjà un `@Binding var sheet: RemotePlayIntent?` ([MediaDetailRemotePlay.swift:277](../../../Shared/Screens/MediaDetailRemotePlay.swift)) : le rendre racine est un déplacement, pas une réécriture. La fiche détail continue de l'utiliser via le presenter au lieu de son `@State` local.

**Compteur de cibles.** `knownRemoteTargetCount` est écrit à chaque sondage réel — chargement d'une fiche détail (`MediaDetailViewModel.loadRemoteTargets`) et ouverture de la feuille, qui re-sonde déjà. Aucun sondage spéculatif n'est ajouté.

### `CardPlayTarget` — nouveau, `Shared/ViewModels/CardPlayTarget.swift`

`static func resolve(item:api:userId:) async -> CardPlayTarget`, une trentaine de lignes, trois cas :

| Type de carte | Coût | Ce qu'on obtient |
|---|---|---|
| Film, épisode | **zéro appel réseau** | `userData.playbackPositionTicks` est déjà dans le DTO de la carte |
| Série | un `getNextUp(seriesId:)` | l'offset de reprise et le titre de l'épisode — appel déjà mis en cache 10 s (préfixe `nextup-`) |
| Échec | — | cible sans offset ; la lecture démarre quand même et `getPlaybackInfo` fait sa propre résolution |

Placé dans `Shared/ViewModels/` et prenant un `any LibraryAPI` : même forme que `LibrarySearchRanker`, le précédent de logique partagée testable de ce projet.

### `MediaCardContextMenu` — modifié

Signature élargie, les deux nouveaux paramètres avec défaut `nil` pour que les appels existants ne bougent pas :

```swift
func mediaCardContextMenu(
    item: BaseItemDto,
    navigation: CardPlaybackNavigation? = nil,
    onGoToSeries: ((BaseItemDto) -> Void)? = nil
) -> some View
```

`navigation` porte le prev/next épisode que les rails de l'Accueil possèdent déjà (`resumeNavigation` / `nextUpNavigation`). Ailleurs il est `nil` et le lecteur n'affiche pas les boutons épisode — dégradation déjà documentée dans CLAUDE.md pour les rails qui les omettent.

`onGoToSeries` non-nil est ce qui **fait apparaître** l'entrée : la présence du rappel prouve que l'écran héberge le `navigationDestination` correspondant. Aucun état supplémentaire à synchroniser, et une grille qui oublie la plomberie n'affiche simplement pas l'entrée au lieu d'offrir un bouton mort.

## Contenu du menu

| Entrée | Condition | Groupe |
|---|---|---|
| **Lecture** / **Reprendre** | item jouable (film, série, épisode) | lecture |
| **Lire depuis le début** | reprise connue **localement** (film, épisode) | lecture |
| **Lire sur…** | `knownRemoteTargetCount == nil` ou `> 0` | lecture |
| **Aller à la série** | `type == .episode` **et** `onGoToSeries != nil` | navigation |
| Marquer comme vu / non vu | existant | état |
| Ajouter aux / retirer des favoris | existant | état |
| Ajouter à une playlist | existant (presenter optionnel) | état |
| **Retirer de Reprendre** | `playbackPositionTicks > 0`, rôle destructif | destructif |

Groupes séparés par des `Divider()`, l'action principale en tête, le destructif en queue.

### Deux décisions assumées

**Le libellé sur une carte de série est « Lecture », jamais « Reprendre ».** Un `contextMenu` construit son contenu de façon synchrone : impossible d'attendre le `getNextUp` avant d'afficher le menu, donc l'offset d'une série est inconnu à ce moment. La reprise s'applique quand même au lancement — ce qui correspond à la sémantique Jellyfin de « lire une série ». Sur un film ou un épisode le DTO de la carte suffit, donc « Reprendre » et « Lire depuis le début » s'affichent correctement.

**« Lire sur… » lit un compteur en cache plutôt que de sonder.** Cache froid ⇒ l'entrée s'affiche (optimiste). Cela évite une entrée morte permanente pour qui n'a pas d'Apple TV, sans ajouter de requête spéculative à l'ouverture de chaque menu. La feuille re-sonde à l'ouverture et possède déjà son état vide (`remote.noTargets.*`), donc le cas « cache périmé » dégrade proprement.

Ces deux décisions s'écartent de la RULE de la fiche détail (« l'affordance ne s'affiche que si `!remoteTargets.isEmpty` — son apparition est ce qui enseigne la précondition »). L'écart est délibéré : un menu contextuel ne peut pas attendre un sondage avant de se dessiner, contrairement à une fiche qui a déjà chargé.

## Couverture

Six nouveaux points d'accroche ; les trois surfaces existantes héritent des nouvelles entrées sans édition.

| Surface | Édition |
|---|---|
| Accueil → Reprendre | remplace le menu bespoke ; passe `resumeNavigation` |
| Accueil → Next Up | ajout ; passe `nextUpNavigation` |
| Accueil → Ajouts récents / Favoris / genres | **une seule** édition — les trois rails partagent `recentlyAddedCard` |
| Écran Favoris | ajout |
| Filmographie (`PersonDetailScreen`) | ajout |
| « Titres similaires » (`MediaDetailSimilarSection`) | ajout |

Plomberie « Aller à la série » (approche C, `@State` + `navigationDestination` hors conteneur lazy) sur **trois écrans hôtes seulement** : Accueil (les rails Reprendre et Next Up partagent le même hôte), recherche, historique de visionnage.

**L'absorption du menu bespoke de l'Accueil est une conséquence, pas un objectif.** Elle est forcée : couvrir le rail Reprendre avec le menu partagé lui **retirerait** « Retirer de Reprendre » si l'entrée n'était pas reprise.

## Erreurs et dégradations

- Échec de résolution de cible ⇒ lecture lancée sans offset, jamais bloquée.
- Échec de lecture ⇒ chemin d'erreur existant de `VideoPlayerView` / du coordinator, inchangé.
- Chaque action conserve la discipline en vigueur : toast via `userFacingMessage(for:)`, notification tier-2 `.cinemaxItemUserDataChanged` ou `.cinemaxFavoritesChanged`, jamais de `localizedDescription` brut à l'écran.
- `AddToPlaylistPresenter` reste lu en **optionnel** dans le menu ; `CardActionPresenter` suit la même règle, pour la même raison (un `@Environment(Type.self)` non-optionnel sur un `@Observable` absent *piège à l'exécution*, et ces cartes vivent aussi dans des hôtes présentés modalement qui réinjectent l'environnement à la main).

## Risques

**Restauration depuis le PiP (iOS) — à vérifier, pas un acquis.** Le lecteur devient un `fullScreenCover` racine au lieu d'un push. La coquille `VideoPlayerView` appelle `dismiss()` quand le modal UIKit se ferme, ce qui referme un cover aussi bien qu'il dépile un push. Mais `IOSPlayerDelegate.restoreUserInterface…` re-présente via un **nouveau `PlayerHostingVC`**, et ce chemin doit être exercé explicitement avant de déclarer le lot fini. C'est la seule inconnue matérielle du design.

**CLAUDE.md à amender.** La RULE « tous les boutons de lecture passent par `PlayLink` — jamais un `NavigationLink` direct vers `VideoPlayerView` » devient « … sauf depuis un menu contextuel, qui passe par `CardActionPresenter` et rejoint le même `VideoPlayerView` / `VideoPlayerCoordinator` ». Sans cet amendement le prochain lecteur de CLAUDE.md croira à une violation.

## Tests

`CardPlayTarget.resolve` est la seule logique testable hors UI, et couvre les cas qui cassent en silence :

- film avec reprise / sans reprise / marqué vu (la reprise ne doit pas s'appliquer)
- épisode avec reprise
- série dont le next-up porte un offset ; série dont `getNextUp` renvoie `nil` ; série dont `getNextUp` jette

Via le mock d'API existant, dans `Tests/CinemaxKitTests/` (cible Xcode `CinemaxTests`). Rappel : `-only-testing` n'exécute silencieusement aucun test swift-testing — lancer la suite complète et grepper `Suite "…"` / `✔`.

Le reste est du câblage SwiftUI, couvert par une passe manuelle sur les deux plateformes : lecture depuis chaque nouvelle surface, focus tvOS inchangé (le menu reste accroché au bouton focusable, jamais à son label), et le scénario PiP ci-dessus.

## Localisation

Nouvelles clés `fr` + `en`, parité vérifiée par la skill `localize-check` :

`card.play`, `card.resume`, `card.playFromStart`, `card.goToSeries`.

`remote.title` (« Lire sur… ») et `home.continueWatching.remove` existent déjà et sont réutilisées telles quelles.
