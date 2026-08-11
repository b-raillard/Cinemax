# Cinemax — Check performance & propositions de nouveautés (2026-08-05, v1.2.0)

Périmètre : audit de performance frais du code actuel (multi-serveur, « Lire
sur… », playlists, Live Activity, App Intents, recherche de personnes, proxy
loopback, SwiftVLC 1.0.0), plus un listing de nouveautés candidates avec
avantages/inconvénients. CLAUDE.md a servi de vérité terrain : les décisions
documentées comme délibérées ne sont pas re-signalées ; les écarts aux contrats
documentés le sont.

> **Note de révision (rebase sur `main` @ `fd1a817`, release 1.2.0).** L'audit a
> été mené sur `4f80870` ; `main` a depuis avancé de 32 commits (lot « menus
> contextuels sur vignettes » + « Ajouts récents » multi-sources + release 1.2.0),
> touchant 20 des fichiers audités. **Les 45 constats ont été revérifiés : aucun
> n'est invalidé, aucun n'a été corrigé entre-temps.** Les références
> `fichier:ligne` ci-dessous sont à jour pour 1.2.0. Deux évolutions à signaler :
> - **F-7 a empiré** : `loadRecentlyAdded` ajoute désormais **deux** fetches JSON
>   séquentiels avant la boucle d'images série (pire cas du widget « Ajouts
>   récents » : 2 JSON + 7 images en série).
> - **Angle mort comblé** : les 642 lignes du nouveau lot cartes
>   (`CardActionPresenter`, `CardPlayTarget`, `MediaCardContextMenu`) ont fait
>   l'objet d'une passe dédiée — voir **§1.5**, 11 constats supplémentaires
>   (F-46 à F-56) dont 2 hauts et une régression utilisateur réelle.

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
| P6 — vignettes de chapitres chargées en rafale à l'ouverture | ✅ Corrigé sur cette branche (F-5) |
| P2/P3/P4/P7 — DownloadManager | N/A — la feature offline a été retirée (App Review 5.2.3) |

### 1.2 Sévérité haute — à corriger en premier

#### F-1 · Recherche tvOS : `ScrollView` imbriqué → la grille perd toute laziness
`Shared/Screens/SearchScreen.swift:66` (ScrollView externe tvOS) enveloppe
`SearchResultsGrid` (`:637`, `LazyVGrid` `:659`) qui contient son **propre**
`ScrollView`. Le scroll externe propose une hauteur non bornée → le scroll interne
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

#### F-4 · Lecteur : le HUD est repeint ~4×/s même masqué, pendant tout le film — ✅ corrigé sur cette branche
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

#### F-5 · Vignettes de chapitres : rafale de requêtes au moment exact de l'ouverture du flux — ✅ corrigé sur cette branche (chemin VLC ; le chemin natif `ChapterController` reste à faire)
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

