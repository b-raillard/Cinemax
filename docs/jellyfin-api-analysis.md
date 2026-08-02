# Analyse de la surface API Jellyfin — Cinemax

> Analyse réalisée contre `jellyfin-sdk-swift` **0.6.0** (révision `e7bb3b7`, celle épinglée dans
> `Package.resolved`) et l'état du code sur `claude/jellyfin-api-analysis-k8es2e`.
> Objectif : mesurer ce que l'app consomme, ce que le serveur expose et qu'elle ignore, et
> proposer des évolutions hiérarchisées.

---

## 1. État des lieux

### 1.1 Volumétrie

| | Nombre |
|---|---|
| Opérations exposées par le SDK 0.6.0 | **439** |
| Entités (DTO) exposées | 396 |
| Opérations SDK réellement appelées par Cinemax | **72** |
| Endpoints construits à la main (`URLSession`) | **~20** |
| **Couverture brute** | **≈ 21 %** |

Le chiffre brut est trompeur : sur les 439 opérations, une grosse moitié relève de domaines
hors périmètre produit (DLNA ×12, musique/artistes/lyrics ×35, Live TV/tuners/DVR ×45,
channels ×8, variantes `Head*` ×20, assistant d'installation ×8). **Rapportée à la surface
pertinente pour un client vidéo (~170 opérations), la couverture réelle est de l'ordre de 55 %.**

### 1.2 Couverture par domaine

| Domaine | Couverture | Commentaire |
|---|---|---|
| Authentification / Quick Connect | ✅ Complète | Les deux côtés de Quick Connect (initiate + authorize), rare chez les clients tiers |
| Bibliothèque / navigation | ✅ Très bonne | `getItems`, genres, vues, saisons, épisodes, next-up, similar, personnes, filtres de requête |
| Recherche | ✅ Bonne | Choix assumé de `/Persons` + fan-out plutôt que `/Search/Hints` |
| Lecture (négociation, rapports) | ✅ Très bonne | Cycle de vie complet : start/progress/stopped + `stopEncoding` + `ping` + `closeLiveStream` |
| userData (vu / favori) | 🟡 Partielle | `markPlayed`/`markUnplayed`/`favorite` OK — **notes utilisateur absentes**, pas d'endpoint userData léger |
| Administration | ✅ Large | Users, policies, devices, activité, plugins, catalogue, tâches, logs, clés API, éditeur de métadonnées, config réseau/encodage |
| SyncPlay | ✅ Complète (mais kill-switchée) | Écrite à la main — voir §2.1 |
| Télécommande (émission) | 🟡 Partielle | `Play` OK — **réception absente**, voir §2.2 |
| Sous-titres | 🟡 Minimale | Sélection de piste uniquement ; ni recherche/téléchargement distant, ni pièces jointes |
| Collections / Playlists | 🟡 Lecture seule | Navigation OK, **aucune écriture** |
| Recommandations serveur | ❌ Absente | `Suggestions`, `Movies/Recommendations`, `Shows/Upcoming` inutilisés |
| Bonus / extras | ❌ Absente | `SpecialFeatures`, `LocalTrailers`, `ThemeMedia`, `Intros` inutilisés |
| Live TV / DVR | ❌ Absente | Choix produit |
| Musique | ❌ Absente | Choix produit |

---

## 2. Constats techniques (à corriger indépendamment des évolutions)

### 2.1 Le SDK **modélise** SyncPlay — le commentaire du code dit l'inverse

`JellyfinAPIClient+SyncPlay.swift` (189 lignes) et `CLAUDE.md` affirment tous deux :

> « The Jellyfin SDK doesn't model the SyncPlay endpoints, so we hand-build the requests via `URLSession` »

C'est **faux en 0.6.0**. Le SDK expose 20 opérations `Paths.syncPlay*` (`SyncPlayCreateGroup`,
`SyncPlayJoinGroup`, `SyncPlayLeaveGroup`, `SyncPlayPause`, `SyncPlayUnpause`, `SyncPlayStop`,
`SyncPlaySeek`, `SyncPlayReady`, `SyncPlayBuffering`, `SyncPlaySetNewQueue`, `SyncPlayGetGroups`,
`SyncPlayNextItem`, `SyncPlayPreviousItem`, `SyncPlaySetRepeatMode`, `SyncPlaySetShuffleMode`, …)
**plus** `Paths.getUtcTime` avec l'entité `UtcTimeResponse` déjà typée.

