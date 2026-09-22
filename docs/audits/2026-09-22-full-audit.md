# Audit complet Cinemax — 2026-09-22

**Périmètre.** `main` à `aac5624` (release 2.1.1) : 342 fichiers Swift, environ 81 600 lignes (65 100 de production, 16 400 de tests), plus `project.yml`, la CI, les scripts, les ressources et `docs/`. Sept audits en lecture seule menés en parallèle : sécurité, performance, qualité/concurrence, code mort, UX/UI/accessibilité, bugs de fond, tests/CI/dépendances/docs.

**Méthode.** CLAUDE.md sert de référence : une décision qu'il documente comme délibérée n'est pas re-signalée ; un écart entre le code et ce qu'il affirme l'est. Chaque constat a été vérifié en lisant le source. Ceux marqués ✅ ont été contre-vérifiés une seconde fois pendant la consolidation. **Confirmé** = mécanisme établi par la lecture du code. **Hypothèse** = demande une mesure (Instruments, appareil, serveur).

**Pas de toolchain Swift dans l'environnement d'audit (Linux)** : rien n'a été compilé ni exécuté. Le code mort et les métriques viennent d'une analyse par scripts.

---

## Verdict

Le code est **d'un niveau de rigueur rare** pour un projet de cette taille :
- 0 `try!`, 0 `as!`, 1 seul force-unwrap (sans danger), 0 TODO/FIXME ;
- 0 erreur brute montrée à l'utilisateur ;
- parité FR/EN parfaite (1005/1005 clés, toutes utilisées) ;
- conformité mécanique au design system quasi totale (244 `.font(.system(size:))`, tous via `CinemaScale.pt`) ;
- code mort Swift marginal (~0,1 %) ;
- continuations toutes protégées contre le double resume, aucun verrou tenu pendant un `await` ;
- ~900 tests, CI verte sur les 8 dernières exécutions de `main`.

Les problèmes réels sont ailleurs :
1. **Quelques bugs de lecture et de session à fort impact utilisateur**, dont un qui efface le point de reprise côté serveur (B1).
2. **Deux trous de sécurité liés au Keychain et au contrôle parental** (S1, S3, S4).
3. **L'accessibilité** : VoiceOver, contraste des CTA accent, Dynamic Type — la conformité *visuelle* est excellente, la conformité *d'usage* beaucoup moins.
4. **La dette structurelle** : un contrôleur de lecture de 4 968 lignes, et un CLAUDE.md de **422 Ko (~100 000 tokens)** chargé par chaque session et chaque sous-agent.

---

## Top 12 — à traiter en premier

| # | Axe | Constat | Effort |
|---|---|---|---|
| B1 | Bug | Fermer le lecteur avant la reprise **efface le point de reprise côté serveur** (les deux moteurs) ✅ | S |
| B2 | Bug | Réveil de veille : une re-négociation qui échoue laisse un **spinner infini** sans alerte | S |
| B3 | Bug | Après une connexion fraîche, l'appareil **n'est pas une cible « Lire sur… »** et le socket n'est pas ouvert ✅ | XS |
| S1 | Sécu | Les éléments Keychain « privés » (jetons de **tous** les serveurs, verrou parental) sont écrits **dans le groupe partagé avec les extensions** ✅ | M |
| S2 | Sécu | Plafond parental serveur décalé d'une catégorie (12 → PG-13, 16 → TV-MA) — ouvert depuis juillet | S |
| S3 | Sécu | Contenu au-dessus du plafond lancé à distance (« Lire sur… », SyncPlay, raccourci) : la lecture démarre seule | M |
| P1 | Perf | La fiche **attend `/Similar`** avant de s'afficher, et son échec affiche l'écran d'erreur ✅ | XS |
| P2 | Perf | Recherche : `LazyVGrid` dans `LazyVStack` (forme proscrite par la RULE, risque d'onglet noir) + ScrollView doublé sur tvOS ✅ | S |
| U1 | UX | Serveur injoignable affiché comme **« Votre bibliothèque est vide »** ✅ | S |
| U2 | A11y | Écrans de connexion **sans AutoFill** (`textContentType`) ni touche Retour ✅ | XS |
| Q1 | Qualité | Écriture Keychain **non atomique** (delete puis add) : un échec perd jeton, registre ou verrou parental | S |
| D1 | Docs | CLAUDE.md fait **422 Ko** : à découper en CLAUDE.md imbriqués par dossier + ADR | M |

Effort : XS < 1 h · S < ½ j · M ≈ 1–2 j · L > 2 j.

---

## 1. Bugs de fond

### Haute

**B1. Le point de reprise est effacé côté serveur quand on ferme le lecteur avant que la reprise ait eu lieu** ✅
- **Où** : `VLCStreamPresenter.swift:922-925` (le `timeSource` renvoie `currentMs` brut) ; `:4875` (le seek de reprise n'a lieu qu'au premier tick avec `lengthMs > 0`) ; `PlaybackReporter.swift:115-127` (`reportStop` envoie `positionTicks` sans condition). Même schéma côté natif : `NativeVideoPresenter.swift:343-348`, NaN → 0.
- **Scénario** : « Reprendre » un film à 1 h 20, fermer pendant le spinner (ou après « Lecture impossible »). Jellyfin reçoit `PositionTicks = 0` et l'écrit : le film revient au début et sort de « Reprendre ». Même chose après une coupure à 45 min suivie d'un retry qui n'ouvre jamais.
- **Aggravant** : en fin de série, `handlePlaybackEnded` fait un `reportStop()` puis « Terminé » en déclenche un second via `viewWillDisappear`.
- **Correctif** : tant que `!mediaConfirmedOpen` ou que le seek de reprise n'a pas atterri, le `timeSource` renvoie `startTime ?? lastKnownPositionMs`. `reportStop` idempotent par `playSessionId`. Ne jamais omettre `PositionTicks` (Jellyfin marquerait l'élément vu).

