# Recherche de personnes

**Statut** : validé, prêt pour le plan d'implémentation
**Lot** : 2/5 de la série « endpoints Jellyfin inexploités » (ordre : hygiène des transcodes → **recherche de personnes** → bonus/trailers → recommandations → télécommande)

## Objectif

Taper « Cillian Murphy » dans la recherche et tomber sur sa fiche, au lieu de rien.

## Problème

`SearchScope.includeItemTypes` est figé sur `[.movie, .series, .episode]` (`Shared/ViewModels/SearchViewModel.swift`). Chercher un nom d'acteur ne renvoie donc que les titres qui contiennent ce nom — c'est-à-dire, presque toujours, rien.

`PersonDetailScreen` existe déjà (portrait, biographie, filmographie séparée films / séries) mais n'est atteignable que depuis la rangée casting d'une fiche. Il faut déjà savoir dans quel film joue quelqu'un pour pouvoir apprendre dans quels films il joue.

## Périmètre

**Dans le périmètre**

- Une rangée « Personnes » en portraits ronds, au-dessus de la grille de résultats, en portée **Tout** uniquement.
- Un appel `GET /Persons` par recherche, classé localement.
- Navigation vers `PersonDetailScreen`, qui existe et ne change pas.

**Hors périmètre**

- Extension aux App Intents. Siri résout des choses à lire ; « joue-moi Cillian Murphy » n'a pas de sens. `MediaItemQuery` reste sur les titres.
- Un 4ᵉ chip de portée « Personnes ». Écarté au profit de la rangée (cf. décision ci-dessous) ; il pourra s'ajouter plus tard sans rien casser.
- Les studios, genres et collections que `/Search/Hints` sait aussi renvoyer.

## Décisions d'architecture

### `GET /Persons`, pas `/Search/Hints`

Les deux savent chercher une personne. La différence est le modèle de retour :

| | Retour | Conséquence |
|---|---|---|
| `/Search/Hints` | `SearchHintResult` → `SearchHint` | Un **second modèle de résultat** dans le pipeline de recherche |
| `/Persons` | `BaseItemDtoQueryResult` → `BaseItemDto` | Le **même modèle** que tout le reste |

Avec `BaseItemDto`, `LibrarySearchRanker.score` s'applique sans modification, `ImageURLBuilder.imageURL(itemId:imageType:tag:)` aussi, et `PersonDetailScreen(personId:personName:)` reçoit exactement ce qu'il attend. `/Search/Hints` obligerait à convertir, ou à faire vivre deux formes de résultat côte à côte pour un gain nul.

`/Search/Hints` renvoie aussi studios et genres — hors périmètre, donc son seul avantage réel ne sert pas ici.

### Un seul appel, pas le fan-out par mot

La recherche de titres interroge le serveur pour la phrase complète **et** chacun des mots significatifs, parce que le `searchTerm` de Jellyfin est contigu et sensible à la ponctuation : « Mission Impossible » rate « Mission : Impossible ».

Un nom de personne n'a pas ce défaut. Le serveur fait un `contains` : « murphy » trouve « Cillian Murphy ». Un appel suffit, et la recherche coûte donc **+1 requête** par frappe débouncée, pas +5.

Le classement local reste utile pour l'ordre d'affichage — `LibrarySearchRanker.score` sur `name`, plafond à 10 portraits.

### Le matching reste dans `LibrarySearchRanker`

C'est le SSOT documenté, partagé avec les App Intents. Le sortir de là le ferait diverger. La nouvelle fonction y vit à côté de `rank`, et réutilise `normalize` / `significantWords` / `score`.

### La rangée n'existe qu'en portée « Tout »

Un filtre de type qui affiche autre chose que le type demandé n'est plus un filtre. En portée Films ou Séries, `personResults` est vidé sans appel réseau.

### La rangée disparaît quand elle est vide

**Zéro personne trouvée ⇒ ni titre de section, ni rangée, ni espace réservé.** Un intitulé « Personnes » au-dessus du vide est un bug visuel, et c'est le cas le plus fréquent (la majorité des recherches visent un titre).

### Un échec de la recherche de personnes ne casse pas la recherche de titres