Vérification :
```swift
// Sources/Paths/SyncPlayJoinGroupAPI.swift
public extension Paths {
    static func syncPlayJoinGroup(_ body: JellyfinAPI.JoinGroupRequestDto) -> Request<Void> {
        Request(path: "/SyncPlay/Join", method: "POST", body: body, id: "SyncPlayJoinGroup")
    }
}
```

Le contre-argument « session sans cache » ne tient pas non plus : le `JellyfinClient` du SDK est
déjà construit avec `fastFailSessionConfiguration` (`urlCache = nil`), donc un `GET /GetUtcTime`
passé par le SDK n'est pas cachable — c'était la seule justification technique.

**Conséquence** : ~190 lignes de plomberie HTTP à la main, plus le modèle `SyncPlayModels.swift`
maintenu en parallèle des DTO du SDK. Le kill-switch actuel (`watchTogetherEnabled = false`) rend
le moment idéal pour migrer sans risque de régression visible.

À noter : le POST PlaybackInfo à la main (`rawPostPlaybackInfo`) est en revanche **justifié** — il
existe pour capturer le corps de réponse brut à des fins de diagnostic et pour isoler la session
(l'URL de réponse contient l'`api_key`). Ne pas le migrer.

### 2.2 L'app ne déclare jamais ses capacités → elle n'est pas pilotable

Aucun appel à `POST /Sessions/Capabilities/Full` (`Paths.postFullCapabilities`) ni
`POST /Sessions/Capabilities`. Or `RemotePlayTarget.resolve` filtre les cibles sur
`isSupportsRemoteControl == true`, drapeau que **seul** ce POST positionne.

**Déduction au niveau du code (à confirmer sur appareil) : une session Cinemax sur Apple TV
n'apparaît pas dans le sélecteur « Lire sur… » d'un Cinemax iPhone, ni dans celui de Jellyfin Web
ou Findroid.** La fonctionnalité « Lire sur… » ne marche donc aujourd'hui que vers des clients
tiers, jamais vers Cinemax lui-même — ce qui est précisément le cas d'usage principal
(iPhone → sa propre Apple TV).

### 2.3 Segments média : 2 types sur 6

`SkipSegmentController` demande `includeSegmentTypes: [.intro, .outro]`. L'énumération
`MediaSegmentType` du SDK en compte six : `intro`, `outro`, **`recap`**, **`preview`**,
**`commercial`**, `unknown`. « Passer le résumé » (recap) est la demande la plus fréquente sur les
séries après « passer le générique ».

### 2.4 Le débit maximal est codé en dur

`VideoPlayerCoordinator.maxBitrate` = `render4K ? 120_000_000 : 20_000_000`. Aucune mesure, aucune
adaptation au réseau. En LAN c'est correct ; en 4G ou sur un lien ADSL montant faible, demander
120 Mbps fait choisir un DirectPlay d'un remux 80 Mbps que le lien ne soutient pas → buffering
permanent alors qu'un transcode aurait été le bon choix. Le SDK expose `GET /Playback/BitrateTest`
(`Paths.getBitrateTestBytes`), inutilisé.

### 2.5 La configuration utilisateur du serveur est ignorée

Aucune référence à `UserConfiguration` dans le code (`subtitleMode`, `audioLanguagePreference`,
`subtitleLanguagePreference`, `playDefaultAudioTrack`, `rememberAudioSelections`,
`rememberSubtitleSelections`). L'objet arrive pourtant déjà gratuitement dans le `UserDto` de
`getCurrentUser`. La sélection de piste repose uniquement sur `selectedAudioIndex` /
`selectedSubtitleIndex` calculés côté serveur, appliqués par ordinal dans
`applyServerTrackDefaultsIfNeeded`. Le mode « sous-titres toujours actifs » ou « forcés uniquement »
d'un compte Jellyfin n'est donc pas respecté de façon fiable, et aucun réglage n'est offert dans
l'app.

### 2.6 Aucun WebSocket général

