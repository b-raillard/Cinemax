# Cinemax — Check performance & propositions de nouveautés (2026-08-05, v1.1.1)

Périmètre : audit de performance frais du code actuel (post-1.1.1 : multi-serveur,
« Lire sur… », playlists, Live Activity, App Intents, recherche de personnes, proxy
loopback, SwiftVLC 1.0.0), plus un listing de nouveautés candidates avec
avantages/inconvénients. CLAUDE.md a servi de vérité terrain : les décisions
documentées comme délibérées ne sont pas re-signalées ; les écarts aux contrats
documentés le sont.

**Verdict global :** la base est saine. Décodage JSON hors main actor partout,
caches TTL avec single-flight sur `getItem`, fan-outs bornés à 6, prefetch
byte-identical vérifié sur tous les chemins câblés, `tag:` cache-buster présent sur
100 % des sites d'images vérifiés, teardown complet du socket de télécommande en
arrière-plan, throttle de la Live Activity correct, overlay de stats réellement
gratuit quand masqué. Les problèmes trouvés sont des coûts diffus (sur-rendu,
sur-fetch, travail par tick) plutôt que des bugs — mais plusieurs sont bien
visibles sur Apple TV A15 et sur serveur auto-hébergé.

---

## Partie 1 — Performance

### 1.1 Statut des constats de l'audit du 2026-07-06

| Constat de juillet | Statut |
|---|---|
| P1/1.3 — stores racine reconstruits sur événements de scène | ✅ Corrigé (RULE « Singleton root stores ») |
| P5 — `getItem` non caché | ✅ Corrigé (TTL 10 s + single-flight `coalesce`) |
| B4 — clé de cache `getLatestMedia` sans `parentId` | ✅ Corrigé (`latest-<user>-<parent>-<limit>-<age>`) |
| P8 — publish extensions à chaque revalidation | ✅ Corrigé (`isCurrent` early-return) |
| B2 — poll QuickConnect tué par une erreur transitoire | ✅ Corrigé (budget de 5 échecs consécutifs) |
| B3 — `connectToServer`/`authenticate` ne vident pas `APICache` | ❌ **Toujours ouvert** (voir F-13) |
| P6 — vignettes de chapitres chargées en rafale à l'ouverture | ❌ **Toujours ouvert** (voir F-4) |
| P2/P3/P4/P7 — DownloadManager | N/A — la feature offline a été retirée (App Review 5.2.3) |

### 1.2 Sévérité haute — à corriger en premier

#### F-1 · Recherche tvOS : `ScrollView` imbriqué → la grille perd toute laziness
`Shared/Screens/SearchScreen.swift:61` (ScrollView externe tvOS) enveloppe
`SearchResultsGrid` (`:624`) qui contient son **propre** `ScrollView` +
`LazyVGrid`. Le scroll externe propose une hauteur non bornée → le scroll interne
prend la hauteur totale de son contenu → **toutes** les cellules se matérialisent
d'un coup. `LibrarySearchRanker.rank` fan-out jusqu'à 5 × 30 résultats : une
requête large construit ~150 `SearchResultCard`, ~150 URLs, ~150 requêtes Nuke
simultanées (≈ 80 Mo décodés). Le scroll interne n'a pas non plus de
`.scrollClipDisabled()` → le poster focalisé (échelle 1.06) est rogné en bord de
grille — violation directe de la RULE tvOS documentée. iOS non concerné.
**Fix :** ne pas imbriquer — sur tvOS, rendre `LazyVStack`/`LazyVGrid` directement
dans le scroll externe (paramètre `wrapInScrollView` ou split du composant).
**Impact :** décrochage visible + pic mémoire à chaque recherche large sur Apple TV.