Les deux appels sont indépendants et concurrents. Si `getPersons` échoue, `personResults` reste vide, la rangée n'apparaît pas, et la grille de titres s'affiche normalement. `searchFailed` — qui pilote l'écran d'erreur avec bouton Réessayer — reste piloté **uniquement** par la recherche de titres. L'inverse (titres en échec, personnes trouvées) montre l'écran d'erreur : c'est le résultat principal qui manque.

## Composants

### `LibraryAPI` — une méthode

```
func searchPersons(userId: String, searchTerm: String, limit: Int) async throws -> [BaseItemDto]
```

→ `Paths.getPersons` avec `searchTerm`, `limit`, `userID`, `enableImages: true`. Implémentation dans `JellyfinAPIClient+Library.swift`, à côté de `getPersonItems`.

**Deux types conforment à `LibraryAPI`** et doivent donc l'implémenter : `JellyfinAPIClient` (production) et `MockAPIClient` (tests). Pas d'implémentation par défaut vide ici — contrairement aux méthodes de cycle de vie du lot précédent, celle-ci est activement pilotée par les tests. Le mock reçoit le même patron que `searchItems` : un `searchPersonsHandler` optionnel, sinon `shouldThrow` / `stubbedPersonResults`.

### `LibrarySearchRanker` — une fonction

```
static func rankPersons(query: String, userId: String, api: any LibraryAPI) async -> [BaseItemDto]
```

Un appel, score local sur `name`, filtre les scores nuls, trie décroissant, plafonne à 10. Renvoie un simple tableau : pas de `failed` à remonter, puisque l'échec se traduit par une rangée absente et non par un état d'erreur.

### `SearchViewModel` — un état

`var personResults: [BaseItemDto] = []`, vidé aux mêmes endroits que `results` (requête vide, changement de portée hors `.all`). Peuplé dans `search(using:)` par un appel concurrent de celui des titres, sous les mêmes gardes de cancellation.

### `SearchScreen` — une rangée

Un `SearchPersonRow` file-private, au-dessus de `SearchResultsGrid`, rendu **uniquement si `!personResults.isEmpty`**. `ContentRow` + `CastCircle` dans un `NavigationLink` vers `PersonDetailScreen`, sur le modèle exact de `MediaDetailCastSection`.

Contraintes de plateforme : `.scrollClipDisabled()` sur la rangée (RULE — les cartes grossissent à 1.06 en focus et se feraient rogner) ; `CinemaTVCardButtonStyle` sur tvOS, `.plain` sur iOS ; `CastCircle` dessine son propre anneau de focus circulaire.

## Flux

1. L'utilisateur tape, `search(using:)` débounce 400 ms.
2. En portée `.all`, deux appels concurrents : le fan-out des titres (existant) et `rankPersons` (nouveau).
3. Les titres alimentent `results` + `searchFailed` ; les personnes alimentent `personResults`.
4. La rangée se dessine si et seulement si `personResults` est non vide.
5. Un portrait pousse `PersonDetailScreen`, inchangé.

## Erreurs

`rankPersons` avale son erreur et renvoie un tableau vide — l'absence de rangée *est* le mode dégradé. Rien à réessayer, rien à signaler : l'utilisateur cherchait probablement un titre, et il l'a.

## Tests

Cible : `Tests/CinemaxKitTests/`, swift-testing, avec le `MockAPIClient` existant.

- Un nom d'acteur renvoie la personne, triée par score.
- Un score nul est filtré (le serveur peut renvoyer large).
- Le plafond de 10 est respecté.
- Un `searchPersons` qui jette renvoie un tableau vide, sans propager.
- En portée `.movies` / `.series`, `personResults` reste vide et aucun appel n'est émis.
- Un échec côté personnes laisse `results` et `searchFailed` intacts.

## Note — contrôle parental

Une personne ne porte pas de classification. La rangée peut donc afficher un acteur dont tous les films sont masqués par `privacy.maxContentAge`. Aucun contenu n'est révélé pour autant : le nom et le portrait ne disent rien du catalogue, et `PersonDetailScreen` liste la filmographie via `getPersonItems`, qui passe par le client déjà plafonné. On documente plutôt que d'ajouter un filtrage qui n'aurait rien à filtrer.
