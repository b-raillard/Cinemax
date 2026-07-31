# Réorganisation de l'arborescence des Réglages

**Date** : 2026-07-31 · **Statut** : validé par Bastien (proposition recommandée, défauts acceptés)

## Objectif

Ranger les réglages par question utilisateur unique, corriger les quatre incohérences
identifiées, sans toucher ni aux clés `@AppStorage` ni au comportement d'aucun réglage.
Pure réorganisation du rendu — aucune migration de données.

## Arborescence cible

```
Réglages
├── Apparence        Mode sombre · Accent · Langue · Effets de mouvement · Taille du texte
├── Interface  (hub) une sous-page par écran configurable
│   ├── Menu principal    (inchangé)
│   ├── Page d'accueil    (inchangé)
│   ├── Bibliothèque      ← Disposition (depuis Apparence) + [tvOS] Estomper les affiches
│   └── Page de détail    (inchangé)
├── Lecture          ← promue au 1er niveau (depuis Interface)
│                    Rendu 4K · Enchaîner les épisodes · Lecteur natif
│                    · [iOS] Activité en direct · Minuteur de veille
│                    + section « Débogage » en bas (orange, depuis Interface → Débogage)
├── Compte           (inchangé)
├── Serveur          Carte serveur · [tvOS] Actualiser la connexion
│                    · Actualiser le catalogue · Serveurs      (− Licences)
├── [admin, iOS]     Administration · Admin avancée (inchangés)
└── (pied du landing) Licences open source  ← depuis Serveur
```

