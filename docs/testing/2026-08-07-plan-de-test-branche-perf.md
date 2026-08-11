# Plan de test — branche `claude/perf-review-new-features-6mycej` (PR #109)

15 correctifs de performance/correction, aucun compilé localement pendant le
développement (session distante Linux sans toolchain Swift) — **la CI est verte**
sur `f6cf995` (Build & Test + SwiftLint + claude-review), donc ça compile et la
suite unitaire passe. Ce qui reste à valider est le **comportement**.

> **Comment t'en servir :** en session locale, donne-moi le chemin de ce fichier.
> Je peux exécuter §1 et §2 moi-même (build, tests, lancement simulateur,
> captures). §3 demande un vrai appareil ou un vrai serveur — je te dirai quoi
> observer, mais je ne peux pas le faire à ta place.

Légende priorité : **P0** = régression bloquante si ça casse · **P1** = important ·
**P2** = confort.

---

## 0. Préalables

```bash
cd <repo>
git fetch origin claude/perf-review-new-features-6mycej
git checkout claude/perf-review-new-features-6mycej
xcodegen generate          # aucun fichier ajouté sur cette branche, donc
                           # normalement un no-op — mais gratuit et sûr
```

**À savoir sur `project.pbxproj`** : le hook pre-commit garde le blob pristine, donc
`git status` l'affiche comme modifié en local. C'est le fonctionnement attendu, pas
un problème de cette branche.

**Réglages qui changent ce qui est testé** (Réglages → Lecture) :
- `Utiliser le lecteur natif` — **off par défaut** ⇒ moteur VLC. Plusieurs
  correctifs touchent **les deux** présentateurs : il faut passer §2.A dans les
  deux positions.
- Section « Débogage » : `debug.fastSleepTimer` (minuterie → 15 s),
  `debug.showSkipToEnd` (bouton qui saute à `durée − 15 s`) — très utiles pour
  atteindre les fins de lecture rapidement.

---

## 1. Automatisé — ce que je lance en premier

**RULE — ne pas paralléliser iOS et tvOS** (course sur `build.db`), et **toujours**
`set -o pipefail` (sans lui, un build en échec renvoie 0).

```bash
# Build iOS
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | tail -5

# Build tvOS (séquentiellement, pas en parallèle)
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' | tail -5

# Tests unitaires
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tee /tmp/tests.log | tail -20
```

**RULE — `-only-testing` exécute silencieusement 0 test swift-testing.** Lancer la
suite complète et vérifier la présence des suites :

```bash
grep -E 'Suite "(CardPlayTarget|PaginatedLoader|Episode navigation|MediaLibraryViewModel load resilience|FavoritesViewModel|WatchedHistoryViewModel)"' /tmp/tests.log
grep -c '✔' /tmp/tests.log      # doit être non nul
grep -E '✘|failed' /tmp/tests.log
```

Tests **nouveaux** sur cette branche, à voir passer nommément :
- `CardPlayTarget` → « Le délai est réellement appliqué… » ← **échouait avant** le
  correctif F-48 ; c'est le test qui prouve que le délai de 1,5 s est appliqué.
- `CardPlayTarget` → « Le sondage perdant continue en fond… » (F-54).
- `PaginatedLoader` → 5 cas `refreshLoadedSpan` (F-49).
- `Episode navigation` → « navigator resolves a target's neighbours… » (F-6, réécrit).

---

## 2. Simulateur — je peux tout faire ici

### 2.A · Lecteur (P0) — à passer **deux fois** : VLC puis lecteur natif

