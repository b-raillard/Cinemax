# Socle App Intents — Siri & Raccourcis (iOS)

Date : 2026-07-29
Statut : validé, en implémentation

## Objectif

Exposer la médiathèque à Siri et à l'app Raccourcis via `AppIntents`. Ce lot
construit la **fondation** : les entités, leur résolution, l'amorçage de session
sans interface, et cinq intents. Il est dessiné pour accueillir ensuite Spotlight,
Control Center, le bouton Action, les widgets Lock Screen et la Live Activity
interactive — aucun de ces cinq n'est construit ici.

## Périmètre

**Dans le lot** — iOS uniquement :

- `MediaItemEntity` + `MediaItemQuery` (résolution d'entités)
- `IntentSessionProvider` (amorçage de session sans interface)
- `LibrarySearchRanker` (extraction de la logique de correspondance)
- Cinq intents : reprendre la lecture, lire un titre, prochain épisode,
  ouvrir une fiche, rechercher
- `CinemaxShortcuts: AppShortcutsProvider` (phrases FR/EN)
- Routage de lecture déclenché par intent

**Hors du lot, explicitement** — Spotlight / CoreSpotlight, Control Center,
bouton Action, widgets Lock Screen & StandBy, Live Activity interactive, tvOS,
exécution en arrière-plan sans ouvrir l'app.

tvOS : le socle compilerait, mais aucune des surfaces desservies n'existe sur
la plateforme. On ne l'y expose pas (`#if os(iOS)`).

## Décisions d'architecture

### Résolution en direct, sans index (option A)

`entities(matching:)` interroge la recherche du serveur actif à chaque appel.
Rien n'est stocké sur l'appareil.

Retenue contre un index local (option B) parce que celui-ci **est** le
sous-système Spotlight écarté du périmètre : fraîcheur, volume, invalidation,
cloisonnement par serveur, corpus de titres au repos sur l'appareil. Le
construire ici aurait payé le coût de Spotlight sans son bénéfice.

Conséquences assumées : la résolution échoue hors-ligne et suit la latence d'un
serveur auto-hébergé. Si le besoin hors-ligne se manifeste, l'hybride (petit
cache chaud pour les suggestions et la re-résolution) est une évolution
**additive** qui ne remet pas ce choix en cause.

### Identité composite (serveur, item)

`MediaEntityID` porte l'id du serveur **et** l'id de l'item, jamais l'id
Jellyfin seul. Un raccourci enregistré chez un serveur puis rejoué sur un autre
doit échouer proprement — jamais lancer un élément différent. `entities(for:)`
est le point où ce cloisonnement se fait respecter.

### Le schéma d'URL public n'est pas élargi

`handleDeepLink` ne connaît que `item` et `home`. On **n'ajoute pas** de verbe
« lire » à `cinemax://` : c'est une porte publique et non authentifiée, et un
« lis n'importe quel id » y créerait une surface d'attaque inutile. La
validation de forme d'id déjà présente (`AppState.isValidItemId`) montre que
cette porte est traitée comme hostile ; on ne l'ouvre pas davantage.

À la place : `AppState.pendingPlaybackIntent`, posé **en processus** par un
intent, consommé par le même routage racine que les deep-links. Les intents
tournent en `openAppWhenRun`.

### Le plafond de classification s'applique aux intents

`IntentSessionProvider` applique `privacy.maxContentAge` via
`applyContentRatingLimit` sur le client qu'il construit. Sans cela, Siri
deviendrait un contournement du contrôle parental — un intent renverrait des
titres que l'app masque.

### Localisation — exception documentée

Titres d'intents et phrases Siri passent par `LocalizedStringResource`, que le
système résout **hors** de `LocalizationManager`, avant que notre code ne
tourne. Même classe d'exception qu'`InfoPlist.strings`.

Conséquence assumée : un utilisateur ayant forcé l'app en anglais sur un
appareil français verra des phrases Siri françaises. La langue des phrases suit
l'appareil, pas le réglage in-app.

## Composants