#### F-2 · `ThemeManager` : les 4 couleurs d'accent sont recalculées à chaque lecture
`Shared/DesignSystem/ThemeManager.swift:119-158` — `accent` / `accentContainer` /
`accentDim` / `onAccent` sont des computed properties : chaque lecture refait
`AccentOption(rawValue:)` (lecture `@AppStorage`) + `Color.dynamic` (allocation
d'un `UIColor` dynamique + closure). **293 sites de lecture dans 66 fichiers**,
dont les plus chauds sont par-carte : `CinemaFocusModifier` lit `accent` 2× par
carte (`FocusScaleModifier.swift:24,32`), `ProgressBarView` et `CastCircle` aussi.
Une grille tvOS de ~60 cartes ⇒ ~120+ allocations `UIColor` par passe de rendu.
Effet secondaire : deux `UIColor` dynamiques distincts ne sont pas `==` → tous les
styles paramétrés par `Color` (`TVFilterChipButtonStyle(accent:)`, etc.) paraissent
« changés » à chaque passe et court-circuitent le diffing.
**Fix :** mémoïser les 4 `Color` résolues dans des stockées `@ObservationIgnored`,
invalidées par les setters `accentColorKey`/`darkModeEnabled` et chaque pas de
`_rainbowHue`.

#### F-3 · `_accentRevision` remonte jusqu'à la racine : l'arc-en-ciel rebuild toute l'app à 10 Hz
`ThemeManager.colorScheme` (`:162-165`) lit `_accentRevision`, et
`AppNavigation.swift:867` applique `.preferredColorScheme(themeManager.colorScheme)`
à la racine. Le body racine dépend donc du compteur d'accent — et le tick
arc-en-ciel le bump toutes les 100 ms : `Group`, `ToastOverlay`, 8 injections
`.environment`, `MainTabView` → `TabView` → tous les onglets re-diffés 10×/s tant
que l'accent arc-en-ciel est actif. (Le tick 10 Hz lui-même est documenté ; c'est
sa portée *racine* qui ne l'est pas.) Attention : `uiScale` bump aussi
`_accentRevision` exprès pour forcer un re-render global — le couplage est porteur.
**Fix :** scinder le compteur — `_accentRevision` pour l'accent/rainbow,
`_globalRevision` (bumpé par `darkModeEnabled`/`uiScale`) lu par `colorScheme`.

#### F-4 · Lecteur : le HUD est repeint ~4×/s même masqué, pendant tout le film
`VLCStreamPresenter.swift:3357-3410` — chaque `.timeChanged` libVLC (~4 Hz) exécute
`paintPosition` : 2 `String(format:)`, 2 écritures `UILabel.text` (invalidation
layout + CoreText), écriture slider/`TVScrubBar.setProgress` (relayout de 3 frames
+ 2 cornerRadius). Le HUD masqué l'est par `alpha = 0`, pas `isHidden` — rien
n'est économisé dans l'état de visionnage normal. La valeur affichée ne change
qu'1×/s : 3 écritures sur 4 sont redondantes même HUD visible. S'y ajoute
`clearLoadingIfOpen()` → `stopAnimating()` sur un indicateur déjà arrêté, 4×/s.
**Fix :** dans `paintPosition`, (a) sauter les écritures quand `!controlsVisible`
(repeindre une fois dans `showControls()`), (b) mémoriser la dernière seconde
peinte et sauter si inchangée. Garder la machine `pendingScrubTargetMs` hors du
gate. Bonus : `isHidden = true` en fin d'animation de masquage (le panneau info le
fait déjà).
**Impact :** temps main-thread continu en 4K — en concurrence directe avec la
livraison d'images sur A15 (le cas hvcC/logiciel documenté) ; batterie iOS.

#### F-5 · Vignettes de chapitres : rafale de requêtes au moment exact de l'ouverture du flux
`VLCStreamPresenter.swift:1934-1951` (VLC) et `ChapterController.swift:58-78`
(natif) : une `Task` par chapitre, immédiatement, au `startPlayback` — un film à
30 chapitres = 30 requêtes `AuthenticatedImageFetch` pendant que libVLC ouvre le
flux, occupant l'origin sur toute la fenêtre d'ouverture. Côté natif, le
`withTaskGroup` est non borné **et** tout-ou-rien (un thumbnail lent retarde toute
la barre). Déjà signalé en juillet, non corrigé (seul le skip `imageTag == nil` a
été ajouté).
**Fix :** différer le lot après `noteMediaOpened()` au minimum ; idéalement,
fetch fenêtré sur les chips visibles (le delegate de scroll est déjà câblé) ;
côté natif, cap à ~4 en vol + application incrémentale.
**Impact :** time-to-first-frame sur serveur auto-hébergé/reverse-proxy.

