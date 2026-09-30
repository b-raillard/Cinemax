# Licence du code public : GPL-3.0-or-later

Date : 2026-09-30. Statut : décidé.

## Décision

Le dépôt public porte désormais un fichier `LICENSE` à la racine : le texte intégral de la **GNU GPL, version 3**, tel que publié par la FSF (<https://www.gnu.org/licenses/gpl-3.0.txt>, non retapé). Le code est distribué sous **GPL-3.0-or-later** (« version 3 ou, à votre choix, toute version ultérieure »). Jusqu'ici le dépôt n'avait aucune licence : le code était visible, mais juridiquement « tous droits réservés ».

L'application le dit elle-même : la notice LGPL de libVLC (`Shared/Screens/LicensesView.swift`) gagne une phrase indiquant que l'app est publiée sous GPL-3.0-or-later, sans rien retirer de l'existant.

## Pourquoi la GPL-3

- **Elle protège d'un clone payant.** Une licence permissive (MIT, Apache-2.0) permettrait à n'importe qui de republier l'app, éventuellement payante, sans rien rendre. Avec la GPL-3, un dérivé distribué doit publier son code sous la même licence : le travail reste commun.
- **Elle satisfait la LGPL de libVLC.** libVLC (LGPL-2.1-or-later) est lié en **statique** dans le binaire (xcframework SwiftVLC). La LGPL-2.1 §6 exige alors que l'utilisateur puisse relier l'app à une version modifiée de la bibliothèque, ce que la publication du code source complet permet — c'est ce que dit la notice de `LicensesView`. Encore fallait-il que ce code soit effectivement réutilisable : sans licence, il ne l'était pas.
- **Elle est cohérente avec la fiche App Store**, qui déclare l'app « Open source ». Sans licence, l'affirmation était fausse au sens strict.
- **Elle est compatible avec toutes les dépendances** : LGPL-2.1+ (libVLC), MPL-2.0 (jellyfin-sdk-swift), MIT (Nuke, SwiftVLC…), Apache-2.0 (swift-nio et consorts), OFL (polices). La **GPL-2 ne le serait pas** : Apache-2.0 est incompatible avec la GPL-2 seule.

## Pourquoi « or-later »

- Une future version de la GPL pourra être adoptée sans avoir à retrouver chaque contributeur.
- C'est la forme qui reste compatible avec le « or-later » de la LGPL-2.1 de libVLC et avec les autres projets GPL-3+.

## Point d'attention pour plus tard : les contributions externes

La GPL-3 et les conditions d'utilisation de l'App Store (restrictions de DRM et d'usage imposées au binaire) sont notoirement difficiles à concilier pour un code dont **plusieurs** titulaires de droits détiennent une part. Aujourd'hui l'auteur est le **seul** titulaire des droits : il distribue son propre code sur l'App Store sous les conditions qu'il choisit, la GPL ne s'appliquant qu'aux tiers. Il n'a besoin d'aucune autorisation.

Dès qu'une contribution externe sera acceptée, elle devra **accorder explicitement la permission de distribution via l'App Store** (un contributor agreement, ou une exception App Store ajoutée à la licence pour les contributions). À poser **avant** de merger la première PR externe, pas après.

## Hors périmètre

- Pas d'en-têtes SPDX dans chaque fichier source : le `LICENSE` racine suffit.
- Le README est traité ailleurs.
- `LICENSE` n'est balayé par aucun chemin `sources` de `project.yml` (la racine n'en est pas un) : il ne finit pas dans le bundle.