| Composant | Rôle | Emplacement |
|---|---|---|
| `LibrarySearchRanker` | Correspondance titre↔requête, pure et testable | `Shared/ViewModels/` |
| `IntentSessionProvider` | Client Jellyfin depuis le Keychain, sans interface | `Shared/Intents/` |
| `MediaEntityID` | Identité composite (serveur, item) | `Shared/Intents/` |
| `MediaItemEntity` | Entité exposée à Siri / Raccourcis | `Shared/Intents/` |
| `MediaItemQuery` | `EntityStringQuery` : matching, suggestions, re-résolution | `Shared/Intents/` |
| Les cinq intents | Actions exposées | `Shared/Intents/` |
| `CinemaxShortcuts` | Phrases Siri | `Shared/Intents/` |

### `LibrarySearchRanker` — extraction

`fetchRanked` / `normalizeForMatch` / `relevanceScore` / `searchStopWords`
sortent de `SearchViewModel` vers une unité pure. C'est de la logique de domaine
aujourd'hui coincée dans un view model, et c'est le cœur du pari de l'option A :
ce classeur plie ponctuation et diacritiques, donc il absorbe déjà les écarts
d'une transcription vocale (« Mission Impossible » → « Mission : Impossible »).

Même précédent que `SeekCoalescer` : de la logique pure sortie d'une grosse
classe pour devenir testable.

`SearchViewModel` délègue ; son comportement ne change pas.

### Les cinq intents

| Intent | Paramètre | Effet |
|---|---|---|
| `ResumePlaybackIntent` | — | Relance la tête de Continue Watching |
| `PlayMediaItemIntent` | `MediaItemEntity` | Lance l'élément |
| `PlayNextEpisodeIntent` | `MediaItemEntity` (séries) | Lance le prochain épisode non vu |
| `OpenMediaItemIntent` | `MediaItemEntity` | Ouvre la fiche sans lancer |
| `SearchLibraryIntent` | `String` | Ouvre la recherche sur le terme |

## Flux

**Résolution** (sans ouvrir l'app) — éditeur Raccourcis ou Siri →
`MediaItemQuery` → `IntentSessionProvider` (Keychain) → `LibraryAPI.searchItems`
→ `LibrarySearchRanker` → entités.

Point non-évident : même avec des intents qui ouvrent l'app pour lancer la
lecture, **la résolution tourne sans interface**. Siri résout le titre avant de
décider quoi faire, et l'éditeur Raccourcis affiche un sélecteur sans jamais
présenter l'app. L'amorçage sans interface est donc requis quoi qu'il arrive.

**Exécution** — intent → `openAppWhenRun` → `AppState.pendingPlaybackIntent` →
routage racine existant → `PlayLink`.

## Erreurs

| Cas | Comportement |
|---|---|
| Pas de serveur / pas de session | Invite explicite à se connecter dans l'app |
| Entité d'un autre serveur | Échec net — **jamais** de repli sur un élément voisin |
| Item disparu (re-scan) | Échec net |
| Hors-ligne / serveur injoignable | Message clair |
| Rien en cours (reprendre) | Message expliquant qu'il n'y a rien à reprendre |

Ces messages ne peuvent pas passer par `userFacingMessage(for:)`, lié à
`LocalizationManager` et indisponible sans interface : ils ont leur propre table
`LocalizedStringResource`.

## Tests

Le risque réel est concentré dans le classeur, et l'extraction le rend purement
testable — c'est le principal bénéfice technique du lot.

- `LibrarySearchRanker` : normalisation, tiers de score, mots significatifs
  (filtrage des mots vides). Reprend et étend `SearchRelevanceTests`.
- `MediaEntityID` : aller-retour de sérialisation, rejet des formes invalides.
- `MediaItemQuery` : rejet inter-serveurs sur `entities(for:)`.
- `IntentSessionProvider` : via le `MockKeychain` existant
  (`SecureStorageProtocol` est déjà injectable), y compris l'application du
  plafond de classification.

Les intents eux-mêmes se vérifient à la main dans Raccourcis et avec Siri.
