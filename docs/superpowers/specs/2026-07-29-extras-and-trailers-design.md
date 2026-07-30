# Bonus et bandes-annonces locales

**Statut** : validé, prêt pour le plan
**Lot** : 3/5 de la série « endpoints Jellyfin inexploités » (hygiène des transcodes ✅ → recherche de personnes ✅ → **bonus/trailers** → recommandations → télécommande)

## Objectif

Rendre accessibles les extras **déjà présents sur le serveur** et aujourd'hui totalement invisibles dans l'app : scènes coupées, making-of, bêtisiers (`/SpecialFeatures`) et bandes-annonces locales (`/LocalTrailers`).

## Problème

Deux collections jouables ne sont jamais demandées. Et le bouton bande-annonce existant est doublement dégradé : il lit `remoteTrailers` (une URL YouTube), sort de l'app vers Safari, et vit dans un bloc `#if os(iOS)` — **il n'existe pas du tout sur tvOS**, faute de navigateur.

Or `/LocalTrailers` renvoie un vrai fichier du serveur, jouable par le moteur interne. Le manque tvOS n'est donc pas une fatalité de plateforme : c'était une conséquence du choix de source.

## Périmètre

**Dans le périmètre** : les deux endpoints, un rail « Bonus », et la bascule du bouton bande-annonce vers la source locale quand elle existe.

**Hors périmètre** : les extras de type audio (thème musical — c'est `/ThemeMedia`, un autre lot), la lecture enchaînée des bonus, et tout marquage « vu » sur un bonus (Jellyfin le supporte, mais un bêtisier coché n'apporte rien).

## Décisions

### Chaque endpoint alimente l'affordance à laquelle il appartient

Option retenue (A) contre un rail unique regroupant tout (B). Une bande-annonce est une **action**, pas un contenu à parcourir : la reléguer parmi les vignettes rétrograde quelque chose qui marche déjà en un tap. Les suppléments, eux, sont bien une collection à parcourir.

### Le trailer local a la priorité sur le trailer distant

Ordre de résolution du bouton :

1. `localTrailers` non vide ⇒ `PlayLink` sur le premier — lecture in-app, **sur les deux plateformes** ;
2. sinon, iOS uniquement : `remoteTrailers` → Safari (comportement actuel, inchangé) ;
3. sinon : pas de bouton.

**RULE — tout bouton de lecture passe par `PlayLink`**, jamais un `NavigationLink` direct vers le lecteur. Le trailer local en est un.

### tvOS gagne le bouton, sous forme de bouton ghost

La rangée d'actions tvOS est un `HStack` de boutons ghost à côté de Lecture (`favoriteButton`, `watchedButton`, `watchTogetherButton`). Le trailer y prend la même forme — mais **seulement quand un trailer local existe** : pas de repli Safari sur tvOS, il n'y a pas de navigateur.

Conséquence : `SettingsKey.detailShowTrailerButton` cesse d'être iOS-only. Sa ligne de réglage doit apparaître sur les deux plateformes, et la description de la clé dans CLAUDE.md doit être corrigée.

### Le rail Bonus se place avant les rails de contenus liés

Dans `secondaryColumnSections`, l'ordre devient : Casting → Saisons → **Bonus** → Collection → Similaires. Les extras parlent de *cet* item ; la collection et les similaires renvoient ailleurs. Ce qui concerne l'item vient d'abord.

Vignettes **16:9** (ce sont des vidéos, pas des affiches), masquées entièrement quand la collection est vide — même discipline que la rangée de personnes du lot précédent.

### Un échec de récupération est non fatal

Les deux fetchs rejoignent le fan-out concurrent existant de `load()`. Une erreur vide la collection concernée et fait disparaître le rail ; elle ne pose jamais `errorMessage` ni ne remplace la fiche par un écran d'erreur. Précédent : le fan-out des genres de `MediaLibraryScreen`.

## Composants

| Élément | Emplacement |
|---|---|
| `getSpecialFeatures(itemId:userId:)`, `getLocalTrailers(itemId:userId:)` | `LibraryAPI` + `JellyfinAPIClient+Library.swift` + `MockAPIClient` |
| `specialFeatures`, `localTrailers` | `MediaDetailViewModel` |
| `MediaDetailExtrasSection` | nouveau fichier `Shared/Screens/` (⇒ `xcodegen generate`) |
| Bouton trailer | `MediaDetailScreen` — branche iOS existante + nouveau bouton ghost tvOS |

Les deux méthodes vont sur `LibraryAPI` et doivent être implémentées par **les deux conformeurs** (`JellyfinAPIClient`, `MockAPIClient`) — pas d'implémentation par défaut, les tests les pilotent.

## Flux

`load()` récupère l'item, puis dans son fan-out concurrent ajoute les deux appels. Le bouton lit `localTrailers.first` ; le rail lit `specialFeatures`. Un bonus se joue par `PlayLink(itemId: extra.id, title: extra.name)` — pas de navigation d'épisode, pas de position de reprise.

## Tests

- Les extras peuplent le view model après `load()`.
- Un `getSpecialFeatures` en échec laisse la fiche affichée et `errorMessage` nil.
- Un `getLocalTrailers` en échec ne casse pas non plus la fiche.
- La préséance : local présent ⇒ c'est lui qui est proposé, même quand un `remoteTrailers` existe.

Le rendu (rail, bouton ghost tvOS) n'est pas testable unitairement — vérification sur le simulateur attaché, comme au lot précédent.

## Note

Les extras héritent de la classification de leur parent côté serveur ; aucun filtrage supplémentaire n'est ajouté ici. `applyContentRatingLimit` porte sur les requêtes d'items du catalogue, et un bonus n'est atteignable que depuis la fiche d'un item déjà visible.