`SyncPlaySocket` est le seul usage de `/socket`, et uniquement pour SyncPlay. Le socket Jellyfin
diffuse aussi `UserDataChanged`, `LibraryChanged`, `Play`, `Playstate`, `GeneralCommand`,
`RefreshProgress`, `ScheduledTasksInfo`. L'app compense par un système de notifications internes à
deux niveaux (`.cinemaxShouldRefreshCatalogue` / `.cinemaxItemUserDataChanged`) qui ne voit que
**ses propres** mutations : un épisode marqué vu depuis Jellyfin Web ou une autre Apple TV reste
affiché comme non-vu jusqu'à un rafraîchissement manuel.

---

## 3. Propositions

Légende — **Priorité** : P0 (à faire) · P1 (fort intérêt) · P2 (opportuniste).
**Faisabilité** : ⭐⭐⭐ triviale · ⭐⭐ moyenne · ⭐ lourde/incertaine.

### 3.1 Tableau de synthèse

| # | Proposition | Priorité | Faisab. | Apport client | Inconvénient principal |
|---|---|:--:|:--:|---|---|
| 1 | Segments `recap` / `preview` / `commercial` | **P0** | ⭐⭐⭐ | « Passer le résumé » sur les séries | Dépend du plugin qui les génère |
| 2 | Bonus & bandes-annonces locales | **P0** | ⭐⭐⭐ | Contenu déjà sur le serveur, invisible ; débloque la BA sur tvOS | Rangée vide sur la plupart des biblios |
| 3 | Devenir cible de télécommande | **P0** | ⭐⭐ | « Lire sur… » marche enfin iPhone → Apple TV Cinemax | Session persistante, surface de contrôle distant |
| 4 | Préférences audio/sous-titres du compte | **P0** | ⭐⭐ | Bonne piste au 1er coup, cohérence avec les autres clients | L'écriture modifie un réglage global partagé |
| 5 | Débit adaptatif (BitrateTest) | **P0** | ⭐⭐ | Moins de buffering hors LAN, moins de transcodes en LAN | Consomme de la data ; heuristique imparfaite |
| 6 | Migration SyncPlay → SDK (dette) | **P0** | ⭐⭐⭐ | Aucun (interne) | Zéro visible ; à faire pendant le kill-switch |
| 7 | WebSocket session général | **P1** | ⭐⭐ | État vu/favori synchro temps réel entre appareils | Socket permanent = batterie/reconnexions |
| 8 | Rangées de recommandation serveur | **P1** | ⭐⭐ | Home vivante, découverte | Coûteux pour un serveur auto-hébergé |
| 9 | Playlists en écriture + file d'attente | **P1** | ⭐⭐ | « Ajouter à une playlist », lecture en file | Nouvelle machine d'état à côté d'`EpisodeNavigator` |
| 10 | userData ciblé (`/UserItems/{id}/UserData`) | **P1** | ⭐⭐⭐ | Rails plus réactifs, moins de trafic | Gating de version + chemin de repli à maintenir |
| 11 | Note utilisateur (pouce ↑/↓) | **P1** | ⭐⭐⭐ | Signal personnel, alimente les recos | Confusion possible avec le cœur/favori |
| 12 | Sous-titres distants (admin) | **P1** | ⭐⭐ | Réparer un film sans ST sans quitter l'app | Écriture serveur + dépend d'un plugin |
| 13 | Thème musical & intros « cinema mode » | **P2** | ⭐⭐ | Ambiance tvOS très « Apple TV+ » | Audio auto = intrusif s'il n'est pas réglable |
| 14 | Compléments admin | **P2** | ⭐⭐⭐ | Tableau de bord complet | Actions destructives, usage rare |
| 15 | Avatars serveur (`/UserImage`) | **P2** | ⭐⭐⭐ | Finition visuelle | Piège multi-serveur (RULE ServersScreen c) |
| 16 | Login : mot de passe oublié + branding | **P2** | ⭐⭐⭐ | Écran de login « fini » | Chemin mort si le serveur n'a pas de provider |
| 17 | Polices embarquées ASS (`Attachments`) | **P2** | ⭐ | Sous-titres stylés corrects (animes) | Dépend de ce que SwiftVLC 0.3.0 expose |
| 18 | `DisplayPreferences` synchronisées | **P2** | ⭐⭐ | Tri/vue identiques entre clients | Schéma serveur mal spécifié, conflit avec `@AppStorage` |
| 19 | Live TV / DVR | **P2** | ⭐ | Indispensable *si* tuner, nul sinon | Chantier énorme, intestable sans matériel |

