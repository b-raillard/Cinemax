# Réorganisation des Réglages — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Réorganiser l'arborescence des Réglages : Lecture au 1er niveau (avec section Débogage), hub Interface = un écran par sous-page (Menu / Accueil / Bibliothèque / Détail), Licences au pied du landing. Spec : `docs/superpowers/specs/2026-07-31-settings-reorganization-design.md`.

**Architecture:** Pure réorganisation du rendu. Les enums `SettingsCategory`/`InterfaceSubcategory` (SSOT de la structure) changent en premier ; les deux fichiers de rendu plateforme (`#if os(iOS)` / `#if os(tvOS)`) sont ensuite adaptés **en parallèle** (ils ne se compilent jamais ensemble pour une même plateforme). Aucune clé `@AppStorage` ne bouge.

**Tech Stack:** SwiftUI multi-plateforme iOS 26/tvOS 26, Swift 6 strict concurrency, swift-testing.

## Global Constraints

- **Aucun nouveau fichier** (ni source ni test) — un nouveau fichier exigerait `xcodegen generate` et du churn `project.pbxproj`. Le test de régression s'ajoute à `Tests/CinemaxKitTests/MenuConfigStoreTests.swift`.
- **Aucune clé `SettingsKey` modifiée** ; aucun `didSet` sur `@Observable` ; jamais de `Toggle` système dans les réglages.
- Toutes les chaînes via `loc.localized(...)` ; parité stricte `fr.lproj`/`en.lproj`.
- Pas de `.font(.system(size: N))` avec littéral nu hors motifs existants copiés tels quels (tout passe par `CinemaScale.pt` / `CinemaFont`).
- Builds iOS et tvOS **sériels** (verrou DerivedData), `set -o pipefail` sur tout pipe xcodebuild, confirmer `** BUILD SUCCEEDED **` dans la sortie.
- Tests : suite complète (`xcodebuild test -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`), **jamais `-only-testing`** ; vérifier « Test run with N tests … passed ». Baseline : 377 tests / 44 suites verts.
- Commits : convention du dépôt (`refactor(settings): …` en français) + trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Le worktree est `/Users/braillard/projets/perso/jellyfin/Cinemax/.claude/worktrees/settings-reorg` — tous les chemins ci-dessous y sont relatifs.