#### F-6 · Navigation épisode VLC : une négociation PlaybackInfo entière jetée + session serveur orpheline
`VLCStreamPresenter.swift:2570-2571` — `navigateToEpisode` await d'abord
`navigator(ref.id)` (`PlayLink.swift:66-72`) qui fait un `getPlaybackInfo` complet
**moteur natif**… dont seul le couple prev/next (de purs lookups de tableau) est
consommé, puis re-négocie en `.vlc`. Chaque Next/autoplay paie donc un `getItem` +
`POST PlaybackInfo` de trop **en séquentiel sur le chemin critique**, et la
négociation jetée a ouvert un live stream côté serveur (`isAutoOpenLiveStream`)
que personne ne referme.
**Fix :** exposer un `neighbors: @Sendable (String) -> (EpisodeRef?, EpisodeRef?)`
synchrone à côté du navigator (la closure capture déjà `refs`/`indexByID`) et
l'utiliser côté VLC ; le chemin natif garde le navigator actuel.
**Impact :** ~0,2-1 s de latence par transition d'épisode + une session/flux
orphelin par transition.

#### F-7 · Widget iOS : posters téléchargés en série → widget « mort » sur serveur lent
`Widgets/CinemaxWidget/CinemaxWidget.swift:146-153` — boucle `for` séquentielle,
jusqu'à 7 posters × timeout 10 s sur une session sans cache. Pire cas ≈ 80 s :
WidgetKit tue l'extension avant, le handler ne rend jamais la timeline, le widget
garde son ancienne entrée indéfiniment, sans erreur visible.
**Fix :** `withTaskGroup` borné à 4 + timeout requête ~5 s (même octets, juste
parallèles). Idem `getSnapshot`.

#### F-8 · Bibliothèque : « marquer vu » déclenche le fan-out complet (9-10 requêtes) par onglet visité
`MovieLibraryScreen.swift:137-139` — le tier-2 `.cinemaxItemUserDataChanged`
appelle `reloadOrDefer()` sans condition → `reload` non gaté → 1 hero + 8 genres
+ éventuel filtre, **par onglet bibliothèque encore vivant dans le TabView**.
Or en mode browse rien de visible ne dépend de l'état vu (les cartes n'ont pas de
badge — documenté), et le menu contextuel garde son propre `playedOverride`. La
justification documentée (« le filtre non-vus doit refléter ») ne vaut que si
`showUnwatchedOnly` est actif.
**Fix :** `guard viewModel.sortFilter.showUnwatchedOnly else { return }` sur la
branche tier-2 (tier-1 inchangé).
**Impact :** un appui long « vu » coûte aujourd'hui ~10 requêtes immédiates + ~9
par autre onglet bibliothèque visité, et un remaniement visible de 1-3 s.

#### F-9 · `getItems` — l'endpoint le plus chaud de l'app — n'a aucun cache
`JellyfinAPIClient+Library.swift:77-119` — zéro `cache.get`/`set`, contrairement à
ses 8 voisins du même fichier. Il alimente : rangées Home (favoris + genres), hero
+ 8 genres + grille filtrée de chaque bibliothèque, Favoris, Historique, Surprise
Me, membres de collection. Chaque reload repaye plein pot des rangées de genre
byte-identiques ; combiné à F-8, un toggle « vu » re-télécharge 8 rangées qui
n'ont pas pu changer.
**Fix :** TTL 30-60 s, clé sur le tuple **complet** (`parentId`, types, tris,
genres, années, `isFavorite`, `filters`, `limit`, `startIndex`, rating cap — les
écrans Favoris/Historique ne diffèrent que par `isFavorite`/`filters` : les omettre
= collision inter-écrans), + ajout du préfixe `items-` au sweep des mutateurs
userData/favoris. C'est aussi ce qui rend F-8 totalement sûr.

### 1.3 Sévérité moyenne