Ordre des catégories (= ordre de déclaration de l'enum) : Apparence · Interface ·
Lecture · Compte · Serveur · Administration · Admin avancée. Apparence reste première
(pastille héro accentuée sur le landing iOS, `isFirst = category == .appearance`).

## Invariants (ne changent PAS)

- Toutes les clés `@AppStorage` (`SettingsKey`) et leurs valeurs — zéro migration.
- Les catalogues SSOT de rows sur `SettingsScreen` (`playbackToggleRows`,
  `homePageToggleRows`, `detailPageToggleRows`, `debugToggleRows`) — seuls leurs
  sites de rendu bougent.
- `SettingsNavCoordinator` (mêmes deux niveaux de navigation hoistés).
- Le freeze tvOS de `MainTabView` (`selectedInterfaceSub == .menu`) — le cas `.menu`
  survit tel quel.
- Compte, Confidentialité & sécurité, MenuSettingsScreen, écrans Admin, mécanisme de
  présentation des sheets (`showLicenses` reste un `@State` de `SettingsScreen` avec
  la `.sheet` au niveau du `body` partagé).
- Gating admin (`visibleCases(isAdmin:isTVOS:)`) — `.playback` n'est pas admin-only
  et existe sur les deux plateformes.

## Changements détaillés

### 1. Enums — `SettingsScreen.swift`

- `SettingsCategory` : nouveau cas `.playback` déclaré entre `.interface` et
  `.account`. Icône `"play.rectangle"` (récupérée de `InterfaceSubcategory.playback`),
  label `loc.localized("settings.playback")`. `isAdminOnly` = false (défaut existant).
- `InterfaceSubcategory` : cases `menu, homePage, library, detailPage` (dans cet
  ordre). `.playback` et `.debug` supprimés. `.library` : icône `"books.vertical"`
  (PAS `"square.grid.2x2"`, conservée par la row Disposition à l'intérieur), label
  `loc.localized("settings.interface.library")`.

### 2. iOS — `SettingsScreen+iOS.swift`

- `settingsDetailView(for:)` : nouveau `case .playback:` → `iOSPlaybackDetail` =
  - panneau glass 1 : contenu actuel de `iOSPlaybackSection` (toggles + divider +
    `iOSSleepTimerRow`) ;
  - `iOSSettingsSectionHeader(loc.localized("settings.debug"))` + panneau glass 2 :
    `debugToggleRows` (le tint orange est déjà porté par le catalogue).
  `iOSPlaybackSection`/`iOSDebugSection` sont absorbées/renommées — plus de cases
  `.playback`/`.debug` dans `iOSInterfaceSubDetailView`.
- `iOSInterfaceSubDetailView(for:)` : nouveau `case .library:` → `iOSLibrarySection` =
  panneau glass avec la row Disposition déplacée verbatim depuis
  `IOSAppearanceDetailView` (label sur sa ligne + contrôle deux boutons pleine
  largeur). Elle lit le `@AppStorage libraryBrowseLayout` déjà déclaré sur
  `SettingsScreen` (ligne existante) ; les helpers `libraryLayoutPicker`/
  `libraryLayoutButton` migrent dans l'extension iOS de `SettingsScreen`.
- `iOSServerDetail` : suppression du panneau Licences.
- Landing (`iOSLayout`) : sous `iOSDeviceInfo`, bouton discret
  « Licences open source » (`CinemaFont.label(.medium)`, `onSurfaceVariant`, centré,
  `.buttonStyle(.plain)`) → `showLicenses = true`.

### 3. iOS — `SettingsAppearanceView+iOS.swift`

- Suppression de la row Disposition bibliothèque + son divider + les helpers
  `libraryLayoutPicker`/`libraryLayoutButton` + le `@AppStorage libraryBrowseLayout`
  privé (dupliqué, devenu inutile ici).

### 4. tvOS — `SettingsScreen+tvOS.swift`

- `tvDetailView(for:)` : nouveau `case .playback:` → `tvPlaybackDetail` =
  `tvToggleList(playbackToggleRows)` + `tvSleepTimerRow` +
  `tvSectionLabel(loc.localized("settings.debug"))` (padding top `spacing4`) +
  `tvToggleList(debugToggleRows)`.
- `tvAppearanceDetail` : suppression de `tvLibraryLayoutRow` et du `tvGlassToggle`
  Estomper les affiches. Les deux migrent dans `tvLibrarySection`.
- `tvInterfaceSubDetailView(for:)` : switch réduit à `menu, homePage, library,
  detailPage` ; `case .library:` → `tvLibrarySection` = `tvLibraryLayoutRow` +
  `tvGlassToggle(dimUnfocusedPosters)`. `tvPlaybackSection`/`tvDebugSection`
  supprimées (contenu absorbé par `tvPlaybackDetail`).
- `tvServerDetail` : suppression de l'appel `tvLicensesButton`.
- Landing (`tvNavigationPanel`) : `tvLicensesButton` (le var existant, un
  `tvActionRow` id `"licenses"`, focus `.toggle("licenses")` déjà câblé) déplacé
  sous `tvSystemInfoBar`, même padding horizontal `spacing10` + padding bottom.
  Focus : atteint en descendant depuis la dernière pastille de catégorie — aucun
  `.focusSection()` requis (VStack focusable simple).

### 5. Localisations — `Resources/{fr,en}.lproj/Localizable.strings`

| Clé | fr | en | Action |
|---|---|---|---|
| `settings.playback` | Lecture | Playback | **ajout** |
| `settings.interface.library` | Bibliothèque | Library | **ajout** |
| `settings.interface.playback` | — | — | **suppression** (les 2 fichiers) |
| `settings.libraryLayout` | Bibliothèque → **Disposition** | Library → **Layout** | changement de valeur (la row vit désormais DANS la sous-page « Bibliothèque » — garder l'ancien libellé ferait « Bibliothèque » sous « Bibliothèque ») |
| `settings.debug` | Débogage | Debug | conservée (devient l'en-tête de section dans Lecture) |

### 6. CLAUDE.md

- Section **Settings Screen** : nouvelle description du landing (5 catégories
  non-admin), hub Interface = Main Menu / Home page / Library / Detail page,
  Lecture top-level avec section Débogage, Licences au pied du landing.
- Corriger la liste des catalogues : `interfaceToggleRows` → `playbackToggleRows`
  (la doc actuelle est périmée).
- Table `@AppStorage` : row `tvos.dimUnfocusedPosters` « toggle in Settings →
  Appearance » → « Settings → Interface → Library ».
- Balayer les autres références « Settings → Interface » (ex. `forceNativeAVPlayer`
  dans la section VLC, « Debug tooling (Settings → Interface → Debug) ») →
  « Settings → Playback ».

## Risques et points de vigilance

- **Exhaustivité des switch** : la suppression de cases d'`InterfaceSubcategory` et
  l'ajout dans `SettingsCategory` cassent la compilation partout où un switch est
  non-exhaustif — c'est voulu, le compilateur est le filet.
- **tvOS focus** : 5 pastilles au landing au lieu de 4 + une row Licences focusable
  sous la barre d'info. À valider par `tvos-focus-reviewer`.
- **Parité FR/EN** : vérifiée par le skill `localize-check`.
- **Aucun nouveau fichier** → pas de `xcodegen generate`, le `project.pbxproj`
  committé reste intact.

## Vérification

1. Build iOS + build tvOS (sériels, jamais parallèles — verrou DerivedData).
2. Suite de tests complète (`xcodebuild test -scheme Cinemax`, grep `Suite`/`✔` —
   jamais `-only-testing`). Baseline lancée avant modification pour comparaison.
3. Skills `localize-check` et `design-system-review` sur les fichiers modifiés.
4. Agent `tvos-focus-reviewer` sur le diff tvOS.
5. Gate de fraîcheur CLAUDE.md avant `gh pr create` (hook existant).
