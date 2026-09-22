# Hygiène des sessions de transcodage

**Statut** : validé, prêt pour le plan d'implémentation
**Lot** : 1/5 de la série « endpoints Jellyfin inexploités » (ordre : hygiène → recherche de personnes → bonus/trailers → recommandations → télécommande)

## Objectif

Fermer proprement les ressources que le serveur Jellyfin alloue pour chaque lecture, et empêcher qu'il récupère un transcode encore utilisé pendant une pause longue.

Aucune UI. Aucun réglage. Le lot est entièrement invisible pour l'utilisateur, sauf par son effet : moins de charge résiduelle sur un serveur auto-hébergé, et une pause longue sur un flux transcodé qui ne se solde plus par un flux mort au réveil.

## Problème

Cinemax demande systématiquement `isAutoOpenLiveStream=true` dans son `POST /Items/{id}/PlaybackInfo`, et **force un transcode HLS** sur les conteneurs seek-heavy (`avi/divx/wmv/asf/flv/vob/mpg/mpeg/mpe/m2v`). Chaque lecture de ce type alloue donc côté serveur un live stream et un job ffmpeg.

À l'arrêt, le client n'envoie que `POST /Sessions/Playing/Stopped`, **sans `liveStreamId`** (`JellyfinAPIClient+Playback.swift`, `reportPlaybackStopped`). Conséquences :

- le live stream ouvert n'est jamais désigné comme fermable ;
- le job d'encodage n'est jamais tué explicitement — le serveur doit l'expirer de lui-même ;
- pendant une pause, plus aucun octet ne circule, donc le serveur peut considérer le job inactif et le récupérer. C'est le scénario que le lecteur rattrape aujourd'hui *après coup* via `reResolveAndResume`.

`PlaybackInfo` (le modèle CinemaxKit, pas le DTO serveur) ne transporte pas `liveStreamId` : c'est le seul vrai travail de plomberie du lot.

## Périmètre

**Dans le périmètre**

- Ajout de `liveStreamId` à `PlaybackInfo` et transmission jusqu'à l'arrêt.
- Trois nouvelles méthodes sur `PlaybackAPI` : ping, arrêt d'encodage, fermeture de live stream.
- Centralisation de la séquence d'arrêt et du keep-alive dans `PlaybackReporter`.

**Hors périmètre**

- Toute UI, tout réglage utilisateur, toute chaîne localisée.
- Le chemin `AVPlayer` natif n'est pas modifié structurellement : il hérite du comportement parce qu'il partage `PlaybackReporter`.
- La détection de flux mort existante (`reResolveAndResume`) reste en place. Ce lot réduit la fréquence du scénario, il ne le remplace pas.

## Décisions d'architecture

### `PlaybackReporter` est le propriétaire unique

Ni `VLCStreamPresenter` ni `NativeVideoPresenter` n'appellent directement les nouveaux endpoints. Toute la séquence vit dans `PlaybackReporter`, qui possède déjà le contrat de reporting de lecture et reçoit déjà les ticks des deux moteurs via `onTick()`.

Raison : les deux presenters ont des teardowns distincts (dismiss iOS, delegate tvOS, navigation d'épisode, PiP). Dupliquer la séquence à chacun de ces points garantit qu'un chemin sera oublié — c'est exactement la classe de bug documentée pour l'activation de session audio. Un seul propriétaire, les deux moteurs en héritent.

### Le keep-alive est doublement conditionné

`POST /Playback/Ping` n'est envoyé que si **les deux** conditions sont vraies :

1. `playMethod == .transcode` — une session DirectPlay n'a pas de job ffmpeg à maintenir en vie ; le ping y serait un no-op serveur, donc du trafic pur.
2. **la lecture est en pause** — tant que le moteur tire ses segments, le job n'est pas inactif et n'a pas besoin d'être ping.

Cadence : 30 s, via un compteur de ticks sur l'observateur 1 s existant. **Aucun nouveau timer** (le presenter possède un unique `addPeriodicTimeObserver`, les sous-contrôleurs n'en ajoutent jamais).