| # | Constat | Où | Fix résumé |
|---|---|---|---|
| F-10 | `NetworkMonitor` écrit `isOnline` sans garde d'égalité à chaque update de path (interface, DNS, flags), et la racine l'observe (`onChange` dans le body) → invalidations de tout l'arbre au churn réseau (trajet, cellulaire) | `NetworkMonitor.swift:19-24` + `AppNavigation.swift:982` | `guard online != isOnline` + comparaison côté handler avant d'allouer la `Task` |
| F-11 | La sonde transport tourne **2×** à chaque lancement (`.task` racine + `onChange(serverURL)` déclenché par `restoreSession`), et re-tourne à chaque `.inactive→.active` (Centre de contrôle, bannière de notif…) — 2 `getaddrinfo` bloquants + poignée TLS ≤4 s à chaque fois | `AppNavigation.swift:900,925,965` | Supprimer le `configure` du `.task` ; gater le `refresh()` de `.active` sur `lastBackgroundedAt != nil` |
| F-12 | Les `getaddrinfo` de la sonde bloquent un thread du pool coopératif Swift (jusqu'à plusieurs secondes sur les réseaux dégradés que la sonde cible) — sur Apple TV 2 cœurs c'est la moitié du pool, `getPlaybackInfo` du tap Lecture attend derrière | `CinemaxStreamProxy.swift:97-143` | Continuation sur une `DispatchQueue` dédiée (le voisin `ipv6ResolvesQuickly` le fait déjà) ; annulation réelle de la sonde (`withTaskCancellationHandler`) |
| F-13 | `connectToServer`/`authenticate` ne vident pas `APICache` et la clé `serverInfo` n'est pas scopée serveur → info/version du serveur A servies pendant l'ajout du serveur B (latent mais à un call-site près : gating de version pointé sur le mauvais serveur) — *reliquat de l'audit de juillet* | `JellyfinAPIClient.swift:190-284,218` | `cache.clear()` dans `connectToServer` après `setClient` ; clé `serverInfo-<url>` |
| F-14 | `validateSession` jette le `UserDto` qu'il vient de recevoir, puis `refreshCurrentUser` re-fetch le même document → 2 aller-retours à chaque retour premier plan >60 s et chaque récupération de 401 | `JellyfinAPIClient+Session.swift:26` + `AppNavigation.swift:702` | `.valid(UserDto)` ou variante retournant le DTO |
| F-15 | Hero bibliothèque : `limit: 20` pour n'utiliser que `items.first` + `totalCount` (identique avec `limit: 1`) — 19 items avec overview complet jetés, sur la requête qui gate le skeleton | `MediaLibraryViewModel.swift:167-181` | `limit: 1` |
| F-16 | `getItems` sur-fetch `.overview` (300-1500 o/item) pour toutes les grilles/rangées alors que seul le hero le lit → ~60-170 Ko de JSON jetés par chargement de bibliothèque | `JellyfinAPIClient+Library.swift:108` | Paramètre `fields:` avec défaut maigre ; `.overview` réservé aux 2 requêtes hero |
| F-17 | `getCollections` : requête spéculative hand-built (violation de la RULE « capability gating via `ServerVersion` » → 404 garanti sur serveurs <10.11 à chaque ouverture de film) + fallback scan boxsets récursif **sans `limit`** ni rating cap, non caché | `JellyfinAPIClient+Library.swift:463-496` | Seuil `ServerVersion.itemCollectionsEndpoint = 10.11` ; `limit` sur le fallback ; cache `collections-` 300 s |
| F-18 | iOS : chaque pop-back vers un détail relance `load()` complet (pas de latch `hasLoaded`, contrairement aux 4 autres VMs) → spinner plein écran sur du contenu déjà rendu + ~5-7 requêtes, y compris `loadCollection`/`loadRemoteTargets` jamais nécessaires en ré-entrée | `MediaDetailScreen.swift:118-119`, `MediaDetailViewModel.swift:88` | Latch `hasLoaded` + hook de dismiss iOS vers `refreshAfterPlayback` (le tvOS l'a déjà) |
| F-19 | Recherche : chaque tap sur un chip de scope re-fan-out jusqu'à 5 `searchItems` sans cache (All→Films→Séries→All = ~20 requêtes pour des sous-ensembles stricts) | `SearchViewModel.swift:392`, ranker `:127-178` | TTL 60 s sur `searchItems` keyé terme+types+cap |
| F-20 | Home : aucune extraction `Equatable` sur les rangées → les ~8-10 tranches du rendu progressif re-rendent toutes les rangées + cartes matérialisées à chaque passe ; idem à chaque tier-2 | `HomeScreen.swift:282-323` | Extraire les rangées en `View, Equatable` (recette `MediaDetail*Section` existante) |
| F-21 | Home : `refreshUserDataRails` refait le fetch favoris à chaque événement tier-2 (un changement vu/position ne peut pas changer les favoris, la rangée n'affiche rien d'userData) ; et l'observer `.cinemaxFavoritesChanged` n'a pas de déferral `isVisible` (N cœurs togglés depuis une grille = N fetches Home cachée) | `HomeViewModel.swift:368-373`, `HomeScreen.swift:90-92` | Retirer favoris du tier-2 ; ajouter le `pendingFavoritesRefresh` gaté `isVisible` |
| F-22 | Bibliothèque browse : 8 écritures dict incrémentales × rangées non-`Equatable` + closures fraîches par passe → jusqu'à ~512 évaluations de body de carte + 512 constructions d'URL pendant un chargement browse tvOS | `MediaLibraryViewModel.swift:257`, `MovieLibraryScreen.swift:254-276` | `LibraryGenreRow`/`LibraryPosterCard` `Equatable` + `.equatable()` ; écrire le dict par chunk |
| F-23 | `MediaDetailScreen` : le classement multi-versions (`MediaSourceQuality.ranked`) est recalculé 4-6× par passe de body (badges, versionRow, actionButtons, badges re-rank si `source == nil`) | `MediaDetailScreen.swift:503-521,282,550,857` | Résoudre une fois dans `detailContent` et threader |
| F-24 | `MediaDetail` : le `LazyVStack` n'a que 2 enfants (backdrop + tout-le-reste en `VStack` eager) → cast, épisodes, collection, similaires se construisent et lancent leurs images immédiatement | `MediaDetailScreen.swift:199-211,251-258` | Émettre les sections comme enfants directs du `LazyVStack` (pattern `HomeScreen.content`) |
| F-25 | `MPNowPlayingInfoCenter` republié **chaque seconde** (XPC vers mediaremoted, ~7 200 fois par film) alors que le système extrapole via elapsed+rate — la Live Activity d'à côté ne pousse que sur discontinuité | `NowPlayingInfoController.swift:75-84` | Même forme de throttle que `PlaybackActivityThrottle` (rate flip, seek, durée connue, sinon ~5 s) |
| F-26 | Trickplay : la planche JPEG (≈5,7 MP) est stockée non décodée ; le crop se fait **sur le main actor à chaque frame de geste** de scrub → décodage complet livré sur le thread principal pendant le drag | `TrickplayController.swift:103-146` | `preparingForDisplay()` hors main à l'insertion en cache ; mémoïser le dernier crop |
| F-27 | `SleepTimerController` : boucle 1 s à soi (violation de la RULE « un seul tick, les sous-contrôleurs n'ajoutent jamais le leur » — le chemin VLC fait correct) + `UIVisualEffectView` blur **vivant au-dessus de la vidéo** pendant toute la fenêtre (≤90 min) = re-blur GPU à chaque frame | `SleepTimerController.swift:67-80,129` | Brancher sur le tick partagé ; fill translucide plat (les deux patterns corrects existent déjà dans le repo) |
| F-28 | `reResolveAndResume` (réveil) écrase `info` sans libérer l'ancienne session (`playSessionId`/`liveStreamId` jetés, pas de `closeLiveStream`/`stopEncoding`) → sur un transcode, l'ancien job ffmpeg reste en vie à côté du nouveau → contention CPU serveur → le nouveau flux saccade | `VLCStreamPresenter.swift:3309-3313` | Libérer l'ancienne session comme le fait le chemin d'échec (`releaseServerSessionAfterFailure`) |
| F-29 | Event-stream VLC : le `guard let self` promeut la capture en forte pour toute la boucle `for await`, et `teardown()` n'a qu'un déclencheur (`viewWillDisappear` + `isBeingDismissed`) → tout dismissal atypique fuit le graphe entier + un heartbeat 1 s zombie qui continue de reporter au serveur | `VLCStreamPresenter.swift:774-776,513-560` | Ré-acquérir `self` faiblement par itération ; filet `deinit` (annuler eventsTask + timers) |
| F-30 | `reconnect`/`setClient` ne fait jamais `invalidateAndCancel()` sur l'ancien client — un switch serveur en construit 2-3, chacun avec son pool de connexions retenu jusqu'à la fin du process | `JellyfinAPIClient.swift:374-394` | Invalider la session sortante dans `setClient` |
| F-31 | Images surdimensionnées : `CastCircle` 80 pt demande `maxWidth: 200` (6,25× les pixels utiles sur tvOS, ×20 portraits) ; rangées de genre/similaires 200 pt demandent 300 | `MediaDetailCastSection.swift:47`, `LibraryGenreRow.swift:46`… | Threader la largeur réelle (buckets 200/300/400 pour rester cache-friendly + byte-identical au prefetch) |
| F-32 | Carrousel hero iOS : les candidats 2-5 ne sont jamais préchargés → flash du fallback gris à la rotation 8 s (le pixel le plus regardé de l'app) exactement ce que la condition `hasBackdropImage` voulait éviter | `HomeScreen.swift:162-178,405-416` | Précharger les URLs hero (byte-identical, `backdropPixelWidth` inclus) |
| F-33 | `ImageURLBuilder.screenPixelWidth` énumère `UIApplication.connectedScenes` à chaque passe de body des 3 heroes les plus chauds | `ImageURLBuilder.swift:54-75` | Mémoïser, invalider sur `.active` |
| F-34 | `PosterCardContent` instancie un `@AppStorage` (= un observer UserDefaults) **par carte** tvOS pour `dimUnfocusedPosters` → des centaines d'observers vivants pour un Bool quasi immuable | `LibraryPosterCard.swift:113` | Promouvoir en `EnvironmentValues` injecté une fois à la racine (pattern `motionEffectsEnabled`) |

### 1.4 Sévérité basse (hygiène, par ordre d'intérêt)

- **F-35** `APICache.set` reconstruit tout le dictionnaire à chaque écriture (`store.filter` sous lock) — avec ~100 entrées `similar-` (TTL 300 s) vivantes après une session de navigation, chaque écriture chaude paie le sweep. Amortir (`if store.count > 64`) — `APICache.swift:24-36`.
- **F-36** Le single-flight ne couvre que `getItem` ; `getEpisodes`/`getSeasons`/`getNextUp`… double-fetchent sur miss concurrent (cas réel : fan-out Home + ouverture détail sur la même saison), et les clés `inFlight` ne sont pas namespacées par type (piège latent) — `APICache.swift:61-77`.
- **F-37** `clearContinueWatching` : jusqu'à 50 POST **séquentiels** (~5 s), chacun déclenchant 5 sweeps de cache complets — chunker à 6 comme partout — `PrivacySecurityScreen.swift:515-541`.
- **F-38** 6 IPC Keychain synchrones avant le premier rendu, dont la liste `servers` lue+décodée **2×** — passer la liste déjà lue à `migrateToMultiServerIfNeeded` — `AppNavigation.swift:119-138`.
- **F-39** Écouteur loopback démarré à chaque lancement avant de savoir si le proxy servira (`prestart()` inconditionnel) — ne pré-démarrer que si `preferProxy` — `CinemaxStreamProxy.swift:58`.
- **F-40** `purgeLegacyDownloads` : `removeObject` UserDefaults inconditionnel + stat FS à chaque lancement, pour toujours — garde de présence (le scrub d'`ExtensionSessionBridge` fait déjà correct) — `AppNavigation.swift:794-806`.
- **F-41** Vignettes de chapitres VLC cachées sous une clé porteuse de token (`api_key` dans l'URL) → doublons disque vs chemin natif + cache invalidé à chaque rotation de token ; idem planches trickplay (~23 Mo re-téléchargés par génération de token) — `VLCStreamPresenter.swift:2026-2028`, `TrickplayController.swift:152-155`.
- **F-42** `PosterPrefetcher.prefetched` non borné (des milliers d'URLs après une longue session tvOS) ; pas de `reset()` au changement de filtre ni re-prefetch après `reloadGenreItems` ; prefetch de la page N re-mappe toute la liste — `PosterPrefetcher.swift:19`, `MovieLibraryScreen.swift:128-130`.
- **F-43** `FlowLayout` sans cache de layout (2n-4n mesures de texte par passe) — sensible sur la feuille filtres avec 25-60 chips de genre — `FlowLayout.swift:4-53`.
- **F-44** `persistRegistry` réécrit `active_server_id` même inchangé (4 opérations SecItem par appel) et le sweep de reachability le déclenche par entrée — `AppNavigation.swift:310-320`.
- **F-45** Divers micro : `Task` par tick du heartbeat VLC au lieu d'`assumeIsolated` (le natif fait correct) ; publishers `NotificationCenter` recréés par body racine ; regex VTT recompilée par segment (`HLSManifestLoader.swift:130`) ; `Date.formatted` par ligne d'épisode ; fermeture socket au background dispatchée en `Task` non structurée (close frame best-effort) ; `.id(item.id)` redondant sur les cartes de grille (ancre `Optional<String>` vs `scrollTo(String)` — la jump bar A→Z peut être un no-op, à vérifier sur device).

### 1.5 Ordre de travail suggéré

1. **Lot « lecteur »** (le plus visible sur A15) : F-4 (HUD gate), F-6 (double négociation), F-5 (chapitres), F-28 (fuite session réveil), F-26 (trickplay decode).
2. **Lot « rendu »** : F-2 + F-3 (accents/racine — petits diffs, gain global), F-1 (recherche tvOS), F-22/F-20 (Equatable Library/Home).
3. **Lot « réseau »** : F-9 (`getItems` cache) + F-8 (gate tier-2) ensemble, F-16/F-15 (payloads), F-13 (reliquat juillet), F-19 (chips recherche).
4. **Lot « infra »** : F-7 (widget), F-10/F-11/F-12 (sondes/monitor), F-14, F-29/F-30.
5. Le reste opportuniste.

---

## Partie 2 — Nouveautés proposées

Légende effort : ⭐ léger (quelques jours) · ⭐⭐ moyen · ⭐⭐⭐ gros chantier.
Les numéros (#N) renvoient aux propositions de `docs/jellyfin-api-analysis.md`
quand elles y existent (statut : 3, 6, 9, 10 déjà livrées).

### A. Lecture — le cœur de l'app

| Nouveauté | Avantages | Inconvénients | Effort |
|---|---|---|---|
| **Auto-skip intro/générique** — réglage « passer automatiquement » (+ toast « Intro passée » avec annulation) | Très demandé sur tous les clients Jellyfin ; quasi gratuit : `SkipSegmentController` connaît déjà les fenêtres ; différenciateur salon tvOS | Dépend du plugin Intro Skipper (déjà le cas du bouton) ; risque de sauter du contenu voulu → le toast-annulation est indispensable ; 2 réglages (intro/générique) à câbler sur les 2 moteurs | ⭐ |
| **Segments `recap`/`preview`** (#1) — « Passer le résumé » sur les séries | Complète un squelette existant (`getMediaSegments` ne demande que 2 types sur 6) ; même UI que Skip Intro | Dépend du plugin qui génère ces segments ; rare sur les petites installs | ⭐ |
| **Préférences audio/sous-titres du compte serveur** (#4) — appliquer `SubtitleMode`/langues du profil Jellyfin au choix de piste initial | Bonne piste au 1er coup ; cohérence avec les autres clients ; lecture seule = sans risque | L'écriture modifierait un réglage global partagé entre clients (à éviter en v1 — lecture seule) | ⭐⭐ |
| **Apparence des sous-titres (chemin VLC)** — taille / fond / position | libVLC l'expose ; le chemin natif hérite des réglages système mais les utilisateurs VLC n'ont aucun contrôle ; confort majeur salon | Surface de réglages par moteur (le natif ne l'aura pas → asymétrie à expliquer) ; API SwiftVLC 1.0.0 à valider d'abord | ⭐⭐ |
| **Débit adaptatif** (#5) — `GET /Playback/BitrateTest` pour choisir `maxBitrate` hors LAN | Moins de buffering en 4G/extérieur ; moins de transcodes inutiles en LAN | Consomme de la data au test ; heuristique imparfaite ; interaction avec le réglage `render4K` à clarifier | ⭐⭐ |
| **File d'attente / lecture continue des playlists & collections** — « Tout lire » + aléatoire | Suite logique des playlists en écriture (1.1.x) ; les dossiers se parcourent déjà | Explicitement écarté en v1 pour une bonne raison : une 2e machine d'état à côté d'`EpisodeNavigator` dans un présentateur de 3 400 lignes = source de bugs garantie ; à ne faire qu'après le refactor du présentateur | ⭐⭐⭐ |
| **Watch Together : ré-activation** — lever le kill-switch `watchTogetherEnabled` | Tout le code existe (contrôleur, socket, sheet, pill HUD) et compile ; différenciateur majeur (très peu de clients Apple le font) ; la migration SDK est faite | Bloquant technique documenté : fusionner `SessionSocket` + `SyncPlaySocket` en un seul socket à fan-out (RULE « un socket par session ») ; QA multi-appareils lourde ; c'est « pas production-ready » pour des raisons qu'il faudra requalifier | ⭐⭐⭐ |

### B. Découverte & Home

| Nouveauté | Avantages | Inconvénients | Effort |
|---|---|---|---|
| **Note utilisateur pouce ↑/↓** (#11) — `POST/DELETE /UserItems/{id}/Rating` | Trivial côté API ; signal personnel qui alimente les recos serveur ; complète le cœur/favori | Risque de confusion cœur vs pouce → placement UI à soigner (menu contextuel + détail seulement) | ⭐ |
| **Rangées de recommandations serveur** (#8) — « Parce que vous avez regardé… » | Home vivante, découverte réelle, données déjà calculées par Jellyfin | Coûteux pour un serveur auto-hébergé modeste (requêtes de plus par chargement Home) → derrière un toggle `home.show*` default-off | ⭐⭐ |
| **Notifications nouveaux épisodes (iOS)** — background refresh sur Next Up des séries favorites + notification locale | Rétention ; use case réel (« S02E05 dispo ») | `BGAppRefreshTask` imprévisible (le système décide) ; serveur souvent injoignable hors LAN → taux d'échec élevé ; réglage par série à construire ; **pas de tvOS** | ⭐⭐ |
| **Indexation Spotlight** (`CoreSpotlight`) — titres de la bibliothèque dans la recherche système | Le socle App Intents est déjà « shaped to accept » ; recherche système + Siri renforcés | Index à maintenir (invalidation multi-serveur, respect de `privacy.maxContentAge` — même règle que `IntentSessionProvider`) ; volumétrie sur grosses bibliothèques | ⭐⭐ |

### C. Plateforme & finitions

| Nouveauté | Avantages | Inconvénients | Effort |
|---|---|---|---|
| **Bandes-annonces & bonus locaux** (#2) — `LocalTrailers`/`SpecialFeatures` via le lecteur interne | Contenu déjà sur le serveur, aujourd'hui invisible ; **débloque la bande-annonce sur tvOS** (aujourd'hui iOS-only via Safari) ; API triviale | Rangée vide sur la plupart des bibliothèques (extras rares) → affichage conditionnel | ⭐ |
| **Écran profil : mot de passe + avatar** — le `v2-todo.md` existant | Déjà spécifié (routes, endpoints, strings) ; App Review avait flaggé le stub retiré ; attendu d'un client « fini » | Upload avatar multipart à écrire ; iOS-only (assumé — saisie mdp à la télécommande = mauvaise UX) | ⭐ |
| **Live Activity interactive** — pause/lecture depuis l'écran verrouillé (`LiveActivityIntent`) | Explicitement prévu « v2 » dans le code ; l'infra display-only est solide ; très visible | L'intent doit piloter le player in-process (app suspendue = cas limites) ; ActivityKit interactif = matrice de QA verrouillé/background | ⭐⭐ |
| **Widgets Lock Screen / StandBy** — familles accessoires | Pipeline `PosterRail` réutilisable ; visibilité quotidienne | Très petites surfaces (peu d'info) ; valeur modérée ; à faire après le fix F-7 | ⭐ |
| **PIN parental** — verrou local sur le changement de profil / le déblocage du rating cap | Complète `privacy.maxContentAge` ; demande classique des familles | Sécurité de façade (PIN local, pas serveur) — à assumer comme « confort », pas comme sécurité ; UX de saisie tvOS | ⭐⭐ |
| **Recherche dans les Réglages (iOS)** — filtre sur les catalogues de rows | Réglages à 3 niveaux maintenant ; les rows sont déjà data-driven (`SettingsToggleRow`) → très peu de code | Valeur marginale tant que le nombre de réglages reste maîtrisé | ⭐ |
| **Avatars serveur** (#15) + **branding login** (#16) | Finition visuelle ; écran de login « fini » | Piège multi-serveur documenté (RULE ServersScreen c — l'avatar d'une entrée non active 404) ; chemin mort si pas de provider | ⭐ |

### D. Écartés (avec raison)

- **Réintroduction du offline/downloads** : retiré sous App Review 5.2.3 ; tout le code a été supprimé et un janitor purge les restes. Re-risquer un rejet + re-écrire le sous-système = non, sauf changement de politique Apple.
- **Live TV / DVR** (#19) : chantier énorme, intestable sans tuner, nul pour l'utilisateur type.
- **AirPlay vidéo sur le chemin VLC** : impossibilité technique documentée (libVLC), déjà actée.
- **File d'attente dans le lecteur** hors playlists : recouvert par la ligne « file d'attente » ci-dessus — à ne considérer qu'après refactor du présentateur.

### Recommandation

**Quick wins à fort impact (un cycle court) :** auto-skip intro/générique + segments
recap (même zone de code), bandes-annonces locales (débloque tvOS), pouce ↑/↓,
écran profil v2 (spéc déjà écrite). Cinq features visibles, toutes ⭐.

**Pari différenciant (un cycle long) :** ré-activation de Watch Together — c'est
la feature qu'aucun autre client Apple ne fait bien, et 90 % du code dort déjà
derrière le kill-switch. Pré-requis : fusion des deux sockets.

**À faire d'abord quoi qu'il arrive :** le lot perf « lecteur » (F-4/F-5/F-6/F-28)
— il améliore chaque session de visionnage existante, sur le matériel le plus
contraint (Apple TV A15), avant d'ajouter quoi que ce soit de neuf.
