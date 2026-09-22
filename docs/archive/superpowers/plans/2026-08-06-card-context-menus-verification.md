# Menus contextuels sur vignettes — vérifications à faire à la main

Ces six scénarios n'ont pas pu être exécutés pendant l'implémentation : ils
demandent un serveur Jellyfin connecté (et, pour le dernier, une lecture
réelle). Tout le reste — compilations iOS + tvOS, suite de 411 tests, parité
FR/EN, revue design system — est vert.

À faire avant de fusionner.

## iOS

1. **Lecture depuis une vignette.** Bibliothèque Films → appui long sur une
   affiche. Attendu : « Lecture » (ou « Reprendre » + « Lire depuis le début »
   sur un film à demi vu) en tête du menu ; le lecteur s'ouvre en plein écran ;
   **le fermer ramène sur la grille**, pas sur un écran intermédiaire.

2. **Rail Reprendre.** Accueil → appui long sur une carte « Reprendre ».
   Attendu : Reprendre + Lire depuis le début + Lire sur… + vu / favori /
   playlist, puis **« Retirer de Reprendre » en rouge, en dernier** — et le
   toucher retire bien la carte de la rangée.

3. **Non-régression « Lire sur… ».** Fiche d'un film → la puce « Lire sur… »
   du bloc d'actions secondaires. La feuille doit s'ouvrir exactement comme
   avant : ce lot a déplacé son hébergement de la fiche vers la racine.

4. **Aller à la série.** Appui long sur une carte d'**épisode** (Reprendre,
   Next Up, résultat de recherche, historique) → « Aller à la série » pousse la
   fiche de la série. Sur un film, et sur la grille bibliothèque, l'entrée doit
   être **absente**.

5. **Scénario PiP — la seule inconnue matérielle du lot.** Réglages → Lecture →
   activer **« Utiliser le lecteur natif »**. Lancer une lecture **depuis un
   menu contextuel** (pas depuis la fiche détail), déclencher le PiP, revenir à
   l'app. Deux branches à vérifier :
   - **restaurer** depuis la vignette PiP → le lecteur plein écran revient et la
     lecture continue au même endroit ;
   - **ne pas restaurer** → on doit pouvoir sortir de l'écran de chargement noir
     (« Préparation… ») par son bouton de fermeture. C'est l'échappatoire ajoutée
     par la vague de correctifs finale ; sans elle on restait coincé.

   Le moteur par défaut (VLC) n'expose pas cet état — c'est pourquoi il faut
   basculer le réglage pour l'exercer.

6. **Bonus, 20 secondes.** Lancer une lecture depuis une carte **à l'intérieur**
   de la feuille « Historique de visionnage » (Réglages → Compte). C'est la
   seule imbrication de présentation que ce lot crée : un `fullScreenCover`
   racine levé depuis une `.sheet`.

## tvOS

7. **Focus.** Parcourir l'accueil, appui long (select maintenu) sur une carte de
   chaque rangée. À la fermeture du menu, **le focus doit revenir sur la carte
   d'origine** — s'il saute sur la pastille d'onglet actif en haut, c'est qu'un
   menu a été accroché au label au lieu du bouton focusable. Les onze points
   d'accroche ont été vérifiés fonction par fonction en relecture, mais rien de
   tout cela n'est vérifiable par le compilateur.