| # | Vérification | Attendu | Garde le correctif |
|---|---|---|---|
| A1 | Lancer une lecture. Laisser le HUD s'auto-masquer (4 s). Le rappeler (tap iOS / une pression tvOS). | Les compteurs affichent la position **courante**, pas celle d'avant le masquage. Barre de progression cohérente. | **F-4** — le gate saute les peintures HUD masqué ; `showControls()` doit rattraper. |
| A2 | HUD visible, regarder défiler 10 s. | Le temps avance chaque seconde, sans saut ni gel. | F-4 (cache par seconde). |
| A3 | Scrub (glissement) puis relâcher. | Labels suivent le doigt ; à la relâche la barre **tient la cible** sans revenir en arrière. | F-4 — `writeTimeLabels` + `pendingScrubTargetMs` hors du gate. |
| A4 | ±10 s à répétition (boutons iOS / clickpad tvOS), y compris **HUD masqué**. | Un seul saut, position projetée affichée dès le rappel du HUD. | F-4 + coalescence de seek existante. |
| A5 | Série : Suivant / Précédent dans le lecteur, plusieurs fois. | Épisode change, titre à jour, boutons prev/next mis à jour, pas de gel. | **F-6** — navigator rendu pur, chaque présentateur négocie. |
| A6 | Laisser un épisode aller au bout avec autoplay activé. | L'épisode suivant démarre. | F-6 (chemin autoplay). |
| A7 | Fin de la dernière saison. | Carte « Vous avez terminé … ». | F-6 (non-régression). |
| A8 | Ouvrir la bande de chapitres. | Vignettes présentes (peuvent arriver **après** le début de la lecture — c'est voulu). | **F-5** — lot différé. |
| A9 | Mettre l'app en arrière-plan pendant la lecture, attendre ~30 s, revenir. | Lecture reprend **et les vignettes de chapitres sont toujours là**. | **F-5, le bug que j'avais introduit** : ce chemin ne relance pas `fetchChapters`. |
| A10 | Minuterie de sommeil (avec `debug.fastSleepTimer`). | Pause + « Toujours là ? » à 15 s. | Non-régression (F-27 non traité). |

### 2.B · Menus contextuels de vignettes (P0) — la plus grosse surface refactorée

Le menu a été entièrement déplacé dans de nouveaux types de vue. **Passer les neuf
surfaces** : grille bibliothèque, rangées de genre, résultats de recherche,
historique, favoris, filmographie d'acteur, titres similaires, et les rails Home
(Reprendre, Next Up, Ajouts récents, Favoris, genres).

| # | Vérification | Attendu | Garde |
|---|---|---|---|
| B1 | Appui long sur une vignette de chaque surface. | Le menu s'ouvre, **toutes** les entrées attendues présentes, aucune entrée morte. | **F-46/F-47** (refactor complet). |
| B2 | iOS : regarder l'aperçu soulevé. | **La jaquette seule** — pas le titre/sous-titre flottants. Poster 2:3 sur les grilles, **backdrop 16:9** sur Reprendre et Next Up. | F-46 (aperçu déplacé dans sa propre vue). |
| B3 | L'aperçu s'affiche-t-il instantanément (image déjà en cache) ? | Pas de blanc d'une seconde. | F-46 — l'URL doit rester byte-identique à celle de la carte. |
| B4 | Menu → Lecture / Reprendre, et « Lire depuis le début ». | Démarre au bon endroit. | F-46 + F-55. |
| B5 | Menu sur une vignette d'**épisode** → « Aller à la série ». | Pousse la fiche série. | F-46 (callback conservé). |
| B6 | Menu → vu / favori / ajouter à une playlist. | Toast, état reflété à la réouverture du menu. | F-46/F-52. |
| B7 | Home → Reprendre → menu → « Retirer de la reprise ». | La carte disparaît. | F-46 (entrée conditionnelle). |
| B8 | **Le scénario clé F-52** : marquer vu depuis une vignette → ouvrir la fiche de l'item → marquer **non vu** → revenir → réouvrir le menu de la vignette. | Le menu dit **« Marquer comme vu »** (vérité serveur), **pas** « Retirer des vus ». | **F-52** — c'était le bug : l'override masquait le serveur. |
| B9 | Sur un serveur sans autre session Jellyfin ouverte : entrée « Lire sur… ». | Peut apparaître (optimiste) ; l'ouvrir montre l'état vide `remote.noTargets`. | F-47 (lecture du compteur déplacée). |

### 2.C · Pagination et grilles (P0)

Nécessite **plus de 40 favoris** et plus de 40 items dans l'historique.

| # | Vérification | Attendu | Garde |
|---|---|---|---|
| C1 | Favoris : défiler profond (page 3+), puis appui long sur une carte → marquer vu. | **La grille ne remonte PAS en haut.** Position de scroll conservée. | **F-49** — la régression la plus visible. |
| C2 | Idem depuis l'Historique. | Idem. | F-49. |
| C3 | Favoris : retirer le cœur d'une carte visible. | La carte disparaît, sans saut de scroll. | F-49 (`hasLoadedAll` re-dérivé). |
| C4 | Favoris : pull-to-refresh. | Retour page 0 — **c'est voulu ici**, c'est une demande explicite. | F-49 (la scission `load()` / `refresh()`). |
| C5 | Bibliothèque, filtre actif (grille plate) : défiler pour charger plusieurs pages. | Pagination normale. | Non-régression `PaginatedLoader` (partagé). |
| C6 | Bibliothèque : marquer vu 2-3 cartes **rapidement** d'affilée. | La grille se stabilise correctement, pas de contenu dupliqué ni de rangées incohérentes. | **F-53** — coalescence des rechargements (le drain en boucle). |
| C7 | Réglages → Serveur → « Rafraîchir le catalogue ». | Home et bibliothèques rechargent. | F-53 (non-régression). |
| C8 | Bibliothèque : pull-to-refresh, puis Retry après une erreur. | Rechargement propre. | F-53. |

### 2.D · Recherche (P1)

| # | Vérification | Attendu | Garde |
|---|---|---|---|
| D1 | Taper une requête lettre par lettre. | Résultats se mettent à jour normalement, pas de gel. | **F-50** (`Equatable`). |
| D2 | Chips Tous / Films / Séries. | Filtrage correct. | F-50 (non-régression). |
| D3 | Requête donnant des personnes (nom d'acteur). | Rangée « Personnes » ronde au-dessus de la grille. | Non-régression. |
| D4 | **Scénario du 2ᵉ défaut trouvé en relecture** : marquer un item vu depuis sa fiche, revenir à la recherche, relancer **la même** requête, ouvrir le menu de sa vignette. | Le menu reflète l'état **vu**. | F-50 — le `==` de la grille devait être aussi fin que celui de la carte. |
| D5 | tvOS : recherche large, regarder le poster focalisé en bord de grille. | *Connu non corrigé* : le poster peut être rogné (F-1, non traité). Ne pas le compter comme régression. | — |

### 2.E · Non-régressions autour du code partagé touché

| # | Vérification | Attendu |
|---|---|---|
| E1 | Home : cartes Reprendre et Next Up → lancer la lecture → boutons prev/next présents dans le lecteur. | Présents (les cartes portent la nav d'épisode). |
| E2 | Fiche série : sélectionner une autre saison, marquer la saison vue. | Épisodes à jour. |
| E3 | Fiche film multi-versions : rangée « Version ». | Choix respecté à la lecture. |
| E4 | Changer de serveur, puis revenir. | Onglets et contenus corrects, pas d'écran noir. |
| E5 | Basculer Réglages → Lecture → `Utiliser le lecteur natif`, relancer une lecture. | Le moteur change, lecture OK. |

---

## 3. Hors simulateur — je ne peux pas valider, à faire sur matériel/serveur réel

Je les liste pour que tu saches ce qui **reste non couvert** après §1–§2.

| # | Vérification | Pourquoi le simulateur ne suffit pas |
|---|---|---|
| H1 | **Le gain de F-4** (temps main-thread pendant un décodage 4K). | Le simulateur n'a pas de décodeur HEVC/DV matériel ; le bénéfice n'est mesurable que sur Apple TV A15. Le *comportement* est couvert par A1-A4. |
| H2 | **F-26** — aperçus de scrub trickplay fluides. | Demande un serveur ayant généré le trickplay. |
| H3 | **F-28** — réveil sur un item **transcodé** : un seul job ffmpeg côté serveur. | Demande d'observer le serveur (`htop`/dashboard Jellyfin) pendant un background/foreground. C'est le correctif dont le symptôme est « le nouveau flux saccade au réveil ». |
| H4 | **F-5** — gain sur le temps-jusqu'à-première-image. | Ne se voit que sur serveur auto-hébergé / reverse-proxy lent. |
| H5 | **F-48** — sur serveur lent/injoignable, appui sur Lecture depuis une vignette de **série**. | Ne doit pas attendre plus de ~1,5 s avant de démarrer. Demande un serveur volontairement lent. Couvert par les tests unitaires côté logique. |
| H6 | PiP iOS, AirPlay. | Indisponibles en simulateur. |
| H7 | Widget iOS / Top Shelf tvOS. | *Connu non corrigé* : F-7 (posters en série) reste ouvert — un widget lent sur serveur distant est **attendu**, pas une régression de cette branche. |

---

## 4. Attendu **non** corrigé — ne pas remonter comme régression

Ces constats sont identifiés et documentés dans
`docs/audits/2026-08-05-perf-et-nouveautes.md`, mais **pas** traités ici :

- **F-51** — un toggle vu/favori déclenche encore plusieurs rechargements en
  arrière-plan (jusqu'à ~25 requêtes). Le symptôme visible (retour page 1) est
  corrigé par F-49 ; le volume de requêtes reste. Décision en attente.
- **F-1** — recherche tvOS : `ScrollView` imbriqué, poster focalisé rogné en bord
  de grille, pic mémoire sur requête large.
- **F-2 / F-3** — couleurs d'accent recalculées à chaque lecture ; accent
  arc-en-ciel qui re-diffuse tout l'arbre à 10 Hz.
- **F-7** — widget iOS : posters téléchargés en série.
- **F-8 / F-9** — `getItems` sans cache ; tier-2 qui relance le fan-out complet en
  bibliothèque.
- **F-5 côté natif** — le `ChapterController` du lecteur natif garde son
  `withTaskGroup` non borné et tout-ou-rien (seul le chemin VLC est corrigé).

---

## 5. Check-list compacte (à me renvoyer annotée)

```
[ ] 1  Build iOS · Build tvOS · Tests (suites présentes, 0 échec)
[ ] A1 HUD rappelé après auto-masquage → position courante        (VLC / natif)
[ ] A2 Compteur défile 1×/s sans gel                              (VLC / natif)
[ ] A3 Scrub → tient la cible, pas de retour arrière              (VLC / natif)
[ ] A4 ±10 s en rafale, dont HUD masqué                           (VLC / natif)
[ ] A5 Suivant / Précédent épisode                                (VLC / natif)
[ ] A6 Autoplay épisode suivant                                   (VLC / natif)
[ ] A7 Carte fin de série                                         (VLC / natif)
[ ] A8 Vignettes de chapitres présentes
[ ] A9 Background→foreground : lecture reprend ET vignettes encore là
[ ] A10 Minuterie de sommeil
[ ] B1 Menu sur les 9 surfaces, aucune entrée morte
[ ] B2 Aperçu iOS = jaquette seule, bonne forme (poster vs backdrop)
[ ] B3 Aperçu instantané (pas de blanc)
[ ] B4 Lecture / Reprendre / Depuis le début
[ ] B5 Aller à la série (épisode)
[ ] B6 vu / favori / playlist
[ ] B7 Retirer de la reprise
[ ] B8 ★ vu depuis vignette → non vu depuis fiche → menu dit « Marquer comme vu »
[ ] B9 Lire sur… (état vide correct)
[ ] C1 ★ Favoris page 3+ → toggle → PAS de remontée en haut
[ ] C2 ★ Idem Historique
[ ] C3 Retrait de cœur → carte disparaît sans saut
[ ] C4 Pull-to-refresh → page 0 (voulu)
[ ] C5 Pagination grille filtrée bibliothèque
[ ] C6 ★ 2-3 toggles rapides → grille stable
[ ] C7 Rafraîchir le catalogue
[ ] C8 Pull-to-refresh + Retry bibliothèque
[ ] D1 Frappe → résultats à jour
[ ] D2 Chips de scope
[ ] D3 Rangée Personnes
[ ] D4 ★ Même requête relancée → état vu à jour dans le menu
[ ] E1 prev/next depuis les rails Home
[ ] E2 Saison / marquer saison vue
[ ] E3 Rangée Version
[ ] E4 Changement de serveur
[ ] E5 Bascule lecteur natif
```

Les ★ sont les scénarios qui ciblent directement un bug corrigé : si un seul doit
être fait, ce sont ceux-là.
