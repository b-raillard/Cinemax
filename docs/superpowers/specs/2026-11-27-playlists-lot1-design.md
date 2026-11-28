# Playlists, lot 1 — conception

Date : 2026-11-27. Maquettes : https://claude.ai/artifact/5yaojQ4CZiskMFgLUp9ES6 (source `_artifacts/playlists-2026-11-27/playlists.html` du checkout principal).

## Pourquoi

Une playlist ne se remplit qu'un titre à la fois, depuis la fiche de chaque film ; sa page ne sait qu'ordonner et retirer. Le propriétaire la juge « pas pratique » et veut pouvoir ajouter des titres depuis la playlist.

## Objectifs

1. **Ajouter des titres depuis la playlist** : sélecteur avec recherche, filtres, sélection multiple **numérotée** (l'ordre des appuis est l'ordre d'ajout), un seul envoi.
2. **Lignes enrichies** : vu, progression, durée, numéro d'épisode.
3. **Feuille « Ajouter à une playlist »** : couverture de chaque playlist, coche si le titre y est déjà, un appui ajoute ou retire, la feuille reste ouverte.
4. **Apple TV** : actions dans l'en-tête de la page et mode « Trier ».
5. **iPad / Duo ouvert** : deux volets (playlist à gauche, contenu à droite).
6. **Série repliée** : les épisodes d'une même série qui se suivent tiennent sur une ligne.
7. **Annuler un retrait** (iOS) et **« Retirer les titres vus »**.
8. Le bouton « Ordonner » devient **« Trier »** ; hors Apple TV le tri reste le glisser-déposer natif par les trois barres (celui de Réglages → Menu principal).

## Hors périmètre

Lire la playlist à la suite / aléatoire (lot 2, demande un essai), playlists dans la recherche, partage, « Masquer de l'accueil ». Pas de seconde file de lecture.

## Approches

- **A — tout dans la page existante (retenue).** `PlaylistDetailScreen` garde sa `List` native (seule source du glisser natif) ; la logique nouvelle va dans des types purs testés. Le sélecteur est un écran à part présenté par la page.
- **B — réutiliser `MediaLibraryScreen` comme sélecteur.** Écartée : c'est une grille de navigation (héros, genres, zoom de carte), pas de sélection ; la plier coûterait plus que d'écrire une grille simple.
- **C — réécrire la page en `ScrollView` + glisser maison.** Écartée : `.onMove` avec la poignée système n'existe que dans `List`.

## Décisions (les miennes, à corriger si besoin)

- **Gratuit.** Les playlists le sont déjà ; rien ici ne passe en Pro.
- **Regroupement** : 3 épisodes consécutifs ou plus de la même série forment une ligne « Série · N épisodes », dépliable. Affichage seulement : le serveur garde les épisodes. En mode « Trier » la liste est à plat (chaque épisode se déplace). Retirer une ligne repliée retire tous ses épisodes en une requête, après confirmation.
- **Sélecteur** : quatre filtres (Récents, Films, Séries, Favoris) + recherche. Un titre déjà dans la playlist est marqué et non sélectionnable ; une série dont des épisodes y sont déjà reste sélectionnable, avec la mention. Une série annonce qu'elle ajoute tous ses épisodes.
- **Feuille d'ajout** : l'appartenance se lit par `getPlaylistItems` de chaque playlist, en parallèle (Jellyfin n'a pas de « playlists contenant ce titre »). Tant qu'elle n'est pas connue, la ligne propose l'ajout. Retirer = toutes les entrées de ce titre (ou de cette série) dans la playlist.
- **Annuler** : ré-ajoute le titre puis le remet à sa place ; iOS seulement (un message n'a pas de bouton sur Apple TV). Pas d'annulation pour une ligne repliée ni pour « Retirer les titres vus », qui demandent une confirmation à la place.
- **Apple TV, mode « Trier »** : chaque ligne porte trois boutons (monter, descendre, retirer). La première idée — un clic saisit la ligne, haut / bas la déplacent — a été construite puis abandonnée après mesure au simulateur : une pression sur trois seulement déplaçait la ligne. « Monter » / « Descendre » restent aussi dans le menu de l'appui long.
- **Deux volets** dès que la largeur est « regular » (iPad, Duo ouvert s'il la rapporte — NON vérifié au simulateur Duo). Sur iPad, « Trier » et les options sont dans le volet gauche : la barre du haut les repliait dans un seul « … ».

## Contraintes reprises de `docs/rules/playlists.md`

Entrées adressées par `playlistItemID` ; présentation hors des conteneurs paresseux ; `Trier` localisé (jamais l'`EditButton` système) ; pas de `didSet` sur un `@Observable` ; chrome unique des couvertures plein écran tvOS ; `canDelete` garde renommer / supprimer.

## Laissé au constructeur

Découpage en fichiers, noms, détails de mise en page tant que les maquettes sont respectées.