#### F-6 · Navigation épisode VLC : une négociation PlaybackInfo entière jetée + session serveur orpheline — ✅ corrigé sur cette branche
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
`Widgets/CinemaxWidget/CinemaxWidget.swift:177-183` — boucle `for` séquentielle,
jusqu'à 7 posters × timeout 10 s (`JellyfinLite.swift:42`) sur une session sans
cache. Pire cas ≈ 80 s : WidgetKit tue l'extension avant, le handler ne rend jamais
la timeline, le widget garde son ancienne entrée indéfiniment, sans erreur visible.
**Aggravé en 1.2.0** : `loadRecentlyAdded` (`:142-156`) enchaîne désormais
`fetchRecentlyAdded` **puis** `fetchSeriesWithRecentEpisodes` en séquentiel avant
la boucle d'images — ce widget paie 2 JSON + 7 images, tous en série.
**Fix :** `withTaskGroup` borné à 4 pour les images + `async let` pour les deux
fetches JSON d'« Ajouts récents » + timeout requête ~5 s (même octets, juste
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
`JellyfinAPIClient+Library.swift:124-166` — zéro `cache.get`/`set`, contrairement à
ses 9 voisins du même fichier (le `getSeriesWithRecentEpisodes` ajouté en 1.2.0
prend, lui, un TTL de 60 s — `getItems` reste le seul non caché). Il alimente : rangées Home (favoris + genres), hero
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
| F-16 | `getItems` sur-fetch `.overview` (300-1500 o/item) pour toutes les grilles/rangées alors que seul le hero le lit → ~60-170 Ko de JSON jetés par chargement de bibliothèque | `JellyfinAPIClient+Library.swift:155` | Paramètre `fields:` avec défaut maigre ; `.overview` réservé aux 2 requêtes hero |
| F-17 | `getCollections` : requête spéculative hand-built (violation de la RULE « capability gating via `ServerVersion` » → 404 garanti sur serveurs <10.11 à chaque ouverture de film) + fallback scan boxsets récursif **sans `limit`** ni rating cap, non caché | `JellyfinAPIClient+Library.swift:510-540` | Seuil `ServerVersion.itemCollectionsEndpoint = 10.11` ; `limit` sur le fallback ; cache `collections-` 300 s |
| F-18 | iOS : chaque pop-back vers un détail relance `load()` complet (pas de latch `hasLoaded`, contrairement aux 4 autres VMs) → spinner plein écran sur du contenu déjà rendu + ~5-7 requêtes, y compris `loadCollection`/`loadRemoteTargets` jamais nécessaires en ré-entrée | `MediaDetailScreen.swift:119`, `MediaDetailViewModel.swift:84-88` | Latch `hasLoaded` + hook de dismiss iOS vers `refreshAfterPlayback` (le tvOS l'a déjà) |
| F-19 | Recherche : chaque tap sur un chip de scope re-fan-out jusqu'à 5 `searchItems` sans cache (All→Films→Séries→All = ~20 requêtes pour des sous-ensembles stricts) | `SearchViewModel.swift:392`, ranker `:127-178` | TTL 60 s sur `searchItems` keyé terme+types+cap |
| F-20 | Home : aucune extraction `Equatable` sur les rangées (0 occurrence de `View, Equatable` dans le fichier) → les ~8-10 tranches du rendu progressif re-rendent toutes les rangées + cartes matérialisées à chaque passe ; idem à chaque tier-2 | `HomeScreen.swift:232-330` | Extraire les rangées en `View, Equatable` (recette `MediaDetail*Section` existante) |
| F-21 | Home : `refreshUserDataRails` refait le fetch favoris à chaque événement tier-2 (un changement vu/position ne peut pas changer les favoris, la rangée n'affiche rien d'userData) ; et l'observer `.cinemaxFavoritesChanged` n'a pas de déferral `isVisible` (N cœurs togglés depuis une grille = N fetches Home cachée) | `HomeViewModel.swift:404-409`, `HomeScreen.swift:95-97` | Retirer favoris du tier-2 ; ajouter le `pendingFavoritesRefresh` gaté `isVisible` |
| F-22 | Bibliothèque browse : 8 écritures dict incrémentales × rangées non-`Equatable` + closures fraîches par passe → jusqu'à ~512 évaluations de body de carte + 512 constructions d'URL pendant un chargement browse tvOS | `MediaLibraryViewModel.swift:257`, `MovieLibraryScreen.swift:254-276` | `LibraryGenreRow`/`LibraryPosterCard` `Equatable` + `.equatable()` ; écrire le dict par chunk |
| F-23 | `MediaDetailScreen` : le classement multi-versions (`MediaSourceQuality.ranked`) est recalculé 4-6× par passe de body (badges, versionRow, actionButtons, badges re-rank si `source == nil`) | `MediaDetailScreen.swift:496-514,275` | Résoudre une fois dans `detailContent` et threader |
| F-24 | `MediaDetail` : le `LazyVStack` n'a que 2 enfants (backdrop + tout-le-reste en `VStack` eager) → cast, épisodes, collection, similaires se construisent et lancent leurs images immédiatement | `MediaDetailScreen.swift:194-198` | Émettre les sections comme enfants directs du `LazyVStack` (pattern `HomeScreen.content`) |
| F-25 | `MPNowPlayingInfoCenter` republié **chaque seconde** (XPC vers mediaremoted, ~7 200 fois par film) alors que le système extrapole via elapsed+rate — la Live Activity d'à côté ne pousse que sur discontinuité | `NowPlayingInfoController.swift:75-84` | Même forme de throttle que `PlaybackActivityThrottle` (rate flip, seek, durée connue, sinon ~5 s) |
| F-26 ✅ | Trickplay : la planche JPEG (≈5,7 MP) est stockée non décodée ; le crop se fait **sur le main actor à chaque frame de geste** de scrub → décodage complet livré sur le thread principal pendant le drag | `TrickplayController.swift:103-146` | `preparingForDisplay()` hors main à l'insertion en cache ; mémoïser le dernier crop |
| F-27 | `SleepTimerController` : boucle 1 s à soi (violation de la RULE « un seul tick, les sous-contrôleurs n'ajoutent jamais le leur » — le chemin VLC fait correct) + `UIVisualEffectView` blur **vivant au-dessus de la vidéo** pendant toute la fenêtre (≤90 min) = re-blur GPU à chaque frame | `SleepTimerController.swift:67-80,129` | Brancher sur le tick partagé ; fill translucide plat (les deux patterns corrects existent déjà dans le repo) |
| F-28 ✅ | `reResolveAndResume` (réveil) écrase `info` sans libérer l'ancienne session (`playSessionId`/`liveStreamId` jetés, pas de `closeLiveStream`/`stopEncoding`) → sur un transcode, l'ancien job ffmpeg reste en vie à côté du nouveau → contention CPU serveur → le nouveau flux saccade | `VLCStreamPresenter.swift:3309-3313` | Libérer l'ancienne session comme le fait le chemin d'échec (`releaseServerSessionAfterFailure`) |
| F-29 | Event-stream VLC : le `guard let self` promeut la capture en forte pour toute la boucle `for await`, et `teardown()` n'a qu'un déclencheur (`viewWillDisappear` + `isBeingDismissed`) → tout dismissal atypique fuit le graphe entier + un heartbeat 1 s zombie qui continue de reporter au serveur | `VLCStreamPresenter.swift:774-776,513-560` | Ré-acquérir `self` faiblement par itération ; filet `deinit` (annuler eventsTask + timers) |
| F-30 | `reconnect`/`setClient` ne fait jamais `invalidateAndCancel()` sur l'ancien client — un switch serveur en construit 2-3, chacun avec son pool de connexions retenu jusqu'à la fin du process | `JellyfinAPIClient.swift:374-394` | Invalider la session sortante dans `setClient` |
| F-31 | Images surdimensionnées : `CastCircle` 80 pt demande `maxWidth: 200` (6,25× les pixels utiles sur tvOS, ×20 portraits) ; rangées de genre/similaires 200 pt demandent 300 | `MediaDetailCastSection.swift:47`, `LibraryGenreRow.swift:46`… | Threader la largeur réelle (buckets 200/300/400 pour rester cache-friendly + byte-identical au prefetch) |
| F-32 | Carrousel hero iOS : `prefetchCardImages` ne précharge que posters/300 et backdrops/600 — les candidats hero 2-5 (backdrop à `backdropPixelWidth`) ne le sont jamais → flash du fallback gris à la rotation 8 s (le pixel le plus regardé de l'app), exactement ce que la condition `hasBackdropImage` voulait éviter | `HomeScreen.swift:170-187,413` | Précharger les URLs hero (byte-identical, `backdropPixelWidth` inclus) |
| F-33 | `ImageURLBuilder.screenPixelWidth` énumère `UIApplication.connectedScenes` à chaque passe de body des 3 heroes les plus chauds | `ImageURLBuilder.swift:54-75` | Mémoïser, invalider sur `.active` |
| F-34 | `PosterCardContent` instancie un `@AppStorage` (= un observer UserDefaults) **par carte** tvOS pour `dimUnfocusedPosters` → des centaines d'observers vivants pour un Bool quasi immuable | `LibraryPosterCard.swift:113` (inchangé en 1.2.0) | Promouvoir en `EnvironmentValues` injecté une fois à la racine (pattern `motionEffectsEnabled`) |

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

### 1.5 Lot « menus contextuels de vignettes » (1.2.0) — passe dédiée

Ce lot est postérieur à l'audit principal. Il attache un menu contextuel à **neuf**
sites d'appel via `MediaCardContextMenu`, avec `CardActionPresenter` (hôte racine)
et `CardPlayTarget` (résolveur de cible). Les décisions documentées (présentateur
hébergé à la racine, lectures `@Environment` optionnelles, résolveur ids-et-scalaires,
carte de série toujours étiquetée « Lecture », aperçu iOS explicite) ne sont pas
re-signalées.

#### F-46 · Tout l'arbre du menu ET l'aperçu iOS sont construits **par carte**, avidement — Haute — ✅ corrigé (le menu contextuel ne se construit plus par carte)
`MediaCardContextMenu.swift:112-125,127-243,256-276`. La prémisse « SwiftUI construit
le `contextMenu` paresseusement » ne tient pas pour cette forme : les deux surcharges
prennent des `@ViewBuilder` **non-échappants**, donc SwiftUI les invoque
synchroniquement pour produire les *valeurs* de vue. Pour chaque carte instanciée par
le conteneur lazy, on paie donc : `CardPlayTargetResolver.isResumable` (`:137`), une
lecture de `knownRemoteTargetCount` (`:182`), **5-6 `loc.localized(...)`** (8 sur une
carte Reprendre) puisque les closures `label:` sont aussi non-échappantes, **5-7 boîtes
de closure échappantes capturant `self`** — donc une copie du `BaseItemDto`, la
structure la plus large du SDK — et un `imageURL(...)` complet (`:262`/`:270`,
`URLComponents` + 3 `URLQueryItem` + re-sérialisation) **byte-identique à celui que la
carte vient de construire une ligne plus haut**. Rien de tout cela n'est montré sans
appui long. Sur la grille tvOS 6 colonnes (48 cartes visibles) : ~300 lookups localisés,
~300 boîtes de closure, 48 constructions d'URL redondantes par matérialisation
(≈1,5-3 ms, soit ~19 % d'une frame à 60 Hz).
**Fix :** (a) ne pas stocker le `BaseItemDto` — tous les champs lus sont des scalaires,
extraire un `CardMenuItem` au site d'appel (même discipline que le résolveur) ; (b)
déplacer les deux builders dans des `View` dédiées (`CardMenuContent`,
`CardArtworkPreview`) pour que `localized`/`imageURL` migrent dans `body`, évalué à
l'appui long ; (c) passer au paramètre `artwork:` l'URL **déjà construite** par la carte
— ce qui transforme la règle « byte-identique » d'un commentaire audité à la main sur
neuf sites en garantie structurelle, et supprime la construction en double.

#### F-47 · Chaque carte observe `knownRemoteTargetCount`, et chaque chargement de détail l'écrit sans garde → invalidation globale des cartes — Haute — ✅ corrigé (garde d'égalité + contrôle de génération)
`MediaCardContextMenu.swift:182` + `MediaDetailViewModel.swift:387` (`:136`).
Parce que `menuItems` est évalué avidement (F-46), la lecture ligne 182 enregistre une
dépendance Observation dans le body du modificateur de **chaque** carte. L'écrivain
(`cardActions?.knownRemoteTargetCount = remoteTargets.count`) n'a **aucune garde
d'égalité** — vérifié — et part d'un `Task` fire-and-forget à chaque `load()`, donc à
chaque ouverture de détail et chaque retry. `withMutation` se déclenche même à valeur
inchangée : ouvrir un film depuis Home invalide le modificateur de toutes les cartes
encore montées derrière (5 rails Home + Favoris poussé + toute `MediaLibraryScreen`
vivante), et chacune repaie le coût complet de F-46.
**Fix :** garder l'écriture (`if … != …`) ; mieux, faire migrer la lecture dans le
`body` de la vue dédiée de F-46 ; idéalement isoler le compteur dans un petit
`@Observable` séparé pour qu'il ne partage jamais une portée d'invalidation avec
`playback`/`remotePlay`.

#### F-48 · Le délai de 1,5 s du sondage next-up est **indicatif, pas appliqué** — et le test censé le verrouiller ne peut pas voir la différence — Moyenne — ✅ corrigé (vrai délai (Task non structurées + continuation à reprise unique) + test d'horloge)
`CardPlayTarget.swift:98-108`. `withTaskGroup` garantit le groupe vide au retour : il
**attend chaque enfant restant** après le corps. Donc `group.next()` + `cancelAll()`
rend la *décision* tout de suite, mais `resolve` ne retourne qu'une fois le sondage
réellement terminé — le commentaire du code l'admet (« still gets joined by the group's
implicit structured-concurrency teardown ») alors que CLAUDE.md décrit un vrai délai.
Le précédent cité (`PlaybackLiveActivityController:150-157`) a une forme *différente* :
deux `Task` non structurées + sentinelle de génération, donc un délai réel. La preuve
est déjà dans la suite : `MockAPIClient.getNextUp` dort avec `try? await Task.sleep`
(`:507`) — le `try?` avale `CancellationError`, donc le mock ignore `cancelAll()` et
dort les 300 ms complètes ; `seriesNextUpTimesOut` (`CardPlayTargetTests.swift:132-149`)
n'assert que le *résultat*, sans horloge, et ne distingue donc pas 50 ms de 300 ms —
or c'est 300 ms aujourd'hui.
**Fix :** ajouter une mesure `ContinuousClock` au test (il doit échouer, c'est le but),
puis adopter la forme du précédent (sondage + délai en `Task` non structurées,
continuation à reprise unique sous verrou). Exposition réelle limitée car
`URLSession` annule promptement — mais l'invariant n'est ni appliqué ni testé, et un
seul `await` non annulable sous `getNextUp` restaurerait le timeout client de 30 s sur
un chemin qui, de son propre commentaire (`:73`), n'a « aucune affordance de
chargement ».

#### F-49 · `loader.reset()` sur notification → un toggle depuis une grille paginée **renvoie l'utilisateur page 1** — Moyenne (régression visible) — ✅ corrigé (refreshLoadedSpan, plus de retour page 1)
`FavoritesScreen.swift:33-40` + `:102-115`, idem `WatchedHistoryScreen.swift:113-123`.
`load()` fait `loader.reset()` puis récupère la page 0, et l'écran observe les
notifications que **ses propres cartes** postent désormais. Défiler 400 favoris jusqu'à
la page 4, marquer une carte comme vue → la grille s'effondre à 40 éléments **sous le
doigt**, offset de scroll perdu. C'était atteignable avant (aller au détail, revenir),
mais l'attachement du menu sur la grille le rend immédiat et en place.
**Fix :** le patch en place de F-51 le résout ; sinon re-demander
`startIndex: 0, limit: loader.items.count` et diffuser dans le tableau existant.

#### F-50 · `SearchResultsGrid`/`SearchResultCard` deviennent définitivement non-court-circuitables — Moyenne — ✅ corrigé (Equatable + .equatable())
`SearchScreen.swift:628-631,658,740-746`. Les deux ont gagné un `let onGoToSeries:
(String) -> Void` ; SwiftUI traite toute propriété de type fonction comme
systématiquement inégale, donc l'optimisation « même valeur ⇒ pas de `body` » ne peut
plus jamais s'appliquer. `SearchScreen.body` se réévalue à **chaque frappe** → chaque
`SearchResultCard.body` → `imageURL` + tout l'arbre de menu avide de F-46. Avant ce lot,
la carte ne portait aucun champ fonction.
**Fix :** `Equatable` + `nonisolated static func ==` ignorant la closure (recette
`MediaDetailSimilarSection`) + `.equatable()` ; ou mieux, remplacer le callback par un
`@Observable SeriesNavigator` injecté — ce qui supprimerait `onGoToSeries` de
`SearchScreen`, `HomeScreen` et `WatchedHistoryScreen` d'un coup.

#### F-51 · Un toggle déclenche jusqu'à 4 rechargements complets non coordonnés, et la notification ne porte **aucun id** — Moyenne
`MediaCardContextMenu.swift:366,379`. Les deux posts sont `object: nil`, donc le seul
recours d'un observateur est un re-fetch complet. Le menu étant désormais sur neuf
surfaces, un toggle depuis une filmographie d'acteur ou « Plus comme ça » salit : Home
(3 fetches), **les deux** `MediaLibraryScreen` vivantes (hero + 8 genres chacune),
Favoris et Historique s'ils vivent — jusqu'à ~25 requêtes et ~1000 décodages de DTO pour
une seule coche. Deux des quatre observateurs n'ont pas le déferral `isVisible`
documenté (`FavoritesScreen:102-115`, `WatchedHistoryScreen:113-123`), et la branche
favoris de Home (`HomeScreen:95-97`) non plus (déjà F-21).
**Fix :** porter l'id + la valeur dans le `userInfo` et donner à chaque observateur un
chemin de patch en place (épisser l'élément), avec repli sur rechargement seulement si
l'id est absent ou qu'un filtre sensible à l'état vu est actif. `LibraryAPI.fetchUserData`
établit déjà le motif « ids en entrée, DTO en sortie ».

#### F-52 · `playedOverride`/`favoriteOverride` ne s'invalident jamais et masquent les données serveur fraîches — Moyenne — ✅ corrigé (OptimisticFlag auto-invalidant)
`MediaCardContextMenu.swift:109-110,129-130`. Rien ne les remet à `nil`, et l'identité de
vue survit aux rechargements (mêmes ids via `ForEach`). Marquer vu depuis la grille
(override = `true`), puis non-vu depuis l'écran de détail : la grille recharge avec
`isPlayed == false` mais le menu résout encore `true`, propose « Retirer des vus » sur un
item non vu, et un tap émet un `markItemUnplayed` redondant + une nouvelle tempête de
notifications. Les overrides sont réellement porteurs sur **deux** surfaces seulement
(`PersonDetailScreen`, `MediaDetailSimilarSection`, qui n'observent aucune des deux
notifications) ; sur les cinq autres ils doublonnent un rafraîchissement déjà en cours.
**Fix :** stocker l'override **avec la valeur serveur dont il dérive** et l'écarter dès
qu'elle change (`(base: Bool, value: Bool)?`, ou `.onChange(of: item.userData?.isPlayed)`).

#### F-53 · Aucune coalescence des rechargements : deux toggles rapides lancent deux fan-outs concurrents — Basse-Moyenne — ✅ corrigé (reload s'enregistre dans loadTask)
`MovieLibraryScreen.swift:152-164`. `performReload` enveloppe `reload` dans une `Task`
nue sans dédup ; `MediaLibraryViewModel.reload` draine un `loadTask` en vol mais ne
s'y **enregistre pas**, donc un second `reload` voit `loadTask == nil` et les deux
`performLoad` tournent en parallèle (~18 requêtes, dernier écrivain gagne sur
`itemsByGenre`). Le raisonnement d'annulation-et-drain du chargement initial montre que
le risque est compris ; `reload` n'est juste pas couvert.
**Fix :** affecter aussi le rechargement à `loadTask`, ou debouncer à l'observateur.

#### F-54 · `cancelAll()` jette le `getNextUp` en vol, donc le cache 10 s ne se réchauffe jamais après un dépassement — Basse — ✅ corrigé (le perdant n'est plus annulé)
`CardPlayTarget.swift:106` + `JellyfinAPIClient+Library.swift:364-379` (le cache est
peuplé **après** le retour de `client.send`). Annuler le sondage jette la réponse avant
sa mise en cache : le prochain tap sur la même carte re-sonde à froid et redépassera
probablement — exactement quand l'offset de reprise est le plus voulu.
**Fix :** ne pas annuler le perdant ; le laisser finir en fond pour réchauffer
`nextup-`. Coût nul, transforme un dépassement répété en dépassement unique.

#### F-55 · La règle de reprise est ré-exprimée en ligne sur Home, contournant le SSOT — Basse — ✅ corrigé (resumeSeconds promu, deux sites Home branchés)
`HomeScreen.swift:752-755` vs `CardPlayTarget.swift:133-140`.
`continueWatchingPlayLink` calcule `startSeconds` avec son propre `guard let ticks…` et
sa propre division par 10 000 000, **omettant la moitié `!isPlayed`** de la règle. Sans
effet aujourd'hui (le rail Reprendre ne renvoie que du non-vu), mais le `PlayLink` d'une
carte et l'entrée « Reprendre » de son menu dérivent l'offset de deux expressions d'une
même règle — la dérive exacte que le SSOT existe pour empêcher.
**Fix :** promouvoir et appeler `CardPlayTargetResolver.resumeSeconds(positionTicks:isPlayed:)`.

#### F-56 · Le sondage de cibles distantes écrit un état global sans contrôle de génération — Basse — ✅ corrigé (contrôle de génération (portée réelle documentée))
`MediaDetailViewModel.swift:136,387`. Le `Task` fire-and-forget n'honore pas
`loadGeneration` (que le reste du fichier respecte), et il écrit désormais dans le
`cardActions` **hébergé à la racine**, pas seulement dans l'état de son écran. Un détail
quitté depuis plusieurs secondes peut donc encore basculer le compteur qui gate
« Lire sur… » sur toutes les cartes vivantes.
**Fix :** capturer `generation` et le revérifier avant l'écriture, + la garde d'égalité de F-47.

#### Vérifié sain dans ce lot
- **Aucun sondage ni `Task` à la construction du menu** : `resolvedCardPlayTarget()` n'est
  atteignable que depuis `startPlayback`/`startRemotePlay`, appelés uniquement depuis des
  actions de `Button`. Ouvrir un menu coûte zéro réseau sur film/épisode, un appel
  (souvent caché) sur série.
- **Clé de cache `nextup-{seriesId}-{userId}` correcte** et le filtre de classification est
  ré-appliqué sur le chemin caché ; les invalidations des mutateurs restent étroites.
- **Aucune fuite dans la course** et rien de non-`Sendable` ne traverse la frontière du
  groupe (`NextUpProbeResult` ne porte que des scalaires — pas de transfert de région d'un
  `BaseItemDto`).
- **`.equatable()` de `MediaDetailSimilarSection` n'est pas défait** : le modificateur est
  attaché sans argument closure, le `==` custom compare les mêmes champs qu'avant.
- **`AddToPlaylistPresenter` et le `VideoPlayerCoordinator` tvOS sont lus en
  présence seule** (`if let` / `!= nil`), donc aucune carte n'enregistre de dépendance sur
  eux — c'est précisément la discipline que `knownRemoteTargetCount` casse (F-47), et le
  contraste dans un même fichier rend le constat sans ambiguïté.
- **`knownRemoteTargetCount` est bien invalidé** aux deux changements d'identité
  (URL serveur, id utilisateur).

### 1.6 Ordre de travail suggéré

1. ~~**Lot « lecteur »** : F-4 (HUD gate), F-6 (double négociation), F-5 (chapitres),
   F-28 (fuite session réveil), F-26 (trickplay decode).~~ ✅ **Fait** — implémenté sur
   cette branche (`perf(player): lot lecteur`). Non compilé localement (runner Linux
   sans toolchain Swift) : vérification par la CI.
2. ~~**Lot « cartes »** (§1.5) : F-46 + F-47 + F-52, puis F-49, F-50, F-48, F-53,
   F-54, F-55, F-56.~~ ✅ **Fait** — 10 des 11 constats du lot sont corrigés sur
   cette branche. **Reste F-51**, seul item non traité, et volontairement : il
   change un contrat documenté (la RULE du rafraîchissement à deux niveaux, dont
   les notifications ne portent aucun payload) et son « patch en place » n'est pas
   un splice générique — sur Favoris et Historique, dé-cocher doit *retirer* la
   carte, pas la mettre à jour, donc la logique est par écran. Son symptôme le plus
   douloureux (le retour page 1) est déjà supprimé par F-49 ; ce qui reste est du
   volume de requêtes en arrière-plan. À décider explicitement.
3. **Lot « rendu »** : F-2 + F-3 (accents/racine — petits diffs, gain global), F-1
   (recherche tvOS), F-22/F-20 (Equatable Library/Home).
4. **Lot « réseau »** : F-9 (`getItems` cache) + F-8 (gate tier-2) + F-51 (payload de
   notification + patch en place) ensemble — les trois attaquent la même tempête de
   rechargements ; puis F-16/F-15 (payloads), F-13 (reliquat juillet), F-19 (chips).
5. **Lot « infra »** : F-7 (widget), F-10/F-11/F-12 (sondes/monitor), F-14, F-29/F-30.
6. Le reste opportuniste.

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
