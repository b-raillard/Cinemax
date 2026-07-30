# Télécommande — « Lire sur… »

**Statut** : validé (option A), prêt pour le plan d'implémentation
**Lot** : 5/5 de la série « endpoints Jellyfin inexploités » (ordre : hygiène des transcodes → recherche de personnes → ~~bonus/trailers~~ *abandonné* → recommandations *non commencé* → **télécommande**)

## Objectif

Depuis la fiche d'un film sur le téléphone, lancer sa lecture **sur l'Apple TV** — sans se lever, sans chercher le titre à la Siri Remote.

## Problème

Chercher et parcourir un catalogue sur une télécommande est pénible ; sur un téléphone c'est immédiat. Jellyfin sait déjà router un ordre de lecture vers une autre session (`POST /Sessions/{id}/Playing`), et l'app n'exploite pas du tout cette voie. Aujourd'hui la seule façon de lancer un film sur la TV est de le retrouver depuis la TV.

`GET /Sessions` est utilisé (rangée « En direct » de l'accueil) mais **gated admin**, à raison — l'endpoint non filtré fuit les sessions de tous les utilisateurs sur certains serveurs ([jellyfin#5210](https://github.com/jellyfin/jellyfin/issues/5210)). Le paramètre `controllableByUserId`, jamais utilisé, ne renvoie que les sessions pilotables par l'utilisateur courant : **le lot est donc accessible à tous, pas seulement aux admins.**

## Périmètre

**Dans le périmètre**

- Une affordance « Lire sur… » sur `MediaDetailScreen`, **iOS et tvOS**, visible **seulement** quand au moins une cible existe.
- Une feuille listant les appareils cibles ; un tap envoie `PlayNow` et confirme par un toast.
- Reprise et version honorées : mêmes règles que le bouton Lecture local (série → épisode suivant, position de reprise, `mediaSourceId` choisi).

**Hors périmètre — décision A assumée**

- **Aucun contrôle depuis le téléphone après l'envoi.** Pas de pause, pas de seek, pas de bandeau persistant. On envoie, puis on pilote à la télécommande de la TV.
- Aucun état global, aucune tâche de fond, aucune socket.
- Pas de mise en file (`PlayNext` / `PlayLast`), pas d'envoi depuis les grilles ou les rangées d'accueil — la fiche seule.
- Réveiller un appareil éteint. Impossible : une session Jellyfin n'existe que si l'app tourne sur la cible.

### Ce que l'option A donne vraiment

Point établi et vérifié dans le code au moment du choix, parce qu'il est contre-intuitif : `PlaybackLiveActivityController` et `NowPlayingInfoController` ne sont attachés **que par les deux presenters locaux** ([NativeVideoPresenter.swift:158](../../../Shared/Screens/NativeVideoPresenter.swift), [VLCStreamPresenter.swift:478](../../../Shared/Screens/VideoPlayer/VLCStreamPresenter.swift)). Envoyer un film sur l'Apple TV n'ouvre aucun lecteur sur le téléphone : **aucune Live Activity, aucune entrée Now Playing, aucun bandeau au centre de contrôle**. Le bandeau apparaît sur l'Apple TV.

| | Source du flux | Le téléphone garde-t-il les contrôles ? |
|---|---|---|
| **AirPlay** | le téléphone | oui, il reste la source |
| **Télécommande Jellyfin** (ce lot) | l'Apple TV, qui tire du serveur | non, le téléphone n'est qu'un émetteur d'ordres |

Et AirPlay n'est pas un repli : l'AirPlay vidéo est impossible sur le chemin libVLC, qui est le moteur par défaut.

## Décisions d'architecture

### `controllableByUserId`, plus un filtre local sur l'utilisateur

Le serveur est censé ne renvoyer que les sessions pilotables. On **re-filtre quand même** côté client sur `userID == currentUserId` : sur un serveur qui ignorerait le paramètre (ancienne version, fork), la réponse contiendrait les sessions des autres utilisateurs, et un tap enverrait un film sur la TV de quelqu'un d'autre. Une session dont `userID` est absent est écartée — on ne peut pas la vérifier.

Conséquence assumée : un admin ayant `EnableRemoteControlOfOtherUsers` ne pourra pas piloter la session d'un autre utilisateur depuis cette feuille. Ce n'est pas le cas d'usage du lot (« envoyer sur *mon* Apple TV »), et c'est le sens le plus sûr par défaut.

### Un nouveau tranchant de protocole `RemoteControlAPI`

Deux méthodes cohésives, sur le modèle exact de `SyncPlayAPI` : implémentations par défaut vides dans l'extension de protocole, pour que les mocks écrits à la main continuent de compiler sans stub. Leçon du lot 1 — deux conformeurs existent (`JellyfinAPIClient`, `MockAPIClient`) et l'un avait été oublié.

`getActiveSessions` reste sur `AuthAPI` où il vit déjà ; on n'y touche pas.

### La résolution des cibles est une fonction pure, dans CinemaxKit

`RemotePlayTarget.resolve(sessions:currentUserId:excludingDeviceId:)` — testable sans app, sans réseau, sans simulateur. Les règles de filtrage sont la partie où l'on peut se tromper silencieusement ; elles sont donc verrouillées par des tests unitaires plutôt que par une vérification à l'œil.

Règles, dans l'ordre :

1. session avec un `id` non vide (sans quoi on ne peut pas l'adresser) ;
2. `userID == currentUserId` (cf. ci-dessus) ;
3. `isSupportsRemoteControl == true` ;
4. `deviceID != ` notre propre `deviceID` — s'envoyer à soi-même, c'est le bouton Lecture ;
5. capacité vidéo : si `playableMediaTypes` est renseigné et non vide, il doit contenir `.video` ; s'il est absent, on garde (les clients anciens sous-déclarent).

Tri par nom d'appareil, insensible à la casse et aux diacritiques, puis par `id` de session — ordre **total**, donc stable d'un sondage à l'autre.

### La découverte ne bloque ni ne casse le rendu de la fiche

`loadRemoteTargets` part dans une `Task` détachée après le chargement principal, exactement comme `loadCollection` : `/Sessions` lent ou en échec ⇒ liste vide ⇒ pas de bouton, et la fiche s'affiche normalement. L'erreur est journalisée, jamais surfacée — un appareil cible absent n'est pas une erreur utilisateur.

### Le bouton n'existe que s'il y a une cible

Une session n'existe que si Jellyfin **tourne** sur l'appareil cible. En pratique il n'y a donc aucune cible la plupart du temps. Un bouton permanent menant à « aucun appareil » serait du bruit ; son apparition enseigne implicitement la précondition (« la TV est allumée, je peux envoyer »).

La feuille garde malgré tout un état vide : entre le sondage qui a fait apparaître le bouton et le tap, l'appareil peut s'être endormi.

### La feuille re-sonde à l'ouverture

Le sondage qui décide de l'affichage du bouton peut avoir plusieurs minutes. La feuille refait donc l'appel dans son propre `.task` — même schéma que `WatchTogetherSheet` avec sa liste de groupes. Deux appels, mais l'un décide d'un affichage et l'autre d'une action : celui qui déclenche un envoi doit être frais.

### Ce qui est envoyé est ce que Lecture aurait joué

`MediaDetailScreen.resolvedPlayTarget(for:)` est déjà la SSOT de « qu'est-ce qu'on lit » — le bouton Lecture et Siri passent par elle. L'envoi distant passe par la même, et gagne un `startTicks` (la position de reprise en ticks, sans conversion en secondes puis retour). Une série résout donc son épisode suivant, un film à moitié vu reprend, et la version choisie dans la rangée « Version » est transmise.

Le `mediaSourceId` n'est transmis que lorsque la cible de lecture est l'item lui-même : pour une série, la source appartiendrait au parent, pas à l'épisode.

## Interface

### iOS — une puce de plus dans la rangée d'actions secondaires

`tv.badge.wifi` dans la rangée existante (cœur, vu, bande-annonce). Délibérément **pas** le glyphe AirPlay : ce n'est pas de l'AirPlay, et le laisser croire serait mentir sur ce que le téléphone garde comme contrôles.

### tvOS — un bouton fantôme de plus dans la rangée d'action

Même traitement que cœur et vu (`CinemaTVButtonStyle(cinemaStyle: .ghost)`), après eux, avant le `Spacer`. Cas d'usage réel : déplacer un film d'une pièce à l'autre.

Le bouton s'insère après le chargement, en fin de rangée : Lecture garde le focus par défaut, donc l'insertion ne le vole pas.

### La feuille

iOS `.sheet`, tvOS `.fullScreenCover` — `.sheet` rend un modal étroit cassé sur tvOS 26. Reprend `WatchTogetherPresentation` comme modèle, y compris la ré-injection explicite des objets d'environnement.

Par ligne : nom d'appareil en corps de texte, sous-titre ` • `-joint entre le nom du client et ce qu'il lit déjà (« lit *Dune* » — prévient qu'on va interrompre quelque chose). Tap → envoi → toast → fermeture. Échec → toast d'erreur, la feuille reste ouverte.

## Clés de localisation

| Clé | fr | en |
|---|---|---|
| `remote.title` | Lire sur… | Play on… |
| `remote.sent` | Lecture lancée sur %@ | Started playing on %@ |
| `remote.unknownDevice` | Appareil inconnu | Unknown device |
| `remote.idle` | Prêt | Ready |
| `remote.nowPlaying` | lit %@ | playing %@ |
| `remote.noTargets.title` | Aucun appareil disponible | No device available |
| `remote.noTargets.subtitle` | Ouvre Jellyfin sur l'appareil cible : il doit être allumé et connecté au serveur pour apparaître ici. | Open Jellyfin on the target device — it has to be awake and connected to the server to show up here. |

## Vérification

- Tests unitaires sur `RemotePlayTarget.resolve` (chaque règle de filtrage, le tri, l'ordre total).
- Tests unitaires sur `MediaDetailViewModel.loadRemoteTargets` (peuplement, échec silencieux).
- Build iOS **et** tvOS (le lot 3 a montré qu'une déclaration enfermée dans un `#if os(iOS)` ne se voit qu'au build tvOS).
- Vérification simulateur : la fiche rend sans bouton quand aucune cible n'existe (le cas nominal sur une machine de dev).

**Limite de vérification, nommée d'avance** : sans deux appareils Jellyfin connectés simultanément au serveur, le chemin nominal — bouton visible, envoi, lecture qui démarre ailleurs — n'est couvert que par les tests unitaires. À valider à l'œil avec un vrai Apple TV allumé.
