# Jellyfin 12.0 — audit de compatibilité et plan de migration (Cinemax)

Date : 2026-09-08 (12.0 stable publiée le jour même, tag `v12.0`). Serveur actuel : NAS `jellyfin/jellyfin:10.11.11`, `EnableLegacyAuthorization=true`, plugin « Chapter Segments Provider 4.0 ». Objectif du lot : **Cinemax compatible 10.10.7 / 10.11.x ET 12.0**, sans toucher au Docker.

Sources : release notes `v12.0` (GitHub), billet jellyfin.org, PR #15559 / #16992 (auth), #17088 / #16999 (`GetItems`), #15516 (`/Items/{id}/Collections`), #17079 (WebSocket → session), source `v12.0` de `HlsSegmentController`, diff statique `jellyfin-sdk-swift` 0.6.0 → 3.1.0.

## 1. Verdict

Cinemax est **déjà presque compatible 12.0**. Le gros morceau (auth legacy) a été fait dans PR #133. Il reste **trois corrections client**, une **mise à jour du SDK Swift** à décider, et une recette en conditions réelles. Rien ne casse sur 10.x avec les corrections proposées : chaque changement est soit neutre, soit gaté par `ServerVersion`.

## 2. Audit — changements 12.0 × état de Cinemax

| Changement serveur 12.0 | État Cinemax | Action |
|---|---|---|
| Auth legacy désactivée par défaut (`api_key`, `X-Emby-Token`, `X-MediaBrowser-Token`, `X-Emby-Authorization`, schéma `Emby`) ; une migration la désactive aussi sur les installs existantes | **Fait** (PR #133) : 4 sites URL-only en `ApiKey`, en-tête `Authorization: MediaBrowser Token=` partout ailleurs (SDK + 6 sites main). `MediaBrowser` reste supporté (vérifié `AuthorizationContext.cs`). | Recette seulement (§5). |
| Préfixes `/emby/*`, `/mediabrowser/*` retirés | Non utilisés. | — |
| Routes retirées : `EasyPassword`, `CriticReviews`, `NetworkShares`, `MediaEncoder/Path`, `Recordings/Groups`, `GET /QuickConnect/Initiate` | Aucune utilisée ; QuickConnect passe par `Paths.initiateQuickConnect` = **POST** déjà. | — |
| Numéro de version `12.0.0` (plus de préfixe `10.`) | `ServerVersion` compare numériquement, parse 2–4 composants. Aucun `"10."` en dur. Tests ne couvrent que 10.x. | **A3** : ajouter cas `12.0.0` / `12.0` / `12.0.0-rc7` à `ServerVersionTests`. |
| `GetItems` : `recursive` appliqué dès qu'il y a des filtres **et** `includeItemTypes` ; asynchrone | Tous nos `getItems` filtrés passent déjà `isRecursive: true` (client + widget). Résultat attendu : identique. | Recette (grille filtrée, « Non vus », décennies, favoris widget). |
| `ItemByName` restreint, personnes dédupliquées | On n'appelle que `/Persons` (liste) et `getItems(personIds:)`. | Recette (recherche d'acteur, fiche personne). |
| `UserDto.HasPassword` obsolète ; `MediaSourceInfo.PlaybackPositionTicks` et `SessionInfoDto.NowPlayingQueueFullItems` **retirés** | Aucun des trois n'est lu. | — |
| Contrôleurs HLS **masqués** de l'OpenAPI (« peuvent être retirés à toute majeure sans préavis ») | On ne construit aucune URL HLS à la main (on suit `TranscodingUrl`). **MAIS** `DELETE /Videos/ActiveEncodings` (notre `stopEncoding`, appelé à chaque arrêt de lecture) vit dans `HlsSegmentController`, `IgnoreApi = true` en 12.0. Toujours servi (vérifié dans la source `v12.0`), mais **absent du SDK 3.x** et fragile à terme. | **A2** : requête construite à la main (même forme que `/Items/{id}/Collections`), tolérante à un 404 (le stop report doit rester l'appel qui compte). Documenter la fragilité dans CLAUDE.md. |
| `GET /Items/{id}/Collections` (« Included In ») **nouveau en 12.0** (PR #15516) | Déjà appelé… en **requête spéculative `try?` sur chaque fiche** — un 404 par ouverture de fiche sur 10.x, en violation de la RULE `ServerVersion` (« jamais une requête spéculative »). | **A1** : seuil `ServerVersion.collectionsReverseLookup = 12.0.0`, gate `serverSupports`, repli TMDb inchangé pour < 12 et version inconnue. Test. |
| WebSocket perdu ⇒ **session fermée** côté serveur (#17079) | `RemoteControlListener` ferme le socket en arrière-plan : sur 12, la session Cinemax disparaît donc des sélecteurs « Lire sur… » dès la mise en veille (déjà quasi le cas), et une appartenance SyncPlay **ne survit plus à un kill** — la carte « groupe orphelin » (`viewerIsParticipant`) devient rare mais le code reste juste. Capacités re-postées au retour au premier plan : déjà fait (`apply` sur `.active`). | Recette ; ajuster la note CLAUDE.md sur la carte orpheline (« vrai sur 10.x, rare sur 12 »). |
| Enums stricts : 12.0 ajoute `PersonKind.narrator`, `TranscodeReason.videoRotationNotSupported`, `ProfileConditionValue.videoRotation`, enums `ActivityLogSortBy` / `HlsAudioSeekStrategy` | Le SDK 0.6.0 génère des `enum: String, Codable` **sans repli** : une valeur inconnue fait échouer le décodage de tout le DTO. Seul `narrator` est un risque de réponse (livres audio : `people[].type`) ; `videoRotationNotSupported` n'est émis que si on déclare la condition. | Couvert par la mise à jour du SDK (§3). Sans elle : risque réel uniquement sur les bibliothèques de livres audio, hors périmètre de Cinemax. |
| Tri par nom via `SortName`/`CleanName` ; images plus jamais agrandies ; symlinks résolus à la lecture ; `.ogg` audio | Neutre côté client. Barre A–Z (`nameStartsWithOrGreater`) reste cohérente avec le tri serveur. Affiches basse résolution rendues à taille réelle dans une boîte `fill`. | Recette (ordre A–Z, affiches floues). |
| Versions multiples d'**épisodes** ; état « vu » partagé entre versions ; filtres BoxSet/Playlist par bibliothèque ; `Accept-Language` ; providers de recherche / similarité ; `dvh1` HLS ; SubtitleEdit | Pas cassant. Opportunités pour le lot « améliorations » (§6). | — |
| Prérequis serveur : venir de 10.10.7 / 10.11.x ; sauvegarde obligatoire (schéma réécrit, pas de retour arrière) ; plugins tiers à retirer avant ; noms d'utilisateur différant seulement par la casse ; scan complet requis après | NAS en 10.11.11 ✓. Plugin « Chapter Segments Provider 4.0 » à vérifier (.NET 10). Seerr consomme l'API Jellyfin — à vérifier avant la bascule (la migration force `EnableLegacyAuthorization=false`). | Lot B (§4). |

## 3. SDK Swift : 0.6.0 → 3.1.0

Le SDK a sauté trois majeures depuis notre pin : 1.0.0 (10.11.8, passage à openapi-generator), 2.0.0 (QuickConnect, ServerDiscovery, **WebSocket**, suppression des types partagés), **3.0.0 « Generate 12.0 »**, 3.1.0 (licence, tolérance aux échecs de poll QuickConnect). La branche 0.x est morte.

Delta mesuré statiquement (pas encore compilé) :

- **118 `Paths.*` utilisés : tous présents sauf `stopEncodingProcess`** (endpoint masqué, voir A2).
- **~12 signatures changées**, toutes mécaniques : corps renommés `PlaybackStartInfo`/`PlaybackProgressInfo` → `PlaybackStateInfo`, `ReadyRequestDto`/`BufferRequestDto` → `PlaybackQueueStateInfo`, `MovieInfo`/`SeriesInfo` → `MovieInfoRemoteSearchQuery`/`SeriesInfoRemoteSearchQuery` ; `applySearchCriteria` prend un `RemoteSearchResult` ; `deleteDevice(id: [String]?)` ; `downloadRemoteImage(itemID:type:imageURL:)` ; `addItemToPlaylist(playlistID:parameters:)` ; `markPlayedItem`, `getSimilarItems`, `getPlaylistItems` aplatis.
- `BaseItemDto.ImageBlurHashes` (type imbriqué) disparu — non lu.
- `JellyfinClient` devient `@unchecked Sendable`, l'init déprécié disparaît — nous utilisons déjà le nouveau.
- Prérequis : swift-tools 6.0, iOS/tvOS 16+ (nous : 26+), `Get` ≥ 2.1.6 (nous : 2.1.6 ✓). **Nouvelle dépendance `swift-nio-transport-services`** (pour le socket du SDK) — entre dans le binaire de l'app, pas dans les extensions (elles ne lient pas CinemaxKit).
- **Collisions de noms** : le SDK exporte désormais `JellyfinSocket`, `Session`, `Subscription`, `QuickConnect`. Les nôtres vivent dans CinemaxKit (priorité du module courant) et aucun fichier de `Shared/` qui les nomme n'importe `JellyfinAPI` → pas d'ambiguïté attendue. Seule une compilation le prouve.
- Enums 12.0 (`narrator`, etc.) décodables.

Recommandation : **faire la montée dans ce lot**, précédée d'un **probe de compilation jetable** (branche + `Package.swift` à `from: "3.1.0"` + build iOS et tvOS) pour mesurer le vrai nombre d'erreurs avant d'engager. Hors périmètre, délibérément : remplacer notre `JellyfinSocket`/`JellyfinSocketHub` ou notre poll QuickConnect par ceux du SDK — les nôtres portent des règles durement acquises (un seul socket par session, budget d'échecs de poll).

## 4. Plan d'actions

### Lot A — client, compatible 10 + 12 (une PR, ordre imposé)

| # | Action | Fichiers | Verrou |
|---|---|---|---|
| A0 | Probe SDK 3.1.0 : branche jetable, bump `Package.swift`, build iOS + tvOS, compter les erreurs. Décision go/no-go sur le chiffre. | `Packages/CinemaxKit/Package.swift` | — |
| A1 | Gater `/Items/{id}/Collections` sur `ServerVersion.collectionsReverseLookup = 12.0.0` ; supprimer le `try?` spéculatif ; repli TMDb inchangé. | `JellyfinAPIClient+Library.swift`, `ServerVersion.swift` | test : inconnu ⇒ repli, 10.11 ⇒ repli, 12.0 ⇒ direct |
| A2 | `stopEncoding` en requête construite à la main (`DELETE /Videos/ActiveEncodings?deviceId=&playSessionId=`), tolérante au 404 ; base path préservé (`setEndpointPath`). | `JellyfinAPIClient+Playback.swift` | test : URL + base path sous-chemin |
| A3 | Tests `ServerVersion` : `12.0.0`, `12.0`, `12.0.0-rc7`, `12.0.0 > 10.11.11`. | `CinemaxKitTests.swift` | tests |
| A4 | Montée SDK 3.1.0 (si A0 va) : renommages de corps, signatures aplaties, `Package.resolved` des deux workspaces, `xcodegen generate`. Vérifier que `deleteDevice` reçoit bien `[id]`. | CinemaxKit + `Admin/` + `+SyncPlay` + `+Playback` | suite complète verte, build tvOS |
| A5 | CLAUDE.md : section « Compatibilité serveur » (12.0 supporté, `ActiveEncodings` masqué, `collectionsReverseLookup`, note socket→session, SDK 3.1.0 remplace 0.6.0 dans « Dependencies ») ; mémoire projet mise à jour. | `CLAUDE.md` | — |

### Lot B — serveur NAS (plus tard, sur ton feu vert ; rien maintenant)

1. **Avant** : vérifier la compatibilité 12 de « Chapter Segments Provider » (repo stable) et de Seerr (auth moderne ? sinon il casse quand la migration force `EnableLegacyAuthorization=false`) ; vérifier qu'aucun couple d'utilisateurs ne diffère seulement par la casse.
2. `docker compose down` ; **sauvegarde complète** de `/volume1/docker/jellyfin-server/config` (pas de retour arrière possible) ; retirer le plugin.
3. `image: jellyfin/jellyfin:12.0` ; démarrer ; laisser la migration finir (option : `--mode MigrateSystem`).
4. **Scan complet obligatoire** (versions alternatives reconstruites, premier scan long).
5. Réinstaller le plugin depuis le dépôt stable ; recette Lot C.

### Lot C — recette 10.11 puis 12.0 (appareil réel, contrôle apparié)

Sur le NAS en 10.11.11 **avec `EnableLegacyAuthorization=false` posé à la main dans `system.xml`** (la condition exacte de 12.0, sans migrer), puis à nouveau après Lot B :

- Lecture VLC MKV 4K, AVI transcode forcé (`TranscodingUrl` + `ApiKey`), proxy loopback (`CINEMAX_FORCE_PROXY=1`), Top Shelf, widget, « Lire sur… » iPhone → Apple TV, socket temps réel, Watch Together à deux comptes, QuickConnect, Live Activity, chapitres/trickplay.
- Contrôle apparié : le build App Store actuel **doit** échouer sur les sites qui étaient en `api_key` avant PR #133.
- 12.0 seulement : grille filtrée / « Non vus » / décennies (résultat identique), ordre A–Z, fiche personne, affiches basse résolution, « Dans cette collection » via l'endpoint direct (log), arrêt de lecture (`ActiveEncodings` 200/204), session fermée en arrière-plan puis réapparition dans « Lire sur… » au retour.

## 5. Décisions à prendre

1. **SDK 3.1.0 dans ce lot ?** (recommandé : oui, sous réserve du chiffre du probe A0) — sinon A2 seul suffit à rester fonctionnel, au prix d'un SDK mort et d'enums non décodables.
2. **A1/A2/A3 d'abord, SDK ensuite** dans la même PR, ou deux PR ? (recommandé : deux — A1–A3 sont sûrs et testables sans le SDK.)
3. Recette Lot C sur 10.11 avec le flag legacy forcé à `false` **avant** de toucher au Docker ? (recommandé : oui, ça isole l'auth de la migration.)

## 6. Ensuite — ce que 12.0 rend possible (hors lot, à brainstormer)

- Ligne « Version » sur les **épisodes** (versions multiples d'épisodes ; `MediaSourceQuality` déjà total, `mediaSourceId` à faire voyager quand la cible est un épisode).
- `Accept-Language: fr` sur le client SDK pour des métadonnées localisées côté serveur.
- Filtres BoxSet/Playlist **par bibliothèque** (onglets Collections/Playlists en mode bibliothèque plus justes).
- Recherche / « Titres similaires » fournis par plugins (gratuit côté client, à recetter).
- `dvh1` HLS DoVi P5 sur le chemin natif ; sous-titres VobSub ; stratégie de seek audio HLS.
- Remplacer notre socket / QuickConnect par ceux du SDK — seulement si un besoin réel apparaît.

## 7. Résultat du probe A0 (2026-09-08, worktree `worktree-probe-sdk-3.1.0`)

**Go.** iOS et tvOS compilent, **645 tests / 80 suites passent** contre jellyfin-sdk-swift 3.1.0. Delta réel : **13 fichiers, ~15 corrections mécaniques** (diff conservé dans le worktree, non commité) :

- Corps renommés : `ReadyRequestDto`/`BufferRequestDto` → `PlaybackQueueStateInfo` ; `PlaybackStartInfo`/`PlaybackProgressInfo` → `PlaybackStateInfo` ; `MovieInfo`/`SeriesInfo` → `MetadataLookupInfo` ; `NameGuidPair` → `NameIDPair`.
- Signatures : `deleteDevice(id: [String])` ; `downloadRemoteImage(itemID:type:imageURL:)` ; `addItemToPlaylist(playlistID:parameters:)` ; `syncPlaySend<T: Decodable & Sendable>`.
- **Ordre alphabétique des inits mémoire** (nouveau générateur) : `ClientCapabilitiesDto`, `UpdateUserPassword`, et les deux `TranscodingProfile` (`protocol` passe en tête). Les autres (`DeviceProfile`, `CodecProfile`, `ProfileCondition`, `PlayRequestDto`, `CreatePlaylistDto`) étaient déjà dans l'ordre.
- `stopEncodingProcess` absent du SDK → `Request<Void>(path: "/Videos/ActiveEncodings", method: "DELETE", …)` construit à la main (`import Get` dans `+Playback.swift`) = l'action A2, faite par nécessité.
- Tests : `UserItemDataDto()` → `UserItemDataDto(key:)` (6 sites) — **`Key` est désormais requis au décodage**, comme `UserPolicy.AuthenticationProviderId`/`PasswordResetProviderId`. Jellyfin les émet toujours depuis 10.9 ; à confirmer en recette 10.11 (un `userData` sans `Key` ferait échouer le décodage de l'item entier).

Points à connaître pour A4 :
- Le SDK embarque un **artefact binaire** `openapi-generator` (releases GitHub de LePips, plugin de génération) : un cache SwiftPM corrompu fait échouer la résolution (`already exists in file system`) — purger `~/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_LePips_openapi_generator_*`. La CI doit pouvoir joindre ce téléchargement ; `-skipPackagePluginValidation` requis en ligne de commande.
- Nouvelles dépendances transitives : `swift-nio` 2.102, `swift-nio-transport-services` 1.28 (socket du SDK, que nous n'utilisons pas). Impact taille binaire non mesuré proprement (le DerivedData du probe contient XCTest).
- 4 warnings de dépréciation nouveaux, tous dans l'admin : `SystemInfo.operatingSystem` / `operatingSystemDisplayName` / `systemArchitecture` (`AdminDashboardScreen`), `NetworkConfiguration.enableUPnP` (`AdminNetworkScreen`) — à traiter dans A4 ou à tolérer.
- Aucune collision de noms (`JellyfinSocket`, `Session`, `Subscription`) — confirmé par la compilation des deux cibles.