**Ordre d'exécution : Task 1 (fondations, commit par l'agent) → Tasks 2 et 3 en parallèle (fichiers disjoints) → Task 4 (intégration par l'orchestrateur) → Task 5 (CLAUDE.md + revues) → Task 6 (PR).** Règle des tasks parallèles : les agents 2 et 3 ne lancent **aucune commande git ni xcodebuild** — deux stagings entrelacés corrompraient l'attribution des commits, et deux builds simultanés se heurtent au verrou DerivedData. L'orchestrateur committe leurs fichiers séparément puis builde en série (Task 4). L'état n'est vert qu'une fois les trois tasks réunies (couplage de compilation trans-fichiers assumé — le commit de la Task 1 laisse volontairement les fichiers plateforme non compilables).

---

### Task 1: Fondations — test de régression, enums, localisations

**Files:**
- Modify: `Tests/CinemaxKitTests/MenuConfigStoreTests.swift` (fin de fichier)
- Modify: `Shared/Screens/Settings/SettingsScreen.swift:14-118`
- Modify: `Resources/fr.lproj/Localizable.strings` (~242-244, ~293)
- Modify: `Resources/en.lproj/Localizable.strings` (~640-642, ~691)

**Interfaces:**
- Produces: `SettingsCategory.playback` (icône `"play.rectangle"`, label `settings.playback`) ; `InterfaceSubcategory` = `menu, homePage, library, detailPage` (`.library` : icône `"books.vertical"`, label `settings.interface.library`) ; clés l10n `settings.playback`, `settings.interface.library` ; valeur de `settings.libraryLayout` = « Disposition » / « Layout ».

- [ ] **Step 1 : Test de régression (rouge — ne compile pas tant que Step 2 n'est pas fait)**

Ajouter à la fin de `Tests/CinemaxKitTests/MenuConfigStoreTests.swift` :

```swift
// MARK: - Settings categories

/// Verrouille la structure du landing Réglages après la réorganisation
/// (Lecture promue au 1er niveau) : l'ordre de déclaration = l'ordre
/// d'affichage, et `.playback` doit rester visible sur les deux plateformes
/// pour tout utilisateur — ni admin-gated, ni platform-gated.
@Suite("SettingsCategory")
struct SettingsCategoryTests {
    @Test("le landing non-admin résout les 5 catégories canoniques, dans l'ordre, sur les deux plateformes")
    @MainActor func nonAdminOrder() {
        let expected: [SettingsCategory] = [.appearance, .interface, .playback, .account, .server]
        #expect(SettingsCategory.visibleCases(isAdmin: false, isTVOS: false) == expected)
        #expect(SettingsCategory.visibleCases(isAdmin: false, isTVOS: true) == expected)
    }

    @Test("l'admin iOS ajoute les deux catégories admin ; tvOS ne les montre jamais")
    @MainActor func adminGating() {
        #expect(SettingsCategory.visibleCases(isAdmin: true, isTVOS: false)
                == [.appearance, .interface, .playback, .account, .server, .administration, .advancedAdmin])
        #expect(SettingsCategory.visibleCases(isAdmin: true, isTVOS: true)
                == [.appearance, .interface, .playback, .account, .server])
    }

    @Test("le hub Interface expose exactement les quatre sous-pages écran, dans l'ordre")
    func interfaceSubPages() {
        #expect(InterfaceSubcategory.allCases == [.menu, .homePage, .library, .detailPage])
    }
}
```

- [ ] **Step 2 : Enums dans `SettingsScreen.swift`**

Remplacer la déclaration des cases de `SettingsCategory` (et son commentaire d'ordre, devenu faux) :

```swift
    // Declaration order = display order on both platforms (consumed by
    // `visibleCases` which preserves `allCases` order). Interface sits
    // second because it's the most-used category after Apparence — the
    // main-menu / playback / debug toggles all live there.
    case appearance
    case interface
    case account
    case server
```

par :

```swift
    // Declaration order = display order on both platforms (consumed by
    // `visibleCases` which preserves `allCases` order). Apparence stays
    // first (its pill is the accented hero on the iOS landing); Lecture
    // sits right after Interface — it hosts the most-consulted playback
    // toggles, promoted out of the Interface hub in the 2026-07 reorg.
    case appearance
    case interface
    case playback
    case account
    case server
```

Dans `var icon`, ajouter après le cas `.interface` :

```swift
        case .playback:       "play.rectangle"
```

Dans `localizedName`, ajouter après le cas `.interface` :

```swift
        case .playback:       loc.localized("settings.playback")
```

Remplacer intégralement les cases + `icon` + `localizedName` d'`InterfaceSubcategory` :

```swift
enum InterfaceSubcategory: String, CaseIterable, Identifiable {
    case menu
    case homePage
    case library
    case detailPage

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .menu:       "rectangle.grid.2x2"
        case .homePage:   "house"
        case .library:    "books.vertical"
        case .detailPage: "info.square"
        }
    }

    @MainActor func localizedName(_ loc: LocalizationManager) -> String {
        switch self {
        case .menu:       loc.localized("settings.interface.menu")
        case .homePage:   loc.localized("settings.homePage")
        case .library:    loc.localized("settings.interface.library")
        case .detailPage: loc.localized("settings.detailPage")
        }
    }
}
```

et actualiser le commentaire de tête de l'enum (« The Interface detail page is itself a hub of sub-pages — one per configurable screen: main menu, Home, Library, Detail. Playback and Debug moved to the top-level `.playback` category in the 2026-07 reorg. »).

- [ ] **Step 3 : Localisations**

`Resources/fr.lproj/Localizable.strings` :
- remplacer `"settings.interface.playback" = "Lecture";` par `"settings.playback" = "Lecture";`
- ajouter sous `"settings.interface.menu" = "Menu principal";` : `"settings.interface.library" = "Bibliothèque";`
- remplacer `"settings.libraryLayout" = "Bibliothèque";` par `"settings.libraryLayout" = "Disposition";`

`Resources/en.lproj/Localizable.strings` :
- remplacer `"settings.interface.playback" = "Playback";` par `"settings.playback" = "Playback";`
- ajouter sous `"settings.interface.menu" = "Main Menu";` : `"settings.interface.library" = "Library";`
- remplacer `"settings.libraryLayout" = "Library";` par `"settings.libraryLayout" = "Layout";`

- [ ] **Step 4 : Vérifier puis committer**

`grep -c "settings.interface.playback" Resources/*/Localizable.strings` → 0 occurrence ; `grep -c '"settings.playback"' Resources/fr.lproj/Localizable.strings Resources/en.lproj/Localizable.strings` → 1 dans chaque. Ne PAS builder : les fichiers plateforme ne compilent pas encore (rouge attendu, Tasks 2-3 le rendent vert). Committer :

```bash
git add Shared/Screens/Settings/SettingsScreen.swift Resources/fr.lproj/Localizable.strings Resources/en.lproj/Localizable.strings Tests/CinemaxKitTests/MenuConfigStoreTests.swift
git commit -m "refactor(settings): fondations de la réorganisation — enums + localisations

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Rendu iOS (agent Opus — fichiers exclusifs : `SettingsScreen+iOS.swift`, `SettingsAppearanceView+iOS.swift`)

**Files:**
- Modify: `Shared/Screens/Settings/SettingsScreen+iOS.swift`
- Modify: `Shared/Screens/Settings/SettingsAppearanceView+iOS.swift`

**Interfaces:**
- Consumes: Task 1 (`SettingsCategory.playback`, `InterfaceSubcategory.library`, clés l10n).
- Produces: `iOSPlaybackDetail`, `iOSLibrarySection`, `libraryLayoutPicker`/`libraryLayoutButton` (déplacés sur l'extension iOS de `SettingsScreen`), `iOSLicensesFooter`.

- [ ] **Step 1 : `settingsDetailView(for:)` — brancher `.playback`**

Dans le `switch category` interne (celui sous le `ScrollView`), ajouter après le cas `.interface` :

```swift
                    case .playback:
                        iOSPlaybackDetail
                    case .administration, .advancedAdmin:
                        EmptyView() // handled above
```

(le cas `.administration, .advancedAdmin` existe déjà — ne pas le dupliquer, seulement insérer `.playback` avant lui).

- [ ] **Step 2 : Page Lecture top-level — remplacer `iOSPlaybackSection` et `iOSDebugSection`**

Supprimer les deux propriétés existantes :

```swift
    var iOSPlaybackSection: some View {
        VStack(spacing: 0) {
            iOSToggleRowsJoined(playbackToggleRows, accent: themeManager.accent, animated: motionEffects, loc: loc)
            iOSSettingsDivider
            iOSSleepTimerRow
        }
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }
```

```swift
    var iOSDebugSection: some View {
        VStack(spacing: 0) {
            iOSToggleRowsJoined(debugToggleRows, accent: themeManager.accent, animated: motionEffects, loc: loc)
        }
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }
```

et les remplacer par la page complète (mêmes contenus, section Débogage titrée en dessous — le tint orange vient déjà de `debugToggleRows`) :

```swift
    /// Page Lecture top-level : réglages du player + section Débogage (outils
    /// QA, toujours visibles — pas de gate #if DEBUG, voir CLAUDE.md).
    var iOSPlaybackDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
            VStack(spacing: 0) {
                iOSToggleRowsJoined(playbackToggleRows, accent: themeManager.accent, animated: motionEffects, loc: loc)
                iOSSettingsDivider
                iOSSleepTimerRow
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)

            VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
                iOSSettingsSectionHeader(loc.localized("settings.debug"))

                VStack(spacing: 0) {
                    iOSToggleRowsJoined(debugToggleRows, accent: themeManager.accent, animated: motionEffects, loc: loc)
                }
                .glassPanel(cornerRadius: CinemaRadius.extraLarge)
            }
        }
    }
