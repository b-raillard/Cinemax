# Lecteur en posture « table » sur l'iPhone Duo — conception

Date : 2026-10-07 · Statut : à valider · Maquette validée : variante A « Pupitre »,
canevas « Lecteur iPhone Duo » (artefact claude.ai, planches `Pupitre` et `StatsHaut`).

## Objectif

Quand l'iPhone Duo est à moitié replié en portrait (posé « en table », comme un
ordinateur portable), le lecteur actuel est mal placé : la vidéo, centrée sur
tout l'écran, est coupée par le pli, et les boutons du haut se retrouvent sur la
moitié relevée, sous la caméra. Le mode « table » met la vidéo sur l'écran du
haut et les commandes sur une dalle de blocs dans l'écran du bas, sur le modèle
de ce que fait Netflix sur ce format.

**Contrainte : rien ne change ailleurs.** Duo ouvert à plat, Duo fermé, Duo plié
en paysage, iPhone, iPad, Apple TV : lecteur actuel, à l'identique.

## Déclenchement

- `UIHingeInteraction` (UIKit, **iOS 27.1+**, `#available` — l'app cible iOS 26)
  ajoutée à la vue de `VLCStreamPresenter`.
- Mode « table » ⇔ `hinge.status == .partiallyOpen` **et** vue du lecteur plus
  haute que large. Tout autre état (`closed`, `fullyOpen`, `unknown`, `hinge ==
  nil`) ⇒ lecteur actuel.
- Décision pure, testée : `PlayerPostureLayout.mode(hingeStatus:viewSize:) ->
  .regular | .tabletop` (nouveau fichier sous `Shared/Screens/VideoPlayer/`).
- Bascule à chaud, sans interrompre la lecture, animée (0,3 s).

Mesures au simulateur du Duo (2026-10-07, sonde jetable) : les mises à jour
arrivent en continu pendant le mouvement ; `fullyOpen` à 180°, `partiallyOpen`
d'environ 174° à 92°, `closed` sous ~60°. Au moment où le lecteur est présenté,
une première mise à jour `hinge == nil` précède l'état réel : elle ne doit pas
provoquer de bascule visible (ignorer `nil` tant qu'aucun état n'est connu).

## Mise en page « table »

Le pli est au milieu de la hauteur de la vue (l'API ne donne pas sa position ;
le lecteur est plein écran, donc milieu = pli).

**Écran du haut**
- Vidéo ajustée en largeur, centrée verticalement dans la moitié haute.
- Encart « Statistiques » (si activé) dans la bande noire au-dessus de l'image,
  à gauche (la caméra et l'état système sont en haut à droite), en deux colonnes
  + ligne « Modules » ; non interactif, reste affiché quand la dalle se masque.
- « Passer l'intro / le générique », la carte « Épisode suivant », la bande de
  présence « Regarder ensemble » et les messages d'erreur restent sur l'écran
  du haut (coin bas droit de la moitié haute pour les deux premiers).

**Écran du bas : la dalle**
1. Barre du film : bloc cadenas · bloc titre (vignette, titre, année · durée ·
   définition, chevron) · bloc « Terminé ». La définition (« 4K », « 1080p »,
   « 720p », « SD ») est lue sur la piste vidéo en lecture, sans requête.
2. Lecture : −10 s · lecture/pause (bloc large) · +10 s ; sur une série, épisode
   précédent / suivant aux extrémités quand ils existent (même règle qu'aujourd'hui).
3. Curseur : temps écoulé · barre (couleur d'accent) · temps restant ; l'aperçu
   Trickplay pendant le glissement, comme aujourd'hui.
4. Réglages : Sous-titres, Audio, Vitesse (chacun affiche sa valeur), Chapitres
   (si > 1 chapitre), Image dans l'image.

Un réglage ouvre sa liste **dans la dalle** (à la place des rangées 2–4) ; la
vidéo continue au-dessus. Le bloc titre ouvre un menu contenant
« Statistiques » (bascule de l'encart du haut) — le bouton n'a pas d'autre place.

Les actions sont celles du HUD actuel (mêmes sélecteurs, mêmes pickers, mêmes
libellés VoiceOver via `PlayerHUDAccessibility`) : la dalle est une autre
présentation, pas une autre logique.

## Masquage et cadenas

- Cadenas **ouvert** (défaut) : la dalle se masque après le délai actuel du HUD
  (4 s sans interaction) ; icône en couleur d'accent.
- Cadenas **fermé** : la dalle reste affichée — ni masquage au délai, ni
  masquage au toucher (seul le cadenas décide) ; icône blanche, bloc en teinte
  normale (pas de surface d'accent qui éblouirait en permanence).
- Une liste ouverte suspend le masquage.
- Toucher la vidéo ou l'écran du bas réaffiche la dalle ; cadenas ouvert, un
  toucher la masque aussi.
- État du cadenas **mémorisé** : nouvelle clé `SettingsKey.playerTabletopHUDLocked`
  (`Bool`, défaut `false`), à ajouter au tableau des clés de
  `Shared/Screens/Settings/CLAUDE.md`. Pas d'entrée dans Réglages.

## Fond et halo

- Fond de la dalle `#0B0B0B` quand elle est affichée, **noir pur** quand elle est
  masquée (fondu 0,45 s).
- Halo : reflet de la vidéo sous le pli, identique dalle affichée ou masquée
  (opacité ~0,38, retourné, flou ~7 pt, fondu vers le bas sur ~80 %), visible
  à travers les blocs translucides.
- Source du halo : **miroir en direct**. La couche de la vue vidéo devient un
  `CAReplicatorLayer` : une seule instance hors mode table (coût nul), deux en
  mode table, la seconde retournée sous le pli et recomposée à chaque image par
  le serveur d'affichage ; un flou natif (`UIVisualEffectView`) et un dégradé
  vers le noir la voilent. Sonde du 2026-10-07 au simulateur du Duo : l'image
  libVLC est bien recopiée. **Écartés** : `Player.takeSnapshot` (libVLC) —
  « Failed to convert image for snapshot » sur les images décodées en matériel,
  et 40 à 380 ms de blocage du fil principal ; la capture `drawHierarchy`
  périodique (~4 ms, mais un reflet qui saute toutes les 2 s), gardée seulement
  pour la vignette du bloc titre, prise quand la dalle apparaît.
- En pause, le reflet montre l'image en pause, comme la vidéo.

## Localisation

Nouvelles clés FR/EN/DE : libellés VoiceOver du cadenas (ouvert / fermé), titre
du menu de la barre du film. Les autres textes réutilisent les clés existantes
(`player.stats`, `player.subtitles`, `player.audio`, `player.speed`…).

## Fichiers

- `Shared/Screens/VideoPlayer/PlayerPostureLayout.swift` — décision pure (nouveau).
- `Shared/Screens/VideoPlayer/TabletopDeckView.swift` — la dalle UIKit (nouveau),
  pilotée par `VLCStreamPresenter` via des fermetures, sans état de lecture propre.
- `Shared/Screens/VideoPlayer/TabletopHalo.swift` — miroir (`MirroringVideoView`), voile du halo, vignette (nouveau).
- `VLCStreamPresenter.swift` — interaction charnière, bascule des contraintes de
  la vue vidéo et du HUD, branchement des actions.
- Nouveaux fichiers ⇒ `xcodegen generate`.
- iOS uniquement (`#if os(iOS)`) ; tvOS ne compile rien de tout cela.

## Tests et vérification

- Unitaires : `PlayerPostureLayout` (chaque statut × portrait/paysage, `nil`,
  `unknown`), règle du masquage (cadenas, liste ouverte).
- Simulateur Duo (compte démo) : bascule ouvert → plié → fermé → plié en cours
  de lecture ; lecture continue, aucune image figée ; captures des deux états de
  la dalle et de l'encart Statistiques.
- Non-régression : iPhone 17 Pro portrait/paysage, iPad, Duo ouvert et fermé —
  lecteur identique.
- Halo : 2 minutes de lecture au simulateur du Duo sans à-coup (le mode table n'existe que sur le Duo).

## Hors périmètre

- Duo plié en paysage (posture « livre ») : lecteur actuel.
- Duo fermé en paysage — marge droite du HUD : correctif séparé, sur la branche
  du Duo fermé (PR #294).
- Statistiques réservées au mode debug : non (décision du 2026-10-07, elles
  restent accessibles à tous).