**B2. Réveil de veille : une re-négociation qui échoue ne signale rien**
- **Où** : `VLCStreamPresenter.swift:4818` (branche d'échec de `reResolveAndResume`) et `:3422` (garde du watchdog `!hasValidTime && lengthMs <= 0`).
- **Mécanisme** : `hasValidTime` et `mediaLengthMs` datent du média d'avant la veille, et `beginOpenLoading` ne les remet pas à zéro : le watchdog ré-armé tire sans rien faire.
- **Scénario (Apple TV)** : veille pendant la lecture → au réveil, le Wi-Fi n'est pas encore revenu → `getPlaybackInfo` échoue → spinner infini ou image figée, sans alerte ni retry.
- **Correctif** : remettre `hasValidTime = false` et `mediaLengthMs = 0` avant d'armer le watchdog, ou appeler `handlePlaybackError()`.
- **Confiance** : logique confirmée ; l'ordre exact des événements au réveil reste à observer sur appareil.

### Moyenne

| # | Constat | Où | Correctif |
|---|---|---|---|
| B3 ✅ | Après une connexion fraîche (premier login, ré-login, ajout de serveur), `onChange(of: currentUserId)` appelle `remoteControl.apply` alors que `isAuthenticated` est encore `false` (posé après `refreshCurrentUser` + 400 ms) → `stop()`. Rien ne rappelle `apply` avant le prochain retour au premier plan : pas de « Lire sur… » entrant, pas d'invitation, pas de `UserUpdated`. | `LoginViewModel.swift:129-146` ; `AppNavigation.swift:1298` | `.onChange(of: appState.isAuthenticated)` qui appelle `apply` |
| B4 | Un changement de serveur qui échoue (`rollBackFailedSwitch`) efface la `ServerVersion` et rien ne la réapprend : plus de « Passer l'intro », plus de rangée Collections, jusqu'au relancement. Le cas « même serveur » a été corrigé en septembre ; le rollback, lui, part d'un client qui pointe encore sur la cible. | `AppNavigation.swift:525-560` ; `JellyfinAPIClient.swift:488` | Mémoriser la version avant `reconnect` et la restaurer, ou relancer `fetchServerInfo()` |
| B5 | Une récupération (réveil, blocage d'image, blocage du flux) re-négocie **sans `mediaSourceId`** et réapplique les pistes par défaut : la version 1080p choisie redevient la 4K (souvent la cause même du blocage), la VF redevient la VO. | `VLCStreamPresenter.swift:4811-4835` | Transmettre `info.mediaSourceId` et les pistes sélectionnées |
| B6 | Fiche : « Marquer comme vu » ne touche que `viewModel.isPlayed` ; `item.userData` garde la position → « Reprendre » reste actif et rouvre le film au milieu. C'est le défaut que la RULE `OptimisticFlag` a corrigé pour les menus contextuels. | `MediaDetailViewModel.swift:315-338` ; `MediaDetailScreen.swift:1029` | Mettre à jour `item?.userData` après succès ; re-fetcher `nextUp` pour une série |
| B7 | tvOS : le héros d'Accueil n'est jamais recalculé après une lecture (`heroItem` n'est écrit que par `load()`). Le rail affiche 40 min, le « Reprendre » du héros repart à 10 min. | `HomeViewModel.swift:327`, `:504` | Recalculer `heroItem` dans `refreshResume` |
| B8 | Fiche série : `refreshAfterPlayback` / `refreshVisibleEpisodes` écrivent `episodes` sans vérifier que la saison sélectionnée n'a pas changé entre-temps → sélecteur sur S2, liste de S1. | `MediaDetailViewModel.swift:232-248`, `:412-415` | `guard selectedSeasonId == seasonId` avant l'écriture |
| B9 | `handleFailedEpisodeNav` suppose que l'épisode courant joue encore ; pendant la fenêtre d'un retry (jusqu'à ~2,5 s), un Suivant qui échoue laisse un spinner infini. | `VLCStreamPresenter.swift:3909-3932` | Si `!mediaConfirmedOpen`, passer par `handlePlaybackError()` |
| B10 | `switchTo` repointe le client partagé **avant** de valider la cible : pendant jusqu'à 30 s, toute l'UI requête la cible avec l'`userId` du serveur précédent ; un 401 concurrent peut faire effacer les identifiants du serveur **précédent** par la coordination d'expiration. | `AppNavigation.swift:525-527` | Valider sur un client autonome (modèle `ServerReachability`) avant `reconnect` — *probable* |
| B11 | `NativeVideoPresenter.navigateToEpisode` n'a ni `navGeneration` ni reprise sur échec : deux appuis sur Suivant = deux `reportStop` ; un échec laisse l'ancien épisode sans session serveur. La RULE « MUST recover » n'est appliquée qu'à VLC. | `NativeVideoPresenter.swift:563-626` | Porter `handleFailedEpisodeNav` et la génération |
| B12 | `PlaybackReporter` : start/progress/stop/ping sont chacun un `Task.detached` indépendant → un progress lancé juste avant un stop peut arriver après lui (session zombie, position réécrite). | `PlaybackReporter.swift:97-217` | File sérielle (motif `ProfileModel`) |
| B13 | `HomeViewModel` : aucune génération sur `load()` ni sur les rafraîchissements partiels lancés par des `Task {}` non annulés → « dernier arrivé gagne », et après un changement de serveur les rails de A peuvent rester (`case nil: break`). | `HomeViewModel.swift:322`, `:501-722` | Compteur `loadGeneration` comme `MediaDetailViewModel` ; vider les rails sur changement de serveur |

### Basse
- **APICache** : `invalidate`/`clear` ne touchent pas `inFlight` et aucun `set` n'est gardé par génération → une réponse d'avant une mutation (`markItemPlayed`) est remise en cache 10–30 s ✅ (`APICache.swift:38-77`). Correctif : compteur de génération vérifié au `set`.
- `MediaLibraryViewModel.loadHeroNavigation` écrit `heroPlay` sans vérifier que le héros n'a pas changé (`:517`).
- `currentUser` / `isAdministrator` non remis à zéro sur changement de serveur/compte si `refreshCurrentUser` échoue (UI seulement, le serveur fait foi).
- `UpstreamHandler` ignore l'erreur d'envoi loopback (`CinemaxStreamProxy.swift:925`) : il peut continuer à tirer tout le fichier vers une connexion morte. *À vérifier sur appareil.*
- `SyncPlayController` : commandes sortantes en `Task { try? … }` — une pause qui échoue ne laisse aucune trace, et pause→seek→unpause peuvent partir dans le désordre (`:276-350`).

---

## 2. Sécurité

Aucun constat Critique ni Haute. Contrôles sains : proxy loopback (bind, admission, traversal, DNS rebinding), confiance TLS par épingle, aucune requête authentifiée sur `URLSession.shared`, `LogScrubber` sur libVLC et diagnostics, deep links sans verbe « play », pas de `pull_request_target` ni d'injection de script dans les workflows.

| # | Sév. | Constat | Où | Correctif |
|---|---|---|---|---|
| S1 ✅ | Moyenne | **Les éléments Keychain « app-private » sont dans le groupe partagé.** `save/getData/delete` ne passent jamais `kSecAttrAccessGroup`, et le seul groupe déclaré est `$(AppIdentifierPrefix)com.cinemax.shared` — c'est donc le groupe par défaut. `access_token`, `servers` (jetons de tous les serveurs), `parental_lock`, `trusted_certificates`, `device_id` sont lisibles par le widget et le Top Shelf. Contredit CLAUDE.md. | `KeychainService.swift:423-462` ; `project.yml:76-77`, `:199-200` | Ajouter **en tête** de `keychain-access-groups` de l'app `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`, le passer explicitement, migrer une fois par `SecItemUpdate` sur `kSecAttrAccessGroup`. À valider sur appareil (attribut `agrp`). |
| S2 | Moyenne | Plafond parental serveur décalé d'une catégorie (12 → `PG-13`, 16 → `TV-MA`) ; `getItems`, `searchItems` et Siri ne refiltrent pas localement. Le test verrouille la valeur fausse. **Ouvert depuis l'audit de juillet (S1).** | `ContentRatingClassifier.swift:58-67` ; `+Library.swift:162-185`, `:343-354` | Code ≤ plafond + `applyRatingFilter` sur `getItems`/`searchItems` |
| S3 | Moyenne | Chemins adressés par id sans contrôle du plafond : Play entrant « Lire sur… », `PlayQueue` SyncPlay, raccourci enregistré, deep link. Un adulte non-admin ayant « Voir En direct » peut lancer un film 18+ sur l'Apple TV d'un enfant plafonné — **la lecture démarre seule**. **Ouvert depuis juillet (S7), élargi.** | `+Library.swift:250-283` ; `RemoteControlListener.swift:145-158` ; `MediaItemQuery.swift:41` | `ContentRatingClassifier.passes` sur l'item résolu avant toute lecture auto ; état « contenu restreint » |
| S4 | Moyenne | Biométrie du verrou parental : `evaluatedPolicyDomainState` jamais comparé. Le code de l'appareil — que la RULE suppose connu de l'enfant — suffit pour **ajouter un visage** (apparence alternative) puis déverrouiller. | `ParentalLockController.swift:133-155` | Mémoriser `evaluatedPolicyDomainState` à l'activation ; s'il change, exiger le PIN |
| S5 ✅ | Moyenne | Top Shelf met `ApiKey` dans les URL d'image, alors que les endpoints d'image Jellyfin sont anonymes (l'app elle-même charge ses posters sans auth). Le jeton part dans le cache de PineBoard et les logs du reverse proxy. La prémisse de la RULE est fausse. | `TopShelf/.../ContentProvider.swift:257-266` | Retirer le paramètre, valider sur 10.9 et 12.0, corriger la RULE |
| S6 | Basse | Vignettes de chapitres et tuiles trickplay : `ApiKey` dans l'URL **en plus** de l'en-tête. | `VLCStreamPresenter.swift:2648` ; `TrickplayController.swift:161` | Retirer `authedURL` |
| S7 | Basse | Socket temps réel : jeton dans l'URL avec un commentaire faux (« a socket has no header ») ; session `.default` (cookies et cache disque). | `+RemoteControl.swift:174-180` ; `JellyfinSocket.swift:73-108` | `URLRequest` + en-tête `Authorization` (garder `ApiKey` en repli), session éphémère |
| S8 | Basse | `ExtensionSessionBridge.publish` mémorise avant d'écrire et ignore l'`OSStatus` : un effacement raté au logout laisse l'ancien jeton au widget. | `ExtensionSessionBridge.swift:97-114` | Mémoriser seulement en cas de succès |
| S9 | Basse | Back-off du PIN basé sur l'horloge murale : avancer la date ferme la fenêtre. | `ParentalLock.swift:173-189` | Compteur monotone ou refus si l'horloge recule ; PIN 6 chiffres |
| S10 | Basse | CI : pas de bloc `permissions:` dans `ci.yml`, actions épinglées par tag et non par SHA (dont `claude-code-action` qui reçoit un jeton OAuth), zip xcodegen téléchargé sans checksum dans un workflow qui a `contents: write`. | `ci.yml` ; `regen-project.yml:26-59` | `permissions: contents: read`, SHA, `shasum -c` |
| S11 | Info | `isValidItemId` accepte les chiffres hex pleine chasse ; `DisplayMessage` entrants affichés sans nom d'émetteur (hameçonnage possible par un utilisateur ayant le contrôle à distance) ; aucune gestion des redirections (URLSession recopie `Authorization` vers un autre hôte) ; `LogScrubber` ne masque ni `"AccessToken":"…"` ni `ApiKey%3D` ; `AdminLogsScreen` en `.textSelection(.enabled)`. | divers | voir rapport sécurité détaillé |

**Anciens constats sécurité (2026-07-06)** : S1, S2 (delete-then-add), S5 (device_id), S7 toujours ouverts ; S3, S4, S6 corrigés.

---

## 3. Performance

| # | Impact | Constat | Où | Correctif |
|---|---|---|---|---|
| P1 ✅ | Haute | La fiche attend `/Items/{id}/Similar` (requête coûteuse, sous la ligne de flottaison) avant de peindre ; un échec remplace toute la fiche par l'écran d'erreur. Idem pour une série (`:545`). | `MediaDetailViewModel.swift:166-172` | Tâche annexe silencieuse (`try?`), discipline `loadRemoteTargets` |
| P2 ✅ | Haute | Recherche : `LazyVGrid` dans `LazyVStack` (forme proscrite par la RULE) ; sur tvOS le tout est ré-enveloppé dans un second `ScrollView` à hauteur non bornée → **toutes** les cellules matérialisées (~150 cartes + requêtes Nuke d'un coup). | `SearchScreen.swift:70-77`, `:731-753` | `VStack` simple ; ne pas doubler le `ScrollView` sur tvOS |
| P3 | Moyenne | Chaque carte construit un `MediaDetailScreen` + `MediaDetailViewModel` inutilisés à chaque évaluation de son body (destination de `NavigationLink` non différée). | `LibraryPosterCard.swift:134` et ~10 autres sites | Wrapper `Deferred { … }` ou VM paresseux — *coût à mesurer* |
| P4 | Moyenne | Le tier-2 d'Accueil ignore les interrupteurs de rails (écart avec la RULE) et écrit sans garde d'égalité → 3–5 requêtes par fin de lecture, invalidation des cartes (focus tvOS). | `HomeViewModel.swift:504-767` | Gater sur `HomeRailPreferences`, `if new != old` |
| P5 | Moyenne | `refreshCurrentUser()` réécrit `currentUser`/`isAdministrator` sans garde à chaque retour au premier plan → invalide chaque carte de bibliothèque iOS. | `AppNavigation.swift:181-182` | Gardes d'égalité |
| P6 | Moyenne | Accueil phase 1 : « Ajouts récents » enchaîne deux requêtes en série sur le chemin du premier affichage (idem widget). | `HomeViewModel.swift:226-234` | Deux `async let` |
| P7 | Moyenne | `ThemeManager` : `accent*` alloue un `Color(uiColor:)` à chaque lecture (339 sites) ; avec l'accent arc-en-ciel, toute l'app se reconstruit à 10 Hz. **Ouvert depuis août (F-2/F-3).** | `ThemeManager.swift:127-165` | Mémoïser ; compteur séparé pour `colorScheme` — *Time Profiler d'abord* |
| P8 | Moyenne | `getItems` demande toujours `overview,genres,childCount` et n'a aucun cache TTL. **Ouvert (F-9/F-16).** | `+Library.swift:179` | `fields:` maigre par défaut ; TTL 30–60 s |
| P9 | Moyenne | Widget : posters téléchargés un par un (7 × 10 s de timeout max), réseau aussi en aperçu de galerie. **Ouvert (F-7).** | `CinemaxWidget.swift:152-191` | `withTaskGroup` borné à 4, placeholder si `isPreview` |
| P10 | Moyenne | Bibliothèque : `itemsByGenre[genre]` écrit 8 fois ; chaque écriture ré-évalue toutes les rangées (non `Equatable`). **Ouvert (F-20/F-22).** | `MediaLibraryViewModel.swift:355` | Écriture unique par lot ; `.equatable()` |
| P11 | Moyenne-Basse | Vignettes de chapitres VLC : ~40 GET simultanés juste après l'ouverture (le chemin natif découpe par 6) ; largeurs 320 vs 480 → pas de partage de cache. | `VLCStreamPresenter.swift:2504-2520` | Découper par 6, aligner les largeurs |
| P12 | Moyenne-Basse | `eventsTask` capture `self` fortement pour toute la boucle, aucun `deinit` : une fermeture atypique fait fuir le lecteur entier (timer 1 s compris). **Ouvert (F-29).** | `VLCStreamPresenter.swift:868-870` | `self` faible par itération + `deinit` de secours |
| P13 | Hypothèse | Journal libVLC consommé au niveau `.debug` : chaque trame h2/segment HLS devient une `String` + un élément d'`AsyncStream`. | `VLCEngineLog.swift:42-63` | Mesurer ; filtrer côté C ou `.debug` limité aux 10 s après ouverture |
| P14 | Hypothèse | `ImagePrefetcher` en `.memoryCache` décode ~240 images au lancement (~150 Mo face à un `costLimit` de 256 Mo). | `PosterPrefetcher.swift:18` | `.diskCache` pour le hors-écran |

Basses (détail dans les rapports) : sonde de transport lancée deux fois à froid et à chaque `.inactive→.active` ; Now Playing republié chaque seconde (~7 000 XPC par film) ; `SleepTimerController` avec sa propre boucle (écart RULE) ; `NetworkMonitor.isOnline` sans garde ; backdrops 2–5 du carrousel iOS non préchargés ; un `@AppStorage` par carte tvOS ; `validateSession` jette le `UserDto` puis le redemande ; ~7 lectures Keychain synchrones avant le premier rendu ; anciens `JellyfinClient` jamais invalidés (fuite d'`URLSession` par reconnexion) ; `ServerTrustDelegate` lit le Keychain même pour un certificat déjà accepté par le système.

---

## 4. Qualité, architecture, concurrence

**Métriques** : 13 fichiers > 800 lignes · 16 `@unchecked Sendable` · 16 `nonisolated(unsafe)` · 11 `MainActor.assumeIsolated` · `@preconcurrency import JellyfinAPI` dans 66 fichiers (contre 35 imports simples) · 261 `Task {` · 206 `try?` · 8 `Notification.Name` · 24 % de commentaires (46 % dans `AppNavigation.swift`).

| # | Sév. | Constat | Correctif |
|---|---|---|---|
| Q1 | Haute | **Écriture Keychain non atomique** : `save` = `delete` puis `SecItemAdd` ; un échec perd le jeton, le registre ou le verrou parental (qui est alors lu « pas de verrou », donc ouvert). Le commentaire `:118` dit « atomic », c'est faux. `saveSharedSession` ignore l'`OSStatus`, `saveActiveServerId`/`saveTrustedCertificates` avalent l'erreur. `getServers()` renvoie `[]` sur échec de décodage sans log, et la migration écrase alors tout le registre avec un seul serveur. | `SecItemUpdate` + repli `SecItemAdd` ; log `.fault` ; copie de sauvegarde du blob illisible |
| Q2 | Haute | **`VLCStreamViewController` est un objet-dieu** : 4 775 lignes, 170 propriétés stockées, 58 `#if os`, 4 mécanismes d'ordonnancement (Timer, 13 `DispatchWorkItem`, `Task.sleep`, `SeekMachine`). La machine de retry (`handlePlaybackError`, 108 lignes) est intestable sans libVLC — c'est pourtant la zone à régressions (B2, B5, B9). | Poursuivre #193 sur le modèle de `SeekMachine` : `PlaybackRetryPolicy` pur d'abord, puis `PlaybackRecoveryCoordinator`, `VLCSyncPlayBinding`, `VLCEpisodeNavigator`, `ChapterStripController`, vues de transport iOS/tvOS |
| Q3 | Moyenne | `JellyfinAPIClient` : 7 champs `nonisolated(unsafe)` mis à jour par morceaux, chacun sous sa propre prise de verrou ; `connectToServer` écrit après un `await` et peut écraser un `reconnect`. | `Mutex<ClientState>` remplacé en une opération |
| Q4 | Moyenne | Logique dupliquée entre les deux présentateurs (`releaseServerSession`, recherche du VC le plus haut codée 4 fois différemment, signal d'arrière-plan différent, mapping d'erreurs d'un seul côté). | Remonter dans `PlaybackReporter` / `UIApplication.topMostViewController()` |
| Q5 | Moyenne | Découpage en slices non respecté : `NativeVideoPresenter`, `MenuConfigStore` et 13 view-models Admin prennent `any APIClientProtocol`. | Restreindre à la slice utilisée |
| Q6 | Moyenne | `@preconcurrency import JellyfinAPI` incohérent : il éteint les diagnostics `Sendable` sur les DTO, donc les RULES « ne jamais transférer un `BaseItemDto` » ne tiennent que par convention. | Retirer fichier par fichier là où ça compile |
| Q7 | Moyenne | Dates suivant la locale de l'appareil, pas la langue de l'app (5 écrans admin + fiche acteur, épisodes, appareils) ; `String(format: "%.1f")` → « 7.5 » en français. | `loc.locale` injecté à la racine ; `Date.RelativeFormatStyle` (supprime 5 `nonisolated(unsafe)`) |
| Q8 | Basse | `AppState` (~800 lignes) vit dans `AppNavigation.swift` et porte un `didSet` sur `serverURL`, contraire à la RULE `@Observable`. | Extraire `AppState.swift` + `+Servers` + `+Session` ; mutateur `setServerURL` |
| Q9 | Basse | Table `ContentRating` copiée 3 fois (app, widget, Top Shelf) — identique aujourd'hui, intestable côté extensions. | Partager la source, comme `ResumeControl.swift` |
| Q10 | Basse | Logs `DIAG (recette …)` restés en `.notice` en production ; préfixes de log mi-anglais mi-français ; références VLCKit obsolètes dans des commentaires ; `viewWithTag(99)` fragile ; `waitUntilReady` qui avale l'annulation. | Nettoyage |

---

## 5. UX/UI, accessibilité, localisation

**Conformité design system** : 0 violation mécanique (polices, couleurs, toggles, tint, glass toolbar). **Localisation** : 1005/1005, 1 seule chaîne en dur. Les problèmes sont d'usage.

### Haute
- **U1 ✅ Serveur injoignable = « Votre bibliothèque est vide »** : `HomeViewModel.errorMessage` n'est jamais assigné, chaque fetch avale son erreur. Hors ligne, l'app dit que le contenu a disparu et invite à « ajouter des films ». → `ErrorStateView(illustration: .offline)` + Réessayer quand toutes les sources échouent ; idéalement un bandeau hors ligne global.
- **U2 ✅ Connexion sans AutoFill ni touche Retour** : `GlassTextField` n'expose ni `textContentType`, ni `submitLabel`, ni `onSubmit` (`LoginScreen`, `ServerSetupScreen`). Pas d'iCloud Keychain, pas de « se connecter avec l'iPhone » sur tvOS. Le formulaire secondaire (`UserSwitchSheet`) le fait, pas l'écran principal.
- **U3 Toasts jamais annoncés à VoiceOver** (`ToastOverlay.swift`) : aucun retour pour « Ajouté aux favoris », « Marqué comme vu », ni pour les erreurs. → `AccessibilityNotification.Announcement`.
- **U4 Contraste des CTA accent** : blanc sur `accentContainer` à 2,62:1 (jaune), 2,77:1 (cyan), 3,36:1 (orange) — sous le seuil « grand texte » pour les deux premiers, sur « Lecture » et « Connexion ». Seul indigo passe AA.
- **U5 Sélecteur d'accent inutilisable avec VoiceOver** : pastilles de 28 pt sans label ni trait (« bouton » ×9), `AccentOption` sans nom localisé.
- **U6 HUD du lecteur masqué toutes les 4 s même sous VoiceOver** ; pas de `accessibilityPerformMagicTap` (lecture/pause), `accessibilityPerformEscape` (fermer) ni `accessibilityViewIsModal`.

### Moyenne
- Badge « vu » quasi invisible en mode clair (coche blanche sur disque `F7F7F8`) ; sous-titres de cartes à 2,0:1 en clair (`CinemaColor.outline`).
- Cartes affiche sans état vu / en cours pour VoiceOver ; labels Reprendre/À suivre sans la série ou sans S×E×.
- Chaîne anglaise en dur lue par VoiceOver : « percent » (`MediaDetailScreen.swift:710`).
- Pluriels faux sans `.stringsdict` : « 1 films », « 1 titres », « et 1 autres », « %dm restantes » (en français : « min »), et 0 doit être au singulier.
- `NSFaceIDUsageDescription` ✅ déclaré dans `project.yml` mais absent des deux `InfoPlist.strings` (la RULE Localisation l'exige).
- Textes tactiles affichés sur tvOS (« tirez pour actualiser », « Touchez le cœur ») ; indice « Menu » alors que la télécommande actuelle porte « Retour ».
- `ProfileScreen` tvOS hors chrome standard des covers, avec `.scrollClipDisabled()` interdit par la RULE.
- Choix de langue du profil : ~190 cultures dans un `confirmationDialog`, sans marque de l'option courante.
- Menu tvOS dans le lobby « Regarder ensemble » quitte la séance **sans confirmation** (incohérent avec le lecteur).
- « Réinitialiser le menu » sans confirmation.
- Favoris en impasse : seul accès par « Tout voir » de la rangée d'Accueil — rangée masquée ou menu sans Accueil = écran inaccessible.
- Carrousel iOS : rotation de 8 s même sous VoiceOver (WCAG 2.2.2) ; balayage vertical à 3 doigts détourné.
- Barre A–Z masquée à VoiceOver sans alternative.
- Dynamic Type : 58 polices dynamiques contre ~510 fixes ; lignes de réglages, états vides et toasts en taille fixe.
- Cibles tactiles < 44 pt (fermeture de toast ~25 pt, X des sheets ~37 pt, FR/EN 40×30, grappe haute du lecteur ~31 pt).
- État « sélectionné » exposé à 2 endroits seulement ; aucun support Reduce Transparency / Increase Contrast.

### Recommandations UX
- Persister tri et filtre par bibliothèque.
- « Annuler » dans les toasts des actions réversibles.
- « Tout voir » sur Ajouts récents, Collections et rangées de genre.
- Suppression unitaire dans l'historique de recherche ; portée « Épisodes ».
- Bandeau hors ligne global affichant le dernier contenu connu.
- Raccourcis clavier iPad hors lecteur (⌘F, ⌘1…5).
- Icône étoile devant la note des cartes.

---

## 6. Code mort

Le code Swift réellement mort est **marginal (~40 lignes sûres)**. Aucun fichier, type, clé de localisation, asset, `SettingsKey` ou `Notification.Name` inutilisé.

**Sûr à supprimer** : `ExtensionSessionBridge.resetPublishMemoForTesting()` et `ParentalLockController.openWhenNotEnabled()` ✅ (0 appel) ; `JellyfinError.invalidURL` (jamais construit) ; `parentBackdropItemId` du Top Shelf (décodé, jamais lu) ; `currentPlayMethod` du présentateur natif et `hostingVC` du VLC (écrits, jamais lus) ; 5 `@Environment(ThemeManager.self)` et 1 `dismiss` non lus ; paramètres jamais lus (`isFirst:`, `player:`, `id:`) ; branches `#else` macOS inatteignables.

**À décider** : `PlayerChapterSelection` (testé, jamais branché) — à brancher (trait `.selected` du chapitre) ou supprimer ; `MediaSourceQuality.bitrateLabel` (tests seulement) ; `purgeLegacyDownloads()` (« garder jusqu'après 1.0.5 », on est en 2.1.1) ; paramètre `userId:` jamais lu dans `reportPlayback*` ; le stub de test SwiftPM `#expect(true)`.

**Docs** : ~5 800 lignes archivables sans risque (`docs/superpowers/` — toutes les features livrées —, le plan de recette de la PR #109, `docs/v2-todo.md` dont le seul item est livré) ; `docs/architecture/*.md` sont des copies **périmées** de CLAUDE.md (« Settings → Interface → Debug », `URLSession.shared` pour l'artwork).

---

## 7. Tests, CI, build, dépendances

Sain : `project.pbxproj` synchronisé avec le disque, aucun secret committé, fixtures anonymisées, `LicensesView` à jour, `dependency-audit.py check` OK.

| # | Sév. | Constat | Correctif |
|---|---|---|---|
| T1 | Haute | **Les profils d'appareil de lecture n'ont aucun test et ne peuvent pas en avoir** (`fileprivate`) : « jamais `mpeg4` », « `ts` jamais `mp4` », « pas de `mp1/mp2/mp3` en transcodage VLC », `minSegments: 1` ne sont protégés que par la prose de CLAUDE.md. `isSeekHeavyContainer` non testé non plus. | Passer en `internal` + `DeviceProfileTests` |
| T2 | Haute | **Course sur `UserDefaults.standard` entre suites** : `HomeRailGatingTests` (non `.serialized`) écrit les clés `home.show*` que `HomeViewModel.load` lit, pendant que `HomePlaylistsRailTests`/`HomeViewModelTests` tournent en parallèle. Même schéma dans `MenuConfigStoreTests`, `SearchHistoryTests`. Source de tests intermittents. | Injecter un `UserDefaults(suiteName:)` dans `HomeRailPreferences`, `MenuConfigStore`, `SearchHistoryStore` |
| T3 | Moyenne | 61 `sleep` dans les tests (ordres garantis par 10 ms, TTL de 50 ms, « aucun appel après 30 ms »). | Horloge injectée, barrières `CheckedContinuation` (modèle `PaginatedLoaderInterlockTests`) |
| T4 | Moyenne | Un test local efface **la vraie session partagée du Keychain** (`ExtensionSessionContractTests.swift:141-157`) : le widget du développeur perd sa session. | Compte de test dédié ou sauvegarde/restauration |
| T5 | Moyenne | Contrôleurs porteurs de RULES sans tests : `AppUpdateChecker`, `NowPlayingInfoController` (génération), `SleepTimerController`, `RemoteControlListener`, `AdminUserDetailViewModel` (read-modify-write de la politique). | Par priorité, en commençant par `AppUpdateChecker` |
| T6 | Moyenne | Xcode non épinglé en CI (juste `xcodebuild -version`) alors que des cassures entre versions sont documentées ; `project.yml` indique `xcodeVersion: "26.5"` pour une toolchain locale en 27.0. | `xcode-select` / `setup-xcode` à version fixe |
| T7 | Moyenne | Une modif de Markdown lance ~11 min de runner macOS (pas de `paths-ignore`) — y compris chaque PR qui touche CLAUDE.md. | `paths-ignore: ['**/*.md', 'docs/**']` + job « skip » si check requis |
| T8 ✅ | Moyenne | **SwiftLint inerte** : `continue-on-error: true`, version brew non fixée, `unused_import` inactive en `lint`, sur un runner macOS. | Supprimer, ou `ubuntu-latest` + image épinglée + baseline, sans `continue-on-error` |
| T9 | Moyenne | Seule la config Debug est compilée en CI ; les chemins `#if DEBUG` et l'optimisation Release ne sont vus qu'à l'archivage. | `xcodebuild build -configuration Release` (non signé) |
| T10 | Moyenne | `claude-code-review.yml` tourne sur les PR Dependabot (sans secrets → check rouge) et sans groupe de concurrence (chaque push = une revue payante). | `if: github.actor != 'dependabot[bot]'` + `concurrency` |
| T11 | Moyenne | Licences Apache-2.0 non créditées (`swift-nio`, `swift-nio-transport-services`, `swift-atomics`, `swift-collections`, `swift-system`) ; `URLQueryEncoder` crédité mais plus résolu. | Mettre à jour `LicensesView` ; avertissements → erreurs dans `dependency-audit.py` |
| T12 | Basse | Cache CI fragile (glob sur le hash DerivedData, clé sans version d'Xcode) ; hook pre-commit qui n'épingle pas xcodegen ; avertissements non bloquants ; `MARKETING_VERSION` = `CURRENT_PROJECT_VERSION` = « 2.1.1 » ; parité des chaînes et `.xcprivacy` non vérifiées en CI ; déclencheur mort dans `regen-project.yml` ; pas de README ni de LICENSE ; `app_logo.png` identique à l'icône 1024 (1 Mo en double) ; commentaires de `project.yml` périmés. | voir rapport CI détaillé |

---

## 8. Documentation — CLAUDE.md

**Constat** : 422 783 octets sur 680 lignes (la plus longue : 11 817 caractères), ~100 000 tokens chargés **à chaque session et par chaque sous-agent**. 292 RULES, 63 « mesuré le … », 65 dates. Répartition : Video Playback 125 Ko, Settings 48 Ko, Media Library 24 Ko, Server Setup 24 Ko, Home 22 Ko… Le hook de fraîcheur sur `gh pr create` ne fait qu'**ajouter**.

**Conséquences mesurables** :
- coût et latence de chaque session d'agent ;
- **contradictions internes déjà présentes** : la RULE verrou parental affirme que widget et Top Shelf n'appliquent aucun filtre d'âge (corrigé par #230, documenté ailleurs dans le même fichier) ; la section App Intents range « Control Center controls, Lock Screen & StandBy » hors périmètre alors qu'ils existent ; la liste des sous-agents omet `jellyfin-api-reviewer` ; la RULE Top Shelf `ApiKey` repose sur une prémisse fausse (S5) ; la RULE Keychain « app-private » est contredite par le code (S1) ;
- double source de vérité avec les commentaires du code (24 % du code source).

**Restructuration proposée** :
1. **CLAUDE.md racine ≤ 30–40 Ko** : vue d'ensemble, règles transverses (Swift 6, `@Observable` sans `didSet`, navigation lazy, URL avec chemin de base, xcodegen, tests), section Build, et un **index d'une ligne par RULE** pointant vers le fichier détaillé.
2. **CLAUDE.md imbriqués** (chargés seulement quand l'agent travaille dans le dossier) : `Shared/Screens/VideoPlayer/`, `Shared/Screens/Settings/`, `Shared/Screens/Admin/`, `Shared/Navigation/`, `Packages/CinemaxKit/`, `Widgets/`, `TopShelf/`, `Shared/Intents/`.
3. **Récits historiques → ADR** (`docs/adr/NNNN-*.md`) : mesures sur appareil, campagnes abandonnées, contrôles appariés. La RULE garde l'invariant et un lien.
4. **Hook de fraîcheur** réécrit pour viser le CLAUDE.md du dossier modifié, avec une taille maximale.
5. Supprimer ou fusionner `docs/architecture/*.md` (périmés).

---

## 9. Suivi des audits précédents

| Audit | Toujours ouvert | Corrigé |
|---|---|---|
| 2026-07-06 (sécurité) | S1 plafond décalé (→ S2), S2 delete-then-add (→ Q1), S5 migration `device_id`, S7 chemins par id (→ S3) | S3 jeton en clair UserDefaults, S4 `read()` mort, S6 avertissement HTTP |
| 2026-08-05 (perf) | F-2/F-3 ThemeManager, F-7 widget séquentiel, F-9/F-16 `getItems`, F-10, F-11/F-12 sonde, F-14, F-20/F-22, F-21, F-25, F-27, F-29, F-30, F-32–F-36, F-38/F-39, F-43, F-45 | F-4, F-5 (en partie), F-6, F-15, F-18, F-26, F-28, F-46 à F-56 |
| 2026-09-10 (plateforme) | — (B4 est un cas voisin non couvert de A1) | A1–A3, A6, A7, P1–P13, R1 |

---

## 10. Plan d'action proposé

**Lot 1 — correctifs rapides à fort impact (≈ 2 jours)**
B1 point de reprise · B3 cible « Lire sur… » après login · B2/B9 spinner infini · B6 « Marquer comme vu » sur la fiche · B7 héros tvOS · P1 `/Similar` non bloquant · P4/P5 gardes d'égalité et gating tier-2 · U1 état « serveur injoignable » · U2 AutoFill · `NSFaceIDUsageDescription` localisé · « percent » en dur.

**Lot 2 — sécurité et intégrité des données (≈ 3 jours)**
S1 groupe Keychain privé + migration · Q1 écritures Keychain atomiques et `getServers` tolérant · S2 table du plafond + filtre local · S3 contrôle du plafond avant lecture auto · S4 état biométrique · S5/S6/S7 jeton hors des URL · S10 durcissement CI.

**Lot 3 — robustesse (≈ 1 semaine)**
B4/B5/B8/B10–B13 · APICache par génération · `PlaybackReporter` sériel · T1 tests des profils d'appareil · T2 `UserDefaults` injectés · T3/T4.

**Lot 4 — accessibilité (≈ 1 semaine)**
Annonces VoiceOver des toasts · contraste des accents jaune/cyan/orange · HUD sous VoiceOver + magic tap / escape · sélecteur d'accent · pluriels `.stringsdict` · `loc.locale` à la racine · Dynamic Type sur réglages/états vides/toasts · cibles 44 pt · `.isSelected` / `.isHeader`.

**Lot 5 — structure (continu)**
Découpage de CLAUDE.md · poursuite de #193 (`PlaybackRetryPolicy` en premier) · extraction d'`AppState` · slices d'API · `@preconcurrency` · perf P2, P3, P7, P8, P10 (Instruments d'abord pour P7, P13, P14) · CI (Xcode épinglé, `paths-ignore`, Release, SwiftLint réel ou supprimé) · licences · archivage de `docs/`.

---

## 11. Avancement (PR #255)

**Lot 1 — fait.** B1, B2/B9, B3, B6, B7, P1, P4/P5, U1, U2, `NSFaceIDUsageDescription`, « percent ». En plus : `MediaDetailViewModel.load()` ne remettait jamais `errorMessage` à zéro (« Réessayer » ne pouvait pas effacer l'écran d'erreur). Relecture adversariale intégrée : l'idempotence du stop ne verrouille qu'un `.sessionEnded` ; la reprise sur erreur de `handleFailedEpisodeNav` / `reResolveAndResume` est limitée au cas d'un retry abandonné ; les tests tier-2 n'utilisent plus `UserDefaults.standard` ; la position en attente du lecteur natif couvre aussi un changement de piste ; `currentUser` est comparé sur les champs affichés.

**Lot 2 — fait, sauf un point.**
- S1 + Q1 : groupe Keychain privé en tête des entitlements des deux apps, migration unique par `SecItemUpdate` ; écritures « mise à jour puis ajout » ; `getServers` journalise et met de côté un registre illisible. **À valider sur appareil signé** (attribut `agrp`).
- S2 : le plafond est envoyé comme l'âge lui-même (`"12"`), lu tel quel par tous les serveurs supportés (vérifié dans les sources 10.9 → 12.0) ; la recherche filtre aussi localement.
- S3 : fiche atteinte par identifiant → état « contenu restreint » et lecture automatique refusée. Trou restant : une carte des rails Reprendre / À suivre lance la lecture sans passer par la fiche.
- S4 : Face ID armé sur le jeu biométrique enrôlé ; un visage ajouté impose le code.
- S5/S6 : plus de jeton dans les URL d'images du Top Shelf, des chapitres et du trickplay.
- S7 : session du socket éphémère. **Reporté au lot 3** : l'authentification du socket par en-tête, car l'URL tokenisée sert aussi de clé d'identité au `JellyfinSocketHub` (il faut changer `RealtimeSocketAPI` pour rendre une requête et comparer le jeton).
- S10 : `permissions: contents: read` sur `ci.yml`, actions épinglées par SHA, somme SHA-256 de xcodegen vérifiée, revue Claude sans Dependabot et avec groupe de concurrence.

**Lot 3 — fait, sauf deux points.**
- B10 + B4 : la cible d'un changement de serveur est validée hors du client partagé (`ServerSessionValidator`, `GET /Users/Me` sur sa propre session). Le client n'est repointé qu'au commit, un refus n'a plus rien à défaire, et la version apprise du serveur courant n'est plus effacée. `rollBackFailedSwitch` supprimé.
- B5 : la reprise VLC après un réveil re-négocie avec la même version (`mediaSourceId`) et réapplique les pistes audio / sous-titres en cours.
- B8 : les deux rafraîchissements d'épisodes de la fiche n'écrivent que dans la saison encore sélectionnée.
- B11 : le lecteur natif a une génération de navigation. En cas d'échec, la session de l'épisode courant est rouverte (appui manuel) ou l'alerte d'erreur s'affiche (enchaînement automatique).
- B12 : `PlaybackReporter` sériel (start → progress → stop dans l'ordre), avec `drain()` pour les tests.
- B13 : génération de chargement sur l'Accueil ; rails vidés quand le serveur ou le compte change.
- APICache : une écriture partie avant une invalidation qui couvre sa clé est refusée ; une invalidation détache les requêtes en vol correspondantes.
- T1 : tests des profils d'appareil, placés dans `AuthedURLTests.swift` (un nouveau fichier imposerait un `xcodegen`).
- T2 : `UserDefaults` injectés dans `HomeViewModel`, `HomeRailPreferences` et `HomeGenrePreferences` ; les suites de l'Accueil utilisent chacune leur store. `MenuConfigStore` n'a pas été touché : sa suite est sérialisée et c'est la seule à lire ses clés.
- T3 : partiel. Les tests du rapporteur et le nouveau test d'APICache ne dorment plus. Le reste des `sleep` passe au lot 5.
- T4 : la session partagée réelle est restaurée après le test.
- **Reportés** :
  - S7 (authentification du socket par en-tête) : il faut changer `RealtimeSocketAPI` et la clé d'identité du hub, trop risqué sans compilateur local. Passe au lot 5.
  - Les autres `sleep` de T3.
- **Relecture adversariale du lot 3, intégrée** (`8b772d3`) :
  - le garde anti-écriture périmée d'APICache pouvait être contourné (un tampon par clé, écrasé par le rafraîchissement lancé par la même mutation) ; il prend désormais un tampon par requête ;
  - les enfants de phase 2 d'un chargement de l'Accueil remplacé écrivaient des rangées en échec par-dessus le nouvel écran ;
  - un stop de lecture attendait derrière un progress bloqué ; il l'annule ;
  - la validation autonome acceptait toute réponse 2xx comme session (page SSO, portail captif) ; elle exige un utilisateur JSON.

**Lot 4 — fait, sauf un point.**
- U3 : les toasts sont annoncés à VoiceOver (depuis `ToastCenter`, donc aussi sous une feuille) et restent au moins 6 s sous VoiceOver ; texte en Dynamic Type ; bouton de fermeture de 44 pt.
- U4 : contraste des boutons d'accent. Un libellé sombre remplace le blanc sur orange, jaune et cyan (5,2 à 6,6:1, contre 2,6 à 3,4:1). Règle numérique pure, qui vaut aussi pour l'accent arc-en-ciel. Nouveau jeton `onAccentContainer` pour tout ce qui est posé sur `accentContainer`.
- U5 : sélecteur d'accent.
  - Pastilles nommées (`accent.name.*`), trait « sélectionné », zones de 44 pt de haut.
  - Rangées tvOS couleur et langue : un seul élément ; la couleur est réglable par balayage.
  - Boutons FR/EN : lus « Français » / « English », 44 pt.
- U6 : sous VoiceOver, le HUD VLC ne se masque plus, le geste magique met en lecture ou en pause, le geste d'échappement ferme le lecteur, et la vue est modale. La barre haute du HUD iOS passe à 44 pt de haut.
- Pluriels : une règle unique (0 et 1 au singulier en français, 1 seulement en anglais) et des clés `.one`. Corrige « 1 films », « 1 titres », « et 1 autres » et « %dm restantes » (devenu « %d min restante(s) »). Pas de `.stringsdict` : un nouveau fichier de ressources imposerait `xcodegen`.
- Q7 : `loc.locale` est injecté à la racine. Les dates (fiche acteur, épisodes, appareils, Prochainement, admin) et les notes (« 7,5 ») suivent la langue de l'app. Les cinq `RelativeDateTimeFormatter` en `nonisolated(unsafe)` sont remplacés par `Date.RelativeFormatStyle`.
- Dynamic Type sur les réglages iOS, les états vides et d'erreur, et les toasts. Traits « en-tête » sur les en-têtes de section, trait « sélectionné » sur les puces, le tri et les onglets de saison.
- Divers : le carrousel iOS ne tourne plus sous VoiceOver ; la coche « vu » est visible en mode clair.
- **Reporté au lot 5** : l'état vu / en cours des cartes pour VoiceOver. Il faut reprendre le libellé composé de chaque carte, surface par surface.
- **Relecture adversariale du lot 4, intégrée** (`df600c2`, `5683bd0`) :
  - `loc.decimal` n'acceptait qu'un `Double` alors que les notes sont des `Float` (erreur de compilation) ; il accepte tout `BinaryFloatingPoint` ;
  - fonds d'accent oubliés : puce de portée de la Recherche, chevron de la première pastille des réglages iOS, sous-titre et chevron de la pastille tvOS focalisée, initiales des avatars ;
  - le geste magique et le retour du HUD à l'activation de VoiceOver attendent qu'aucune couche (alerte, sélecteur, panneau d'options tvOS, carte de fin de série) ne tienne l'écran, et le geste magique attend un média ouvert ;
  - toast : annonce via `UIAccessibility.post`, action « Fermer » explicite et geste d'échappement sur l'élément combiné.
  - Non traité, antérieur au lot : la coche blanche des pastilles jaune et cyan en mode sombre (~1,6:1).