Coût réel : **zéro requête ajoutée sur une lecture normale**, 2/min uniquement pendant une pause sur un flux transcodé. À comparer aux 6/min que `reportPlaybackProgress` envoie déjà (throttle de 10 ticks).

**Hypothèse à valider sur serveur réel** : « une lecture active suffit à maintenir le job en vie ». Si elle est fausse, on retire la condition 2 et on ping à 30 s en continu dès qu'on transcode — le surcoût reste marginal.

### L'arrêt d'encodage est systématique, la fermeture de live stream est réservée à l'abandon

`DELETE /Videos/ActiveEncodings` est envoyé **à chaque arrêt**, sans regarder `playMethod`. L'appel est idempotent côté serveur (no-op s'il n'y a pas de job) et cette inconditionnalité couvre le cas où le serveur a décidé de transcoder sans que le client l'ait déduit de la réponse.

`POST /LiveStreams/Close` n'est **pas** appelé sur le chemin nominal : transmettre `liveStreamId` dans `Sessions/Playing/Stopped` suffit, le serveur ferme le flux lui-même. L'appel explicite est réservé au chemin d'abandon — `PlaybackInfo` a réussi mais la lecture n'a jamais démarré (échec d'ouverture du moteur, dismiss avant la première frame). Sans lui, ce cas laisse un live stream ouvert qu'aucun `Stopped` ne viendra jamais réclamer.

### Les nouvelles méthodes `PlaybackAPI` ont des implémentations par défaut

Les trois méthodes sont déclarées avec un corps par défaut vide dans l'extension du protocole, sur le modèle explicite de `SyncPlayAPI`.

Raison : `CountingPlaybackAPI` (`Tests/CinemaxKitTests/PlaybackReporterTests.swift`) conforme `PlaybackAPI` à la main. Sans implémentation par défaut, l'ajout de trois exigences casse la compilation de la suite existante et oblige à écrire trois stubs sans rapport avec ce qu'elle teste. Les tests de ce lot surchargeront explicitement les méthodes qui les concernent.

## Composants

### `PlaybackInfo` — un champ

`public let liveStreamId: String?`, alimenté depuis `mediaSource.liveStreamID` de la réponse serveur.

Attention : `_getPlaybackInfo` construit `PlaybackInfo` à **plusieurs endroits** (chemin transcode avec `transcodingURL`, chemin flux direct, repli sans PlaybackInfo). Le champ doit être renseigné à chacun ; le repli direct-stream (qui n'a jamais parlé au serveur) porte légitimement `nil`.

### `PlaybackAPI` — trois méthodes

| Méthode | Endpoint SDK | Paramètres |
|---|---|---|
| `pingPlaybackSession(playSessionId:)` | `Paths.pingPlaybackSession(playSessionID:)` | id de session de lecture |
| `stopEncoding(deviceId:playSessionId:)` | `Paths.stopEncodingProcess(deviceID:playSessionID:)` | `KeychainService.getOrCreateDeviceID()` + id de session |
| `closeLiveStream(liveStreamId:)` | `Paths.closeLiveStream(liveStreamID:)` | id de live stream |

`reportPlaybackStopped` gagne un paramètre `liveStreamId: String?` transmis à `PlaybackStopInfo.liveStreamID`.

### `PlaybackReporter` — deux évolutions

- `reportStop()` : signale l'arrêt **avec** le `liveStreamId`, puis déclenche `stopEncoding`. Les deux dans la même `Task.detached` séquentielle — l'ordre compte, le serveur doit enregistrer la position de reprise avant qu'on tue le job.
- `onTick()` : ajoute un compteur de ping indépendant du compteur de progression existant (les deux cadences diffèrent, 30 s contre 10 s, et le ping porte des conditions que la progression n'a pas). Le compteur est remis à zéro quand la lecture repart, pour qu'une reprise ne déclenche pas un ping résiduel.

### Chemin d'abandon

Quand un `PlaybackInfo` a été obtenu mais que la lecture ne démarre jamais, le presenter appelle `closeLiveStream` (si `liveStreamId` est non-nil) **et** `stopEncoding` — même inconditionnalité que sur le chemin nominal : le moteur a pu tirer assez de segments pour que le serveur ait lancé un job avant d'échouer.

Points d'accroche identifiés :

- `VLCStreamPresenter.handlePlaybackError()` (`VLCStreamPresenter.swift:3002`) — échec d'ouverture et retry épuisé ;
- `NativeVideoPresenter.showPlaybackErrorAlert(error:)` (`NativeVideoPresenter.swift:732`), atteint seulement après épuisement de `retryWithDirectURL` (`:342`).

Le teardown avant première frame (dismiss très précoce) passe déjà par `reportStop()`, donc par le chemin nominal — il n'a pas besoin d'un traitement séparé.

## Flux

**Lecture nominale d'un fichier transcodé**

1. `PlaybackInfo` → le serveur ouvre un live stream et un job ffmpeg, réponse porte `playSessionId` + `liveStreamId`.
2. `reportStart` (inchangé).
3. Tick 1 s : progression toutes les 10 s (inchangé) ; ping toutes les 30 s **uniquement pendant les pauses**.
4. Arrêt : `Stopped` avec `liveStreamId` → `DELETE /Videos/ActiveEncodings`.

**Lecture DirectPlay** — identique, sans aucun ping. Le `DELETE` part quand même (no-op serveur).

**Abandon avant démarrage** — `PlaybackInfo` a réussi, le moteur échoue : `closeLiveStream(liveStreamId)` + `stopEncoding`, pas de `Stopped` (aucune lecture n'a eu lieu, donc aucune position de reprise à enregistrer).

## Erreurs

Tous les nouveaux appels sont **best-effort et silencieux**, comme le reporting de lecture existant : `Task.detached`, erreur avalée et journalisée, jamais remontée à l'UI. Un serveur pré-10.x qui ne connaît pas une route renvoie un 404 sans conséquence.

Aucun de ces appels ne doit passer par `notifyIfUnauthorized` : ils partent pendant un teardown, souvent alors que l'app se met en arrière-plan, et un 401 transitoire y déclencherait une revalidation de session parasite. Ils suivent le régime des reports de lecture, pas celui des lectures de catalogue.

## Tests

Cible : `Tests/CinemaxKitTests/`, suite swift-testing, mock `PlaybackAPI` sur le modèle de `CountingPlaybackAPI`.

- L'arrêt envoie `Stopped` **puis** `stopEncoding`, dans cet ordre.
- Le `liveStreamId` de `PlaybackInfo` arrive bien dans l'appel `Stopped`.
- Un `liveStreamId` nil ne bloque ni ne déforme la séquence d'arrêt.
- Le ping ne part pas en DirectPlay, même en pause.
- Le ping ne part pas en lecture active, même en transcode.
- Le ping part une fois par tranche de 30 ticks en pause sur un transcode.
- Le compteur de ping se remet à zéro à la reprise.

Le **chemin d'abandon n'est pas couvert par les tests unitaires** : il vit dans les presenters UIKit, hors de portée d'un mock `PlaybackAPI`. Il se vérifie à la main, en coupant le serveur entre la réponse `PlaybackInfo` et l'ouverture du flux.

Rappel projet : `-only-testing` exécute silencieusement 0 test swift-testing. Lancer la suite complète et vérifier la présence de la suite dans la sortie.

## Ce que ce lot ne prétend pas faire

Il ne supprime pas la nécessité de `reResolveAndResume` : un serveur peut toujours perdre un flux pour d'autres raisons (redémarrage, coupure réseau, expiration de token). Il réduit la fréquence d'un scénario précis — la récupération d'un job inactif pendant une pause — et nettoie derrière lui. Rien de plus.