---

### 3.2 Détail des propositions P0

#### 1. Segments média complets — `recap`, `preview`, `commercial`

*Endpoint* : `GET /Items/{id}/MediaSegments` (déjà appelé).

**Ce que ça change** : bouton « Passer le résumé » au début des épisodes de série, « Passer
l'aperçu » sur les previews de fin, « Passer la publicité » sur les enregistrements TV.

**Faisabilité ⭐⭐⭐** — une ligne dans `SkipSegmentController.swift:55`, trois cas dans le `switch`
de libellé (`SkipSegmentController.swift:105`), six clés de localisation FR/EN. Toute la machinerie
(détection temporelle, ré-entrée, seek vers `segment.end`, rendu iOS/tvOS) est déjà en place et
type-agnostique.

**Inconvénients** : aucun techniquement. Fonctionnellement, les segments `recap`/`preview` ne sont
produits que par certains plugins (Intro Skipper récent, MediaSegments API 10.10+) ; sur un serveur
qui ne les génère pas, le comportement est strictement identique à aujourd'hui. Attention à ne pas
enchaîner deux bannières (un `recap` suivi immédiatement d'un `intro`) — prévoir une priorité.

---

#### 2. Bonus & bandes-annonces locales

*Endpoints* : `GET /Items/{id}/SpecialFeatures`, `GET /Items/{id}/LocalTrailers`.

**Ce que ça change** : les making-of, scènes coupées, featurettes et bandes-annonces stockés
localement (dossiers `extras/`, `specials/`, `trailers/` — remplis automatiquement par Jellyfin)
sont aujourd'hui **totalement invisibles** dans Cinemax alors qu'ils sont déjà indexés côté serveur.
Bénéfice secondaire important : la bande-annonce devient lisible **sur tvOS**, alors que le bouton
actuel (`detail.showTrailerButton`) est iOS-only parce qu'il ouvre `remoteTrailers` dans Safari.

**Faisabilité ⭐⭐⭐** — deux `GET` qui renvoient des `[BaseItemDto]`, donc directement consommables
par `ContentRow` + `PlayLink` sans nouveau modèle. À charger en `Task` latéral après le chargement
principal, comme `loadCollection` / `loadRemoteTargets` (même discipline : échec silencieux).

**Inconvénients** : la majorité des bibliothèques n'ont pas d'extras → la rangée doit disparaître si
vide (même règle que les rangées de genre). Les extras sont des items sans `userData` exploitable :
pas de reprise de lecture, pas de badge « vu » — il faut le prévoir pour ne pas polluer la
Continue Watching.

---

#### 3. Devenir une cible de télécommande — `POST /Sessions/Capabilities/Full`

*Endpoint* : `Paths.postFullCapabilities(_ body: ClientCapabilitiesDto)`.

**Ce que ça change** : c'est le chaînon manquant de la fonctionnalité « Lire sur… » déjà livrée.
Aujourd'hui Cinemax **émet** une commande de lecture mais ne se déclare jamais comme pilotable,
donc `RemotePlayTarget.resolve` (qui exige `isSupportsRemoteControl == true`) élimine toute session
Cinemax. Résultat : on ne peut pas envoyer un film de son iPhone vers sa propre Apple TV — le cas
d'usage numéro un. Un simple POST au moment de la connexion corrige ça, et rend aussi Cinemax
pilotable depuis Jellyfin Web, Findroid, Swiftfin.

Le DTO à envoyer :
```swift
ClientCapabilitiesDto(
    deviceProfile: <le profil VLC ou Apple selon le réglage>,
    playableMediaTypes: [.video],
    supportedCommands: [.playState, .play, .displayMessage, .setAudioStreamIndex,
                        .setSubtitleStreamIndex, .volumeUp, .volumeDown, .mute, …],
    isSupportsMediaControl: true,
    isSupportsPersistentIdentifier: true
)
```

**Faisabilité ⭐⭐** — le POST lui-même est trivial (à appeler dans `AppState.applyActiveServer` /
après `authenticate`, avec re-post au changement de serveur). Le vrai travail est de **recevoir**
les commandes : il faut le WebSocket général (proposition 7) et un routage vers le player. Bonne
nouvelle : le patron existe déjà — le `PlaybackBridge` de `SyncPlayController` fait exactement ça
(commande entrante → appel moteur direct, sans ré-émission).

Découpage possible en deux temps : (a) POST des capacités seul → l'appareil apparaît dans les
listes et accepte `PlayNow` au prochain démarrage de l'app ; (b) socket + commandes temps réel.
L'étape (a) apporte déjà l'essentiel si l'app tourne au premier plan sur l'Apple TV.

**Inconvénients** :
- **Sécurité/UX** : déclarer `supportsMediaControl` signifie que n'importe quelle session du même
  compte peut déclencher une lecture sur l'appareil. C'est le comportement standard Jellyfin, mais
  il mérite un réglage « autoriser le contrôle à distance » (défaut activé) et une confirmation
  visuelle quand une lecture est déclenchée à distance.
- Sur tvOS, l'app doit être au premier plan pour réagir ; hors premier plan la session expire côté
  serveur et la cible disparaît de la liste. Comportement identique aux autres clients, mais à
  documenter pour ne pas être perçu comme un bug.
- Le `deviceProfile` envoyé dans les capacités doit rester cohérent avec celui envoyé au moment du
  `PlaybackInfo` (VLC vs natif selon `forceNativeAVPlayer`) — sinon le serveur pré-transcode selon
  le mauvais profil quand la lecture est initiée à distance.

---

#### 4. Préférences audio / sous-titres du compte serveur

*Source* : `UserDto.configuration` (déjà récupéré), écriture via `POST /Users/Configuration`.

**Ce que ça change** : respect de `subtitleMode` (`Default` / `Always` / `OnlyForced` / `None` /
`Smart`), `audioLanguagePreference`, `subtitleLanguagePreference`, `playDefaultAudioTrack`. Un
utilisateur qui a réglé « sous-titres toujours affichés en français » sur Jellyfin Web retrouve le
même comportement dans Cinemax. Et surtout : un écran de réglages « Langues » dans
Settings → Lecture, absent aujourd'hui.

**Faisabilité ⭐⭐** — la lecture est gratuite (l'objet est déjà dans le `UserDto` que
`refreshCurrentUser()` récupère). Le point d'application est `applyServerTrackDefaultsIfNeeded`
(`VLCStreamPresenter.swift:2326`) et son équivalent natif : au lieu de suivre aveuglément
`selectedSubtitleIndex`, arbitrer avec le mode voulu (ex. `Always` → forcer la première piste dans
la langue préférée même si le serveur n'en a sélectionné aucune). L'écriture nécessite un nouvel
`AuthAPI`/`ServerAPI` member + un écran.

**Inconvénients** :
- L'écriture modifie une préférence **globale du compte**, partagée avec tous les autres clients.
  Il faut le dire explicitement dans l'UI (« ce réglage s'applique à tous vos appareils Jellyfin »),
  sinon c'est un effet de bord surprenant. Alternative plus sûre : lecture seule dans un premier
  temps, avec un override local `@AppStorage` par-dessus.
- `rememberAudioSelections` / `rememberSubtitleSelections` impliquent de mémoriser les choix par
  série côté serveur — surface plus large, à traiter dans un second lot.

---

#### 5. Débit adaptatif — `GET /Playback/BitrateTest`

**Ce que ça change** : `maxBitrate` cesse d'être un booléen 4K/1080p déguisé. Le serveur télécharge
quelques Mo, on mesure le débit réel, on plafonne la négociation en conséquence. En LAN gigabit on
demande le maximum (donc DirectPlay, zéro transcode) ; en 4G on demande 8 Mbps (donc un transcode
qui *tient*, plutôt qu'un DirectPlay qui bégaie).

**Faisabilité ⭐⭐** — l'endpoint prend un `size` en octets et renvoie des octets aléatoires : la
mesure est un simple chrono. `NetworkMonitor` existe déjà et donne le signal de re-mesure
(changement d'interface). Le réglage `render4K` devient un tri-état : *Auto* (défaut) / *Maximum* /
*Économe*.

**Inconvénients** :
- La mesure consomme de la data. **Ne jamais la lancer automatiquement en cellulaire** sans un
  réglage explicite — sinon c'est un motif de rejet App Review et une mauvaise surprise pour
  l'utilisateur. Mesurer en Wi-Fi, appliquer une valeur conservatrice par défaut en cellulaire.
- Une mesure ponctuelle est un mauvais prédicteur d'un lien instable. Prévoir un plancher/plafond,
  un lissage sur plusieurs mesures, et surtout ne pas re-négocier en cours de lecture (ce serait
  une refonte complète vers de l'ABR côté client, hors de portée avec libVLC).
- Interaction avec `MediaSourceQuality` : le plafond de bitrate est le **premier** critère de tri
  des versions multiples. Un plafond dynamique fait donc varier la version choisie d'une session à
  l'autre pour un même film — comportement correct mais qui peut surprendre. Le laisser visible
  dans la rangée « Version ».

---

#### 6. Migration SyncPlay vers le SDK (dette)

Voir §2.1. Suppression d'environ 190 lignes de `URLSession` manuel + alignement de
`SyncPlayModels.swift` sur les DTO du SDK (`GroupInfoDto`, `JoinGroupRequestDto`,
`NewGroupRequestDto`, `PlaybackRequestDto`, `UtcTimeResponse`).

**Faisabilité ⭐⭐⭐** — traduction mécanique, et le code est actuellement **inactif** (kill-switch
`MediaDetailScreen.watchTogetherEnabled = false`), donc aucun risque de régression visible.

**Inconvénients** : la couverture de test de SyncPlay est faible (la feature étant désactivée), donc
la migration se valide surtout par relecture. Et il faut d'abord corriger la note correspondante
dans `CLAUDE.md`, qui documente aujourd'hui une contrainte inexistante — sans quoi un futur
contributeur ré-écrira du HTTP à la main.

---

### 3.3 Détail des propositions P1

#### 7. WebSocket de session général

Étend `SyncPlaySocket` (déjà un `actor` autour de `URLSessionWebSocketTask`, avec parsing en frames
`Sendable` via `AsyncStream` — l'architecture est bonne, il suffit d'élargir le vocabulaire).

**Apport** : `UserDataChanged` et `LibraryChanged` poussés par le serveur remplacent la moitié du
système de notifications à deux niveaux — un épisode marqué vu depuis Jellyfin Web se met à jour
en direct dans Cinemax. `Play` / `Playstate` / `GeneralCommand` complètent la proposition 3.
`RefreshProgress` et `ScheduledTasksInfo` rendraient l'écran Tâches admin réactif au lieu du
polling 2 s actuel.

**Inconvénients** : une connexion permanente coûte en batterie et en réveils réseau ; il faut la
fermer en arrière-plan et la rouvrir sur `scenePhase .active`, ce qui interagit avec la logique de
re-validation de session existante. Risque de tempête de rafraîchissements si le serveur émet
beaucoup d'événements (scan de bibliothèque en cours) → prévoir un debounce et réutiliser le
mécanisme de report `isVisible` déjà en place.

#### 8. Rangées de recommandation serveur

`GET /Items/Suggestions`, `GET /Movies/Recommendations` (renvoie des `RecommendationDto` portant le
**motif** : `SimilarToRecentlyPlayed`, `HasDirectorFromRecentlyPlayed`, `HasActorFromRecentlyPlayed`
— de quoi écrire un vrai titre de rangée « Parce que vous avez regardé X »), `GET /Shows/Upcoming`
(« Prochainement »).

**Inconvénients** : trois appels de plus dans un `HomeViewModel.load` déjà lourd — les intégrer au
fan-out chunké à 6 et les traiter comme les rangées de genre (échec = rangée absente, jamais un
écran d'erreur). Les recos Jellyfin sont basées sur les métadonnées (acteurs, réalisateurs, genres),
pas sur du collaboratif : sur une petite bibliothèque elles sont pauvres, voire répétitives par
rapport à la rangée « Similaires » déjà présente sur la fiche détail. À rendre désactivable
(`home.showRecommendations`) comme toutes les autres rangées.

#### 9. Playlists en écriture

`POST /Playlists`, `POST /Playlists/{id}/Items`, `GET /Playlists/{id}/Items`,
`DELETE /Playlists/{id}/Items`, `POST /Playlists/{id}/Items/{itemId}/Move/{index}`.

**Apport** : « Ajouter à une playlist » s'insère naturellement dans `MediaCardContextMenu` (déjà
partagé par la bibliothèque, la recherche et l'historique) ; puis lecture en file continue.

**Inconvénients** : la file d'attente dans le player est le vrai coût, et elle **duplique
conceptuellement** l'`EpisodeNavigator` existant. Décider en amont si la file remplace ou coexiste
avec la navigation d'épisodes — deux machines d'état concurrentes dans `VLCStreamPresenter` serait
une source de bugs certaine. Recommandation : livrer d'abord l'écriture (ajout/retrait/réordonnancement)
sans file d'attente dans le player, puis évaluer.

#### 10. userData ciblé — `GET /UserItems/{id}/UserData`

Permet de rafraîchir l'état vu/reprise d'un item sans re-télécharger le `BaseItemDto` complet.
Cible naturelle du tier-2 `.cinemaxItemUserDataChanged`.

**Inconvénients** : endpoint récent — il faut un gating par version serveur (le modèle existe déjà
avec `getCollections`, mais **en mieux** : gater sur `ServerInfo.version` déjà stocké plutôt que
d'encaisser un 404 systématique). Gain surtout perceptible sur gros catalogues et connexions lentes ;
sur une bibliothèque modeste le bénéfice est marginal par rapport au coût du chemin parallèle.

#### 11. Note utilisateur — `POST /UserItems/{id}/Rating`, `DELETE /UserItems/{id}/Rating`

**Inconvénients** : Jellyfin expose la note comme un booléen `Likes` (pouce haut/bas), pas une note
sur 5 — attention à ne pas promettre une granularité inexistante. Et le risque produit est réel : un
cœur (favori) **et** un pouce sur la même carte, c'est deux affordances proches dont la différence
n'est pas évidente. À réserver à la fiche détail plutôt qu'au menu contextuel des posters.

#### 12. Sous-titres distants — `GET /Items/{id}/RemoteSearch/Subtitles/{lang}` + `POST …/{subtitleId}`

**Apport** : depuis la fiche d'un film sans sous-titres, chercher et installer une piste
OpenSubtitles sans quitter l'app.

**Inconvénients** : c'est une **écriture serveur** → à placer sous `AdminAPI` et à gater sur
`isAdministrator` (cohérent avec le reste de la section Admin, donc iOS-only). Dépend du plugin
OpenSubtitles configuré côté serveur. Après téléchargement il faut re-négocier `PlaybackInfo` pour
que la nouvelle piste apparaisse — donc une invalidation de cache `getItem` en plus.

---

### 3.4 Détail des propositions P2

#### 13. Thème musical & intros « cinema mode »
`GET /Items/{id}/ThemeMedia`, `GET /Items/{id}/Intros`. Le thème d'une série joué en fond sur la
fiche détail est très caractéristique des clients TV soignés. **Inconvénients** : audio qui démarre
tout seul = intrusif ; obligatoirement opt-in, avec coupure immédiate à la navigation et respect de
`motionEffects` / silencieux. `Intros` (cinema mode) demande un plugin et allonge le délai avant
image — probablement à ignorer.

#### 14. Compléments admin
`POST /Library/Refresh` (scan complet — actuellement seulement atteignable via les tâches
planifiées), `POST /System/Restart`, `POST /System/Shutdown`, `GET /System/Storage`,
`GET /Items/Counts` (compteurs pour le dashboard), `POST /Videos/MergeVersions`, gestion des
dossiers virtuels, sauvegardes 10.11 (`/Backup`). **Inconvénients** : actions destructives ou à
usage très rare ; chacune coûte un écran. À traiter à la demande plutôt qu'en lot.

#### 15. Avatars serveur — `GET /UserImage`
**Inconvénient spécifique** : la RULE (c) de `ServersScreen` interdit de charger l'avatar d'une
entrée non-active (l'`ImageURLBuilder` pointe le serveur actif → 404 ou requête inter-serveurs).
L'usage doit donc rester limité au serveur actif : sélecteur d'utilisateur, en-tête Réglages.

#### 16. Login — `POST /Users/ForgotPassword`, `GET /Branding/Configuration`
**Inconvénients** : `ForgotPassword` n'aboutit que si un provider de réinitialisation est configuré
(rarement le cas en auto-hébergé) → n'afficher le lien que si `GetPasswordResetProviders` en
retourne un, sinon c'est un chemin mort. `Branding` renvoie du HTML/CSS libre : n'afficher que le
texte brut échappé, jamais de rendu HTML (surface XSS depuis un serveur tiers).

#### 17. Polices embarquées — `GET /Videos/{id}/{sourceId}/Attachments/{index}`
Corrigerait le rendu des sous-titres ASS/SSA stylés (animes). **Inconvénients** : il faut écrire les
polices dans un répertoire temporaire et le faire consommer par libVLC — dépend de ce que
SwiftVLC 0.3.0 laisse passer comme options d'instance, ce qui n'est pas garanti. Gain de niche pour
un risque d'intégration élevé.

#### 18. `DisplayPreferences`
**Inconvénients** : schéma serveur en sac de clés/valeurs mal spécifié, et l'app a déjà
`LibrarySortFilterState` local + des `@AppStorage` globaux. Fort risque de conflit de source de
vérité pour un bénéfice faible. **Non recommandé en l'état.**

#### 19. Live TV / DVR
~45 endpoints, un guide EPG, un modèle de lecture différent (flux live sans reprise), des timers et
des enregistrements. **Inconvénients** : chantier énorme, impossible à tester sans tuner, et sans
valeur pour la majorité des utilisateurs de Jellyfin en vidéothèque. À n'envisager que sur demande
utilisateur avérée.

---

## 4. Séquencement suggéré

**Lot 1 — « quick wins » (faible risque, effet immédiat)**
Propositions 1, 2, 6. Trois changements localisés, aucun nouveau modèle de données, zéro impact
sur l'architecture. Corrige au passage une note erronée dans `CLAUDE.md`.

**Lot 2 — « la télécommande qui marche »**
Proposition 3 (étape a : POST des capacités), puis 7 (socket), puis 3 (étape b : commandes
entrantes). C'est le lot qui rend enfin utilisable une fonctionnalité déjà livrée, et le socket
sert ensuite à tout le reste.

**Lot 3 — « la lecture juste »**
Propositions 4 et 5. Les deux touchent la négociation de lecture — les faire ensemble évite deux
régressions séparées sur le chemin le plus sensible de l'app, et permet de tester le tout dans une
même campagne (LAN / 4G / serveur lent).

**Lot 4 — « découverte »**
Propositions 8, 11, puis 9. À arbitrer selon les retours utilisateurs ; c'est le lot le plus
discutable en termes de rapport valeur/effort.

---

## 5. Points de vigilance transverses

- **Gating par version serveur** : plusieurs propositions (10, segments récents, sauvegardes)
  dépendent de Jellyfin ≥ 10.10/10.11. `ServerInfo.version` est déjà stocké mais **jamais lu** pour
  décider quoi que ce soit. Introduire un helper de comparaison de version dans CinemaxKit avant le
  premier usage, plutôt que de multiplier les `try?` + repli silencieux comme dans `getCollections`.
- **Frontière de privilège** : toute écriture serveur (12, 14) va dans `AdminAPI`, donc iOS-only par
  décision produit. Ne pas la glisser dans `LibraryAPI` par commodité.
- **Discipline de session** : tout nouvel endpoint construit à la main doit reprendre le triptyque
  existant — en-tête `MediaBrowser`, `setEndpointPath(_:preservingBasePathOf:)` (sinon 404 sur les
  serveurs en sous-chemin), session éphémère `urlCache = nil`, `notifyIfUnauthorized`.
- **Budget de requêtes sur Home** : la page fait déjà un fan-out chunké à 6. Les propositions 2 et 8
  en ajoutent ; les intégrer au chunking existant et non en parallèle, sinon un serveur auto-hébergé
  modeste se fait saturer au lancement.