```

- [ ] **Step 3 : `iOSInterfaceSubDetailView(for:)` — nouveau switch**

Remplacer :

```swift
                    switch sub {
                    case .menu:       EmptyView() // handled above
                    case .homePage:   iOSHomePageSection
                    case .detailPage: iOSDetailPageSection
                    case .playback:   iOSPlaybackSection
                    case .debug:      iOSDebugSection
                    }
```

par :

```swift
                    switch sub {
                    case .menu:       EmptyView() // handled above
                    case .homePage:   iOSHomePageSection
                    case .library:    iOSLibrarySection
                    case .detailPage: iOSDetailPageSection
                    }
```

- [ ] **Step 4 : Sous-page Bibliothèque + helpers déplacés**

Ajouter (à côté d'`iOSHomePageSection`) — la row Disposition et ses deux helpers viennent **verbatim** de `IOSAppearanceDetailView`, en lisant le `@AppStorage libraryBrowseLayout` déjà déclaré sur `SettingsScreen` (ligne 194 de `SettingsScreen.swift`) :

```swift
    var iOSLibrarySection: some View {
        VStack(spacing: 0) {
            iOSSettingsRow {
                // Label on its own line, the two-option control full-width
                // below it — side-by-side gets squeezed to "Par…/Tout…" once
                // the label + buttons can't share one row (e.g. FR @ 100%).
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
                    HStack {
                        iOSRowIcon(systemName: "square.grid.2x2", color: themeManager.accent)
                        Text(loc.localized("settings.libraryLayout"))
                            .font(CinemaFont.dynamicLabel(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                        Spacer()
                    }
                    libraryLayoutPicker
                }
            }
        }
        .glassPanel(cornerRadius: CinemaRadius.extraLarge)
    }

    /// Full-width two-option control. "By genre" = browse (hero + genre rows);
    /// "Show all" = flat grid. Each button takes half the row so the full FR
    /// labels ("Par genre" / "Tout afficher") fit without truncation.
    var libraryLayoutPicker: some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            libraryLayoutButton(.browse, label: loc.localized("settings.libraryLayout.browse"))
            libraryLayoutButton(.grid, label: loc.localized("settings.libraryLayout.grid"))
        }
    }

    func libraryLayoutButton(_ option: LibraryBrowseLayout, label: String) -> some View {
        let isSelected = (LibraryBrowseLayout(rawValue: libraryBrowseLayout) ?? .browse) == option
        return Button {
            libraryBrowseLayout = option.rawValue
        } label: {
            Text(label)
                .font(.system(size: CinemaScale.pt(15), weight: .semibold))
                .foregroundStyle(isSelected ? themeManager.onAccent : CinemaColor.onSurfaceVariant)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .fill(isSelected ? themeManager.accent : CinemaColor.surfaceContainerHigh)
                )
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 5 : Serveur — retirer les Licences**

Dans `iOSServerDetail`, supprimer le bloc :

```swift
            // Licenses
            VStack(spacing: 0) {
                navigationRow(icon: "doc.text", label: loc.localized("settings.licenses")) {
                    showLicenses = true
                }
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
```

- [ ] **Step 6 : Licences au pied du landing**

Dans `iOSLayout`, le `VStack(spacing: 0)` devient :

```swift
            VStack(spacing: 0) {
                iOSHeader
                iOSNavigationList
                iOSDeviceInfo
                iOSLicensesFooter
            }
```

et ajouter (près d'`iOSDeviceInfo`) :

```swift
    /// Pied de page « À propos » du landing : lien discret vers les licences
    /// open source, sous le bloc appareil/version. Reste un `@State` de
    /// `SettingsScreen` (`showLicenses`) — la `.sheet` est déjà attachée au
    /// `body` partagé.
    var iOSLicensesFooter: some View {
        Button {
            showLicenses = true
        } label: {
            Text(loc.localized("settings.licenses"))
                .font(CinemaFont.label(.medium))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
        }
        .buttonStyle(.plain)
        .padding(.bottom, CinemaSpacing.spacing8)
    }
```

et réduire le `.padding(.bottom, CinemaSpacing.spacing6)` d'`iOSDeviceInfo` à `.padding(.bottom, CinemaSpacing.spacing3)` pour que le lien respire sans doubler l'espace.

- [ ] **Step 7 : `SettingsAppearanceView+iOS.swift` — retirer la Disposition**

Supprimer : la ligne `@AppStorage(SettingsKey.libraryBrowseLayout) private var libraryBrowseLayout…` ; le bloc `iOSSettingsDivider` + `iOSSettingsRow { … libraryLayoutPicker … }` en fin de panneau (lignes ~153-169) ; les helpers `libraryLayoutPicker` et `libraryLayoutButton` (lignes ~176-204, ils vivent désormais sur l'extension iOS de `SettingsScreen`). Le commentaire de tête (« All rows here are Appearance-only (dark mode, accent, language) ») reste juste.

- [ ] **Step 8 : Relecture finale du diff (AUCUNE commande git ni xcodebuild)**

Cette task s'exécute en parallèle de la Task 3 dans le même worktree : ne lancer **aucun** `git add`/`git commit` (entrelacement de staging) ni **aucun** `xcodebuild` (verrou DerivedData). Se relire, vérifier que chaque référence à `iOSPlaybackSection`/`iOSDebugSection`/`.playback`/`.debug` a disparu du fichier iOS (`grep -n "iOSPlaybackSection\|iOSDebugSection" Shared/Screens/Settings/SettingsScreen+iOS.swift` → 0), et rapporter DONE. L'orchestrateur committe et builde (Task 4).

---

### Task 3: Rendu tvOS (agent Opus — fichier exclusif : `SettingsScreen+tvOS.swift`)

**Files:**
- Modify: `Shared/Screens/Settings/SettingsScreen+tvOS.swift`

**Interfaces:**
- Consumes: Task 1 (`SettingsCategory.playback`, `InterfaceSubcategory.library`, clés l10n). `tvActionRow`/`tvGlassToggle`/`tvSectionLabel`/`tvSleepTimerRow`/`tvLibraryLayoutRow` existants.
- Produces: `tvPlaybackDetail`, `tvLibrarySection` ; `tvLicensesButton` déplacé sur le landing.

- [ ] **Step 1 : `tvDetailView(for:)` — brancher `.playback`**

Dans le `switch category`, ajouter après le cas `.interface` :

```swift
                case .playback:
                    tvPlaybackDetail
```

- [ ] **Step 2 : Page Lecture top-level — remplacer `tvPlaybackSection` et `tvDebugSection`**

Supprimer :

```swift
    var tvPlaybackSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvToggleList(playbackToggleRows)
            tvSleepTimerRow
        }
    }
```

```swift
    var tvDebugSection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvToggleList(debugToggleRows)
        }
    }
```

et les remplacer par :

```swift
    /// Page Lecture top-level : réglages du player + section Débogage (outils
    /// QA, toujours visibles — pas de gate #if DEBUG, voir CLAUDE.md).
    var tvPlaybackDetail: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvToggleList(playbackToggleRows)
            tvSleepTimerRow

            tvSectionLabel(loc.localized("settings.debug"))
                .padding(.top, CinemaSpacing.spacing4)
            tvToggleList(debugToggleRows)
        }
    }
```

- [ ] **Step 3 : `tvInterfaceSubDetailView(for:)` — nouveau switch**

Remplacer :

```swift
                switch sub {
                case .menu:       tvMenuSection
                case .homePage:   tvHomePageSection
                case .detailPage: tvDetailPageSection
                case .playback:   tvPlaybackSection
                case .debug:      tvDebugSection
                }
```

par :

```swift
                switch sub {
                case .menu:       tvMenuSection
                case .homePage:   tvHomePageSection
                case .library:    tvLibrarySection
                case .detailPage: tvDetailPageSection
                }
```

- [ ] **Step 4 : Sous-page Bibliothèque**

Ajouter (à côté de `tvHomePageSection`) :

```swift
    var tvLibrarySection: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            tvLibraryLayoutRow

            tvGlassToggle(
                icon: "viewfinder",
                label: loc.localized("settings.dimUnfocusedPosters"),
                key: "dimUnfocusedPosters",
                value: $dimUnfocusedPosters
            )
        }
    }
```

- [ ] **Step 5 : Apparence — retirer les deux rows déplacées**

Dans `tvAppearanceDetail`, supprimer la ligne `tvLibraryLayoutRow` et le bloc :

```swift
            tvGlassToggle(
                icon: "viewfinder",
                label: loc.localized("settings.dimUnfocusedPosters"),
                key: "dimUnfocusedPosters",
                value: $dimUnfocusedPosters
            )
```

Actualiser le commentaire de `tvLibraryLayoutRow` (« The iOS equivalent is an inline segmented control in `IOSAppearanceDetailView` ») → « Rendered inside Interface → Library on both platforms; the iOS equivalent lives in `iOSLibrarySection`. »

- [ ] **Step 6 : Serveur — retirer les Licences ; landing — les accueillir**

Dans `tvServerDetail`, supprimer la ligne `tvLicensesButton`. Dans `tvNavigationPanel`, remplacer :

```swift
            // System Information bar
            tvSystemInfoBar
                .padding(.horizontal, CinemaSpacing.spacing10)
                .padding(.bottom, CinemaSpacing.spacing8)
```

par :

```swift
            // System Information bar + about footer (open-source licences —
            // reachable by pressing down past the last category pill; plain
            // vertical stack, no .focusSection() needed)
            tvSystemInfoBar
                .padding(.horizontal, CinemaSpacing.spacing10)

            tvLicensesButton
                .padding(.horizontal, CinemaSpacing.spacing10)
                .padding(.bottom, CinemaSpacing.spacing8)
```

(`tvLicensesButton` existe déjà — `tvActionRow(id: "licenses", …)`, focus `.toggle("licenses")` — seul son site d'appel change.)

- [ ] **Step 7 : Relecture finale du diff (AUCUNE commande git ni xcodebuild)**

Cette task s'exécute en parallèle de la Task 2 dans le même worktree : ne lancer **aucun** `git add`/`git commit` (entrelacement de staging) ni **aucun** `xcodebuild` (verrou DerivedData). Se relire, vérifier `grep -n "tvPlaybackSection\|tvDebugSection" Shared/Screens/Settings/SettingsScreen+tvOS.swift` → 0, et rapporter DONE. L'orchestrateur committe et builde (Task 4).

---

### Task 4: Intégration (orchestrateur) — commits séparés Tasks 2/3, builds sériels, suite complète

**Files:** aucun nouveau — commits des fichiers des Tasks 2 et 3, vérifications.

- [ ] **Step 0 :** Deux commits séparés (attribution par task) :

```bash
git add Shared/Screens/Settings/SettingsScreen+iOS.swift Shared/Screens/Settings/SettingsAppearanceView+iOS.swift
git commit -m "refactor(settings): rendu iOS de la nouvelle arborescence

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git add Shared/Screens/Settings/SettingsScreen+tvOS.swift
git commit -m "refactor(settings): rendu tvOS de la nouvelle arborescence

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 1 :** Build iOS : `set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20` → `** BUILD SUCCEEDED **`.
- [ ] **Step 2 :** Build tvOS : `set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | tail -20` → `** BUILD SUCCEEDED **`.
- [ ] **Step 3 :** Suite complète :

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Attendu : `** TEST SUCCEEDED **` et « Test run with **380** tests in **45** suites passed » (377 + les 3 de `SettingsCategoryTests`).

- [ ] **Step 4 :** En cas d'échec build/tests : boucle de correction vers l'agent propriétaire du fichier fautif (fix rounds du skill), jamais de correctif orchestrateur.

---

### Task 5: CLAUDE.md + revues (localize-check, design-system-review, tvos-focus-reviewer)

**Files:**
- Modify: `CLAUDE.md` (section « Settings Screen », références « Settings → Interface » éparses, table `@AppStorage` row `tvos.dimUnfocusedPosters`, liste des catalogues `interfaceToggleRows` → `playbackToggleRows`)

- [ ] **Step 1 :** `grep -n "Settings → Interface\|Interface hub\|interfaceToggleRows\|Settings → Appearance" CLAUDE.md` et corriger chaque occurrence pour refléter : Lecture top-level (incl. Débogage), hub Interface = Main Menu / Home page / Library / Detail page, Licences au pied du landing, `dimUnfocusedPosters` → Settings → Interface → Library.
- [ ] **Step 2 :** Skill `localize-check` → 0 clé manquante fr/en, 0 chaîne codée en dur introduite.
- [ ] **Step 3 :** Skill `design-system-review` sur les fichiers modifiés → traiter tout écart.
- [ ] **Step 4 :** Agent `tvos-focus-reviewer` sur le diff de `SettingsScreen+tvOS.swift` → traiter les findings réels (skill `receiving-code-review` : vérifier avant d'appliquer).
- [ ] **Step 5 :** Commit `docs(claude): réglages — arborescence à jour dans CLAUDE.md` (+ trailer), incluant les éventuels correctifs de revue (ou commits séparés si substantiels).

---

### Task 6: Finalisation — push + PR

- [ ] **Step 1 :** Skill `finishing-a-development-branch`.
- [ ] **Step 2 :** Push : `git push -u origin HEAD:refactor/settings-reorganisation`.
- [ ] **Step 3 :** `gh pr create` vers `main` (le hook PreToolUse vérifie la fraîcheur CLAUDE.md — satisfaite par la Task 5), titre « refactor(settings): réorganisation de l'arborescence des réglages », corps : résumé de l'arborescence cible + lien spec + résultats de vérification, pied « 🤖 Generated with [Claude Code](https://claude.com/claude-code) ».

## Self-review du plan

- **Couverture spec** : enums ✔ (T1) ; iOS ✔ (T2) ; Appearance iOS ✔ (T2/S7) ; tvOS ✔ (T3) ; l10n ✔ (T1/S3) ; CLAUDE.md ✔ (T5) ; vérifs ✔ (T4/T5). Pas d'écart.
- **Placeholders** : aucun — chaque step porte son code exact.
- **Cohérence de types** : `iOSPlaybackDetail`/`tvPlaybackDetail`/`iOSLibrarySection`/`tvLibrarySection`/`iOSLicensesFooter` nommés identiquement entre tasks ; helpers `libraryLayoutPicker`/`libraryLayoutButton` consommés par T2/S4 uniquement.
