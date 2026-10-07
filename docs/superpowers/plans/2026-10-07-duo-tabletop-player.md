# Lecteur Duo en posture « table » — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** quand l'iPhone Duo est à moitié replié en portrait, le lecteur iOS place la vidéo sur l'écran du haut et ses commandes sur une dalle de blocs dans l'écran du bas, avec un halo de la vidéo sous le pli qui suit l'image en direct ; partout ailleurs, le lecteur reste identique.

**Architecture:** une décision pure (`PlayerPostureLayout`) transforme l'état de la charnière (`UIHingeInteraction`, iOS 27.1) et la taille de la vue en mode `regular` / `tabletop`. `VLCStreamPresenter` garde ses contrôles existants (mêmes boutons, mêmes actions, mêmes libellés VoiceOver) et bascule entre deux jeux de contraintes et deux styles de boutons ; un guide « zone vidéo » déplace la vidéo et les éléments centrés vers la moitié haute. Le halo est un miroir en direct de la vue vidéo : sa couche devient un `CAReplicatorLayer` (une seule instance en regular, deux en mode table), la copie est retournée sous le pli, puis voilée par un flou natif et un dégradé vers le noir — rendu par le serveur d'affichage, sans capture ni minuteur (sonde du 2026-10-07 : la copie de l'image libVLC s'affiche bien).

**Tech Stack:** Swift 6, UIKit (le lecteur iOS est UIKit), SwiftVLC, swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-07-duo-tabletop-player-design.md`

## Global Constraints

- iOS uniquement : tout le code nouveau du lecteur est sous `#if os(iOS)` ; tvOS ne compile rien de la dalle (la décision pure, elle, compile partout).
- `UIHingeInteraction` / `UIHinge` n'existent que dans le SDK **27.1** ; la CI compile avec **Xcode 27.0** (`ci.yml` `XCODE_VERSION: "27.0"`, `project.yml` `xcodeVersion: "27.0"`). Le code charnière est sous `#if !NO_HINGE_API` **et** `if #available(iOS 27.1, *)` (l'app cible iOS 26).
- Mode « table » ⇔ charnière `partiallyOpen` **et** vue plus haute que large. Tout le reste ⇒ lecteur actuel, à l'identique.
- Délai d'auto-masquage inchangé : 4 s (`scheduleHideControls`).
- Nouvelle clé `SettingsKey.playerTabletopHUDLocked` = `"player.tabletopHUDLocked"`, `Bool`, défaut `false`.
- Couleurs : fond de dalle = blanc à 4 % sur noir (≈ `#0B0B0B`) affichée, noir pur masquée ; blocs = blanc 7,5 % (lecture : 13 %), rayon 20 pt ; cadenas ouvert = icône en couleur d'accent, fermé = icône blanche, bloc toujours en teinte normale.
- Halo : miroir en direct, opacité 0,38, retourné, image reflétée commençant 24 pt sous le pli, flou, fondu vers le noir sur 80 % ; identique dalle affichée ou masquée.
- Toute chaîne visible passe par `loc.localized` ; nouvelles clés en **fr, en et de** (CI : parité FR/EN).
- Nouveau fichier Swift sous `Shared/` ou `Tests/` ⇒ `xcodegen generate` avant de compiler. Ne jamais commiter `DEVELOPMENT_TEAM` (le hook pre-commit nettoie le pbxproj).
- swift-testing : jamais `-only-testing` (exécute 0 test en silence) ; lancer toute la suite et chercher le nom de la suite dans le journal.
- `$SCRATCH` dans les commandes = le dossier scratchpad de la session (fichiers jetables, jamais dans le dépôt).
- Branche dédiée depuis `main` : `claude/duo-tabletop-player` (la PR #294 du Duo fermé reste à part). Fusion manuelle par l'utilisateur.

**Écarts par rapport à la spec (retour utilisateur du 2026-10-07 intégré) :**
1. Les listes (sous-titres, audio, vitesse, chapitres) restent la feuille d'actions iOS actuelle (`presentPicker` → `UIAlertController`) — *en attente de la comparaison visuelle demandée par l'utilisateur*.
2. Le menu de la barre du film est un `UIMenu` natif sur le bloc titre (une ligne « Statistiques » cochable) — *en attente de la même comparaison*.
3. La vignette du bloc titre est une miniature du film capturée à chaque apparition de la dalle (`drawHierarchy`, ~4 ms, seulement quand la dalle apparaît).

**Décisions (plus des écarts) :**
- Ligne de détail = année · durée · définition, la définition déduite de la piste vidéo en lecture (largeur ≥ 3 200 px → « 4K », ≥ 1 800 → « 1080p », ≥ 1 200 → « 720p », sinon « SD ») — aucune requête de plus.
- Halo en DIRECT (miroir `CAReplicatorLayer`), pas de rafraîchissement périodique.
- Cadenas fermé : la dalle ne se masque JAMAIS, ni au bout de 4 s ni au toucher. Seul le cadenas décide.

## Review Focus

- **Charnière qui bouge pendant qu'une feuille d'actions est ouverte** : la feuille reste ouverte et utilisable, la mise en page bascule derrière ; le choix fait dans la feuille s'applique.
- **Pli → plat → pli en pleine lecture, pendant un glissement du curseur** : la lecture continue, le curseur ne saute pas, aucun état « en cours de glissement » ne reste coincé.
- **Mise à jour `hinge == nil` en cours de lecture** (la vue change de hiérarchie : PiP, rotation) : le mode ne bascule pas, il garde le dernier état connu.
- **Film sans chapitres / un seul chapitre, film sans épisodes voisins** : le bloc Chapitres disparaît et les blocs restants se partagent la largeur ; les boutons épisode précédent / suivant restent masqués.
- **VoiceOver actif en mode table** : pas d'auto-masquage (règle existante), chaque bloc garde le libellé du bouton d'origine, le cadenas annonce son état.

---

## File Structure

| Fichier | Rôle |
|---|---|
| `Shared/Screens/VideoPlayer/PlayerPostureLayout.swift` (nouveau) | Décision pure : `HingeReading`, `PlayerLayoutMode`, `PlayerPostureLayout.mode/reading/autoHides`. Sans UIKit hormis `CGSize`. Compile iOS + tvOS. |
| `Tests/CinemaxKitTests/PlayerPostureLayoutTests.swift` (nouveau) | Tests swift-testing de la décision. |
| `Shared/Screens/VideoPlayer/TabletopHUDStyle.swift` (nouveau, iOS) | Fabriques de `UIButton.Configuration` pour les blocs (transport, réglage, titre, cadenas, fermer) et constantes de couleur. Aucun état. |
| `Shared/Screens/VideoPlayer/TabletopHalo.swift` (nouveau, iOS) | `MirroringVideoView` (vue vidéo à couche `CAReplicatorLayer` : miroir en direct sous le pli), `TabletopHaloVeil` (flou natif + dégradé vers le noir par-dessus le reflet), `TabletopHalo.thumbnail(of:videoAspect:)` (vignette du bloc titre) et `TabletopHalo.qualityLabel(width:)`. |
| `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift` | Guide « zone vidéo », jeux de contraintes regular / tabletop, charnière, bascule, cadenas, blocs, statistiques en deux colonnes, rafraîchissement du halo. |
| `Shared/DesignSystem/SettingsKeys.swift` | Clé `playerTabletopHUDLocked` + défaut. |
| `Resources/{fr,en,de}.lproj/Localizable.strings` | Libellés VoiceOver du cadenas. |
| `project.yml` | Condition de compilation `NO_HINGE_API` pour le SDK 27.0. |
| `Shared/Screens/VideoPlayer/CLAUDE.md`, `Shared/Screens/Settings/CLAUDE.md` | RULE du mode table ; ligne de la clé. |

---

### Task 0: Branche et garde de compilation du SDK 27.0

**Files:**
- Modify: `project.yml` (cible `Cinemax`, réglages `base`, à côté de `SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) CINEMAX_APP`, ligne ~190)

**Interfaces:**
- Produces: la condition de compilation `NO_HINGE_API`, définie seulement quand le SDK iOS est en 27.0.

- [ ] **Step 1: Créer la branche depuis `main` et y porter la spec**

```bash
git stash list >/dev/null   # rien à remiser : la spec est un fichier non suivi
git fetch origin main
git switch -c claude/duo-tabletop-player origin/main
git add docs/superpowers/specs/2026-10-07-duo-tabletop-player-design.md docs/superpowers/plans/2026-10-07-duo-tabletop-player.md
git commit -m "docs: spec et plan du lecteur Duo en posture table"
```

- [ ] **Step 2: Écrire la sonde de compilation (fichier jetable, hors projet)**

Créer `$SCRATCH/hinge-probe.swift` :

```swift
import UIKit
#if !NO_HINGE_API
@available(iOS 27.1, *)
@MainActor func probe() -> UIHingeInteraction { UIHingeInteraction { _, _ in } }
#endif
```

- [ ] **Step 3: Vérifier que la sonde casse sur le SDK 27.0 sans la condition**

```bash
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)   # Xcode 27.0 par défaut
xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios26.0-simulator $SCRATCH/hinge-probe.swift
```
Expected: erreur « cannot find 'UIHingeInteraction' in scope ».

- [ ] **Step 4: Ajouter la condition dans `project.yml`**

Sous les réglages `base` de la cible `Cinemax` (là où se trouve `SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) CINEMAX_APP`), ajouter :

```yaml
        # UIHingeInteraction (iPhone Duo) n'existe qu'à partir du SDK 27.1 ;
        # la CI compile encore avec Xcode 27.0. Le code charnière est sous
        # `#if !NO_HINGE_API`. À retirer quand la CI passe en 27.1.
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphonesimulator27.0]": $(inherited) CINEMAX_APP NO_HINGE_API
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos27.0]": $(inherited) CINEMAX_APP NO_HINGE_API
```

Le hook PostToolUse relance `xcodegen generate`.

- [ ] **Step 5: Vérifier la condition dans les deux Xcode**

```bash
xcodebuild -project Cinemax.xcodeproj -scheme Cinemax -sdk iphonesimulator -showBuildSettings 2>/dev/null | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS
DEVELOPER_DIR=/Applications/Xcode-27.1-RC.app/Contents/Developer xcodebuild -project Cinemax.xcodeproj -scheme Cinemax -sdk iphonesimulator -showBuildSettings 2>/dev/null | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS
```
Expected: la première ligne contient `NO_HINGE_API`, la seconde non. Si les crochets ne prennent pas (même valeur des deux côtés), essayer `[sdk=iphonesimulator27.0*]` ; en dernier recours, remplacer la garde de compilation par une résolution à l'exécution (`NSClassFromString("UIHingeInteraction")`) et le signaler.

- [ ] **Step 6: Commit**

```bash
git add project.yml Cinemax.xcodeproj/project.pbxproj
git commit -m "build: condition NO_HINGE_API pour compiler la charnière du Duo avec le SDK 27.0"
```

---

### Task 1: Décision pure `PlayerPostureLayout`

**Files:**
- Create: `Shared/Screens/VideoPlayer/PlayerPostureLayout.swift`
- Test: `Tests/CinemaxKitTests/PlayerPostureLayoutTests.swift`

**Interfaces:**
- Produces:
  - `enum HingeReading: Equatable, Sendable { case unknown, closed, partiallyOpen, fullyOpen }`
  - `enum PlayerLayoutMode: Equatable, Sendable { case regular, tabletop }`
  - `enum PlayerPostureLayout` avec
    - `static func mode(hinge: HingeReading, viewSize: CGSize) -> PlayerLayoutMode`
    - `static func reading(previous: HingeReading, update: HingeReading?) -> HingeReading`
    - `static func autoHides(mode: PlayerLayoutMode, locked: Bool) -> Bool`
    - `static func tapHides(mode: PlayerLayoutMode, locked: Bool) -> Bool`

- [ ] **Step 1: Écrire les tests**

```swift
import Testing
import CoreGraphics
@testable import Cinemax

/// Le mode « table » du lecteur : vidéo sur l'écran du haut, dalle de
/// commandes sur l'écran du bas — seulement Duo à moitié ouvert ET en portrait.
@Suite("PlayerPostureLayout")
struct PlayerPostureLayoutTests {
    private let portrait = CGSize(width: 703, height: 1000)
    private let landscape = CGSize(width: 1000, height: 703)

    @Test("à moitié ouvert en portrait : mode table")
    func partiallyOpenPortrait() {
        #expect(PlayerPostureLayout.mode(hinge: .partiallyOpen, viewSize: portrait) == .tabletop)
    }

    @Test("à moitié ouvert en paysage (posture livre) : lecteur actuel")
    func partiallyOpenLandscape() {
        #expect(PlayerPostureLayout.mode(hinge: .partiallyOpen, viewSize: landscape) == .regular)
    }

    @Test("ouvert, fermé ou inconnu : lecteur actuel", arguments: [HingeReading.fullyOpen, .closed, .unknown])
    func otherReadingsAreRegular(_ reading: HingeReading) {
        #expect(PlayerPostureLayout.mode(hinge: reading, viewSize: portrait) == .regular)
        #expect(PlayerPostureLayout.mode(hinge: reading, viewSize: landscape) == .regular)
    }

    @Test("vue carrée ou vide : lecteur actuel")
    func degenerateSizes() {
        #expect(PlayerPostureLayout.mode(hinge: .partiallyOpen, viewSize: CGSize(width: 700, height: 700)) == .regular)
        #expect(PlayerPostureLayout.mode(hinge: .partiallyOpen, viewSize: .zero) == .regular)
    }

    @Test("une mise à jour sans charnière garde le dernier état connu")
    func nilKeepsPrevious() {
        #expect(PlayerPostureLayout.reading(previous: .partiallyOpen, update: nil) == .partiallyOpen)
        #expect(PlayerPostureLayout.reading(previous: .unknown, update: nil) == .unknown)
    }

    @Test("une vraie mise à jour remplace l'état")
    func updateReplaces() {
        #expect(PlayerPostureLayout.reading(previous: .partiallyOpen, update: .fullyOpen) == .fullyOpen)
        #expect(PlayerPostureLayout.reading(previous: .unknown, update: .closed) == .closed)
    }

    @Test("cadenas fermé en mode table : un toucher ne masque pas la dalle")
    func lockedTapDoesNotHide() {
        #expect(PlayerPostureLayout.tapHides(mode: .tabletop, locked: true) == false)
        #expect(PlayerPostureLayout.tapHides(mode: .tabletop, locked: false) == true)
        #expect(PlayerPostureLayout.tapHides(mode: .regular, locked: true) == true)
    }

    @Test("le cadenas fermé n'arrête le masquage automatique qu'en mode table")
    func lockOnlyMattersInTabletop() {
        #expect(PlayerPostureLayout.autoHides(mode: .tabletop, locked: true) == false)
        #expect(PlayerPostureLayout.autoHides(mode: .tabletop, locked: false) == true)
        #expect(PlayerPostureLayout.autoHides(mode: .regular, locked: true) == true)
        #expect(PlayerPostureLayout.autoHides(mode: .regular, locked: false) == true)
    }
}
```

- [ ] **Step 2: Lancer les tests, vérifier l'échec de compilation**

```bash
xcodegen generate
xcrun simctl bootstatus 2E531329-FC54-453A-85D4-6E6C27F97314 -b
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'id=2E531329-FC54-453A-85D4-6E6C27F97314' -derivedDataPath build/DD-tests -skipPackagePluginValidation 2>&1 | tee $SCRATCH/test.log | grep -E "error:|\*\* TEST" | head
```
Expected: `error: cannot find 'PlayerPostureLayout' in scope`.

- [ ] **Step 3: Implémenter**

```swift
import CoreGraphics

/// L'état de la charnière du Duo, détaché de `UIHinge.Status` (SDK 27.1) pour
/// que la décision et ses tests compilent avec n'importe quel SDK.
enum HingeReading: Equatable, Sendable {
    case unknown, closed, partiallyOpen, fullyOpen
}

enum PlayerLayoutMode: Equatable, Sendable {
    /// Le lecteur de toujours : vidéo plein écran, HUD par-dessus.
    case regular
    /// iPhone Duo à moitié replié en portrait : vidéo sur l'écran du haut,
    /// dalle de blocs sur l'écran du bas. Voir la RULE dans `VideoPlayer/CLAUDE.md`.
    case tabletop
}

/// Décision pure du mode de mise en page du lecteur iOS.
enum PlayerPostureLayout {
    /// Table ⇔ à moitié ouvert ET plus haut que large. À moitié ouvert en
    /// paysage, l'appareil s'ouvre comme un livre (pli vertical) : lecteur actuel.
    static func mode(hinge: HingeReading, viewSize: CGSize) -> PlayerLayoutMode {
        guard hinge == .partiallyOpen, viewSize.height > viewSize.width else { return .regular }
        return .tabletop
    }

    /// `UIHingeInteraction` envoie `hinge == nil` quand la vue change de
    /// hiérarchie (présentation du lecteur, PiP) : ce n'est pas un changement
    /// de posture, on garde le dernier état connu.
    static func reading(previous: HingeReading, update: HingeReading?) -> HingeReading {
        update ?? previous
    }

    /// Le cadenas de la dalle n'existe qu'en mode table ; fermé, la dalle ne se
    /// masque ni au bout du délai…
    static func autoHides(mode: PlayerLayoutMode, locked: Bool) -> Bool {
        !(mode == .tabletop && locked)
    }

    /// …ni au toucher (décision utilisateur du 2026-10-07 : seul le cadenas décide).
    static func tapHides(mode: PlayerLayoutMode, locked: Bool) -> Bool {
        !(mode == .tabletop && locked)
    }
}
```

- [ ] **Step 4: Relancer les tests**

```bash
xcodegen generate
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'id=2E531329-FC54-453A-85D4-6E6C27F97314' -derivedDataPath build/DD-tests -skipPackagePluginValidation 2>&1 | tee $SCRATCH/test.log | grep -E "\*\* TEST|✘" | head
grep -c 'Suite "PlayerPostureLayout" passed' $SCRATCH/test.log
```
Expected: `** TEST SUCCEEDED **`, compteur ≥ 1.

- [ ] **Step 5: Commit**

```bash
git add Shared/Screens/VideoPlayer/PlayerPostureLayout.swift Tests/CinemaxKitTests/PlayerPostureLayoutTests.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(lecteur): décision pure du mode table du Duo"
```

---

### Task 2: Refactor neutre du HUD iOS (aucun changement visible)

But : rendre la mise en page commutable sans rien changer à l'écran. C'est la porte de non-régression des tâches suivantes.

**Files:**
- Modify: `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift` — `setupVideoView` (~1491), `setupControls` (~1500–1870), `buildIOSTransport` (~1880–2036), `setupSkipButton` (~1241), `showNextUpCard` (~1392)

**Interfaces:**
- Produces (dans `VLCStreamPresenter`, iOS) :
  - `private let videoArea = UILayoutGuide()` — regular : bords de `view` ; tabletop : moitié haute.
  - `private var videoAreaBottom: NSLayoutConstraint!` — la seule contrainte qui bascule pour la zone vidéo.
  - `private var regularHUDConstraints: [NSLayoutConstraint] = []`
  - `private var tabletopHUDConstraints: [NSLayoutConstraint] = []`
  - `private func makeRegularHUDConstraints() -> [NSLayoutConstraint]`
  - `private let statsContainer = UIView()` (hissé d'une `let` locale en propriété)
  - `private let statsLabel2 = UILabel()` (colonne droite, cachée en regular)

- [ ] **Step 1: Guide « zone vidéo »**

Dans `setupVideoView`, remplacer les quatre contraintes de `videoView` sur `view` par :

```swift
        view.addLayoutGuide(videoArea)
        let areaBottom = videoArea.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        videoAreaBottom = areaBottom
        NSLayoutConstraint.activate([
            videoArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoArea.topAnchor.constraint(equalTo: view.topAnchor),
            areaBottom,
            videoView.leadingAnchor.constraint(equalTo: videoArea.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: videoArea.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: videoArea.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: videoArea.bottomAnchor)
        ])
```

Puis remplacer `view.centerXAnchor` / `view.centerYAnchor` par `videoArea.centerXAnchor` / `videoArea.centerYAnchor` pour : `noticeView` (lignes ~1678, ~1682), `skipHUD` (~1725–1726), `loadingIndicator` (~1766–1767), `centerGlyph` et `skipGlyph` (~1784–1801). En regular la zone vidéo = la vue : rien ne bouge.

- [ ] **Step 2: Bouton « Passer » et carte « Épisode suivant » au-dessus du pli**

Dans `setupSkipButton`, remplacer la contrainte du bas par deux contraintes : l'existante (`= safe.bottom − 64`) passe en priorité `.defaultHigh`, et on ajoute un plafond obligatoire :

```swift
        let skipBottom = skipButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -64)
        skipBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            skipButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            skipBottom,
            // Mode table : reste sur l'écran du haut. En regular la zone vidéo
            // descend jusqu'au bas de la vue, ce plafond ne mord jamais.
            skipButton.bottomAnchor.constraint(lessThanOrEqualTo: videoArea.bottomAnchor, constant: -24)
        ])
```

Même traitement dans `showNextUpCard` pour `card.bottomAnchor` (−64 en `.defaultHigh` + `≤ videoArea.bottom − 24`).

- [ ] **Step 3: Hisser `statsContainer` et préparer la seconde colonne**

Dans `setupControls`, remplacer `let statsContainer = UIView()` par l'usage de la propriété `statsContainer`. Ajouter avant `statsContainer.addSubview(statsLabel)` :

```swift
        statsLabel2.translatesAutoresizingMaskIntoConstraints = false
        statsLabel2.numberOfLines = 0
        statsLabel2.textColor = .white
        statsLabel2.font = statsLabel.font
        statsLabel2.isHidden = true
```

et remplacer les deux contraintes `statsLabel.trailingAnchor` / `statsLabel.bottomAnchor` par un empilement horizontal :

```swift
        let statsColumns = UIStackView(arrangedSubviews: [statsLabel, statsLabel2])
        statsColumns.axis = .horizontal
        statsColumns.alignment = .top
        statsColumns.spacing = 18
        statsColumns.translatesAutoresizingMaskIntoConstraints = false
        statsContainer.addSubview(statsColumns)
        NSLayoutConstraint.activate([
            statsColumns.topAnchor.constraint(equalTo: statsContainer.topAnchor, constant: 10),
            statsColumns.bottomAnchor.constraint(equalTo: statsContainer.bottomAnchor, constant: -10),
            statsColumns.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor, constant: 14),
            statsColumns.trailingAnchor.constraint(equalTo: statsContainer.trailingAnchor, constant: -14)
        ])
```

(retirer l'ancien `statsContainer.addSubview(statsLabel)` et les quatre contraintes `statsLabel.*Anchor` du bloc existant ; garder celles de `statsContainer` sur `titleLabel` et `safe`). `statsLabel2` caché ⇒ la pile se réduit à `statsLabel` : identique à aujourd'hui.

- [ ] **Step 4: Sortir les contraintes déplaçables dans `makeRegularHUDConstraints()`**

Dans `buildIOSTransport`, retirer du grand `NSLayoutConstraint.activate([...])` toutes les contraintes de `closeButton`, de la grappe (`subtitleButton` … `statsButton`), `titleLabel.trailingAnchor ≤ statsButton.leadingAnchor − 12`, `slider`, `timeLabel`, `durationLabel`, `transportRow`, `chapterScroll` (leading / trailing / bottom), et les déplacer telles quelles dans :

```swift
    /// Le HUD de toujours. Reconstruit à chaque passage en regular : la mise en
    /// page table en change les mêmes vues de place.
    private func makeRegularHUDConstraints() -> [NSLayoutConstraint] {
        let safe = view.safeAreaLayoutGuide
        let cSafe = controlsContainer.safeAreaLayoutGuide
        return [
            closeButton.trailingAnchor.constraint(equalTo: cSafe.trailingAnchor, constant: -12),
            closeButton.topAnchor.constraint(equalTo: cSafe.topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsButton.leadingAnchor, constant: -12),
            subtitleButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            subtitleButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            audioButton.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -4),
            audioButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            pipButton.trailingAnchor.constraint(equalTo: audioButton.leadingAnchor, constant: -4),
            pipButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            speedButton.trailingAnchor.constraint(equalTo: pipButton.leadingAnchor, constant: -4),
            speedButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            statsButton.trailingAnchor.constraint(equalTo: speedButton.leadingAnchor, constant: -4),
            statsButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            slider.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            slider.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -22),
            timeLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            timeLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -8),
            durationLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            durationLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -8),
            transportRow.centerXAnchor.constraint(equalTo: controlsContainer.centerXAnchor),
            transportRow.bottomAnchor.constraint(equalTo: timeLabel.topAnchor, constant: -16),
            chapterScroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            chapterScroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            chapterScroll.bottomAnchor.constraint(equalTo: transportRow.topAnchor, constant: -16)
        ]
    }
```

À la fin de `buildIOSTransport` :

```swift
        regularHUDConstraints = makeRegularHUDConstraints()
        NSLayoutConstraint.activate(regularHUDConstraints)
```

Les contraintes internes de `chapterStack` et celles de `scrubPreview` restent où elles sont (elles suivent `slider` / `timeLabel`).

- [ ] **Step 5: Compiler (Xcode 27.0 = CI) et lancer toute la suite**

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DD-x270 -skipPackagePluginValidation 2>&1 | grep -E "error:|\*\* BUILD" | head
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'generic/platform=tvOS Simulator' -derivedDataPath build/DD-iae-tv -skipPackagePluginValidation 2>&1 | grep -E "error:|\*\* BUILD" | head
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'id=2E531329-FC54-453A-85D4-6E6C27F97314' -derivedDataPath build/DD-tests -skipPackagePluginValidation 2>&1 | tee $SCRATCH/test.log | grep -E "\*\* TEST|✘" | head
```
Expected: deux `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Contrôle visuel de non-régression**

Installer sur l'iPhone 17 Pro (D5222D2F, compte démo), ouvrir Sintel, HUD affiché : capture portrait et paysage (`xcrun simctl io D5222D2F-A253-4D88-99C2-1FBC01402D42 screenshot …`). Comparer à une capture faite depuis `main` avant la tâche : mêmes positions de la grappe, du titre, des chapitres, de la rangée de lecture, du curseur, des statistiques (activées).

- [ ] **Step 7: Commit**

```bash
git add Shared/Screens/VideoPlayer/VLCStreamPresenter.swift
git commit -m "refactor(lecteur): zone vidéo et contraintes du HUD commutables, sans changement visible"
```

---

### Task 3: Charnière et bascule de la mise en page (zone vidéo, fond, voile)

**Files:**
- Modify: `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift` — `viewDidLoad` (~631), `viewDidLayoutSubviews` (~2911), `setupGestures` (~2074), `handleTap` (~4145)

**Interfaces:**
- Consumes: `PlayerPostureLayout`, `HingeReading`, `PlayerLayoutMode` (Task 1) ; `videoArea`, `videoAreaBottom`, `regularHUDConstraints`, `tabletopHUDConstraints`, `makeRegularHUDConstraints()` (Task 2).
- Produces:
  - Dans le présentateur : `private var hingeReading: HingeReading = .unknown`, `private var layoutMode: PlayerLayoutMode = .regular`, `private let tabletopBackdrop = UIView()` (fond noir de la moitié basse, SOUS la vue vidéo : le reflet du miroir de Task 5 se dessine par-dessus), `private let deckTint = UIView()`, `private func applyLayoutMode()`, `private func makeTabletopHUDConstraints() -> [NSLayoutConstraint]` (version provisoire ici, complétée en Task 4).

- [ ] **Step 1: Pas de nouveau fichier ici**

Le fond de la moitié basse est une simple `UIView` noire. Il est placé SOUS `videoView` : en Task 5, la copie miroir de la vidéo est dessinée par la couche de `videoView` hors de ses limites, donc au-dessus de ce fond.

- [ ] **Step 2: Ajouter les vues et l'interaction charnière dans le présentateur**

Propriétés (iOS) :

```swift
    #if os(iOS)
    private var hingeReading: HingeReading = .unknown
    private var layoutMode: PlayerLayoutMode = .regular
    private let tabletopBackdrop = UIView()
    /// Teinte de la dalle, DANS `controlsContainer` : s'efface avec le HUD,
    /// laissant le noir pur du fond (`tabletopBackdrop`) et le halo.
    private let deckTint = UIView()
    private var tabletopBackdropConstraints: [NSLayoutConstraint] = []
    #endif
```

Dans `viewDidLoad`, juste après `setupVideoView()` :

```swift
        #if os(iOS)
        tabletopBackdrop.translatesAutoresizingMaskIntoConstraints = false
        tabletopBackdrop.backgroundColor = .black
        tabletopBackdrop.isHidden = true
        view.insertSubview(tabletopBackdrop, belowSubview: videoView)
        NSLayoutConstraint.activate([
            tabletopBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabletopBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabletopBackdrop.topAnchor.constraint(equalTo: view.centerYAnchor),
            tabletopBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        #if !NO_HINGE_API
        if #available(iOS 27.1, *) {
            view.addInteraction(UIHingeInteraction { [weak self] _, update in
                self?.hingeChanged(update.hinge.map { HingeReading($0.status) })
            })
        }
        #endif
        #endif
```

Et après `setupControls()` (le conteneur existe) :

```swift
        #if os(iOS)
        deckTint.translatesAutoresizingMaskIntoConstraints = false
        deckTint.backgroundColor = UIColor.white.withAlphaComponent(0.04)
        deckTint.isUserInteractionEnabled = false
        deckTint.isHidden = true
        controlsContainer.insertSubview(deckTint, at: 0)
        NSLayoutConstraint.activate([
            deckTint.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor),
            deckTint.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor),
            deckTint.topAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            deckTint.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor)
        ])
        #endif
```

Hors de la classe, dans le même fichier :

```swift
#if os(iOS) && !NO_HINGE_API
@available(iOS 27.1, *)
extension HingeReading {
    init(_ status: UIHinge.Status) {
        switch status {
        case .closed: self = .closed
        case .partiallyOpen: self = .partiallyOpen
        case .fullyOpen: self = .fullyOpen
        default: self = .unknown
        }
    }
}
#endif
```

- [ ] **Step 3: La bascule**

```swift
    #if os(iOS)
    private func hingeChanged(_ update: HingeReading?) {
        hingeReading = PlayerPostureLayout.reading(previous: hingeReading, update: update)
        applyLayoutMode()
    }

    /// Seul point d'entrée des deux mises en page. Idempotent : appelé par la
    /// charnière, par chaque passe de mise en page (la taille change à la
    /// rotation) et quand les chapitres arrivent (le bloc Chapitres apparaît).
    private func applyLayoutMode(force: Bool = false) {
        let mode = PlayerPostureLayout.mode(hinge: hingeReading, viewSize: view.bounds.size)
        guard force || mode != layoutMode else { return }
        layoutMode = mode
        let tabletop = mode == .tabletop
        NSLayoutConstraint.deactivate(regularHUDConstraints + tabletopHUDConstraints)
        videoAreaBottom.isActive = false
        videoAreaBottom = videoArea.bottomAnchor.constraint(equalTo: tabletop ? view.centerYAnchor : view.bottomAnchor)
        videoAreaBottom.isActive = true
        if tabletop {
            tabletopHUDConstraints = makeTabletopHUDConstraints()
            NSLayoutConstraint.activate(tabletopHUDConstraints)
        } else {
            regularHUDConstraints = makeRegularHUDConstraints()
            NSLayoutConstraint.activate(regularHUDConstraints)
        }
        tabletopBackdrop.isHidden = !tabletop
        deckTint.isHidden = !tabletop
        // Pas de voile à 45 % sur la vidéo du haut : la dalle a son propre fond.
        controlsContainer.backgroundColor = tabletop ? .clear : .black.withAlphaComponent(0.45)
        applyHUDStyle()
        UIView.animate(withDuration: 0.3) { self.view.layoutIfNeeded() }
        if controlsVisible { scheduleHideControls() }
    }

    /// Provisoire (complété en Task 4) : la dalle vide, le HUD de toujours caché.
    private func makeTabletopHUDConstraints() -> [NSLayoutConstraint] { makeRegularHUDConstraints() }
    private func applyHUDStyle() {}
    #endif
```

Dans `viewDidLayoutSubviews` (iOS) : appeler `applyLayoutMode()` **avant** `layoutTransportRow()`, et sortir de `layoutTransportRow()` en mode table :

```swift
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyLayoutMode()
        layoutTransportRow()
    }
```

et en tête de `layoutTransportRow()` :

```swift
        // Mode table : les blocs fixent leurs largeurs, le recalage de PR #281
        // (espacement puis échelle) se battrait contre eux.
        guard layoutMode == .regular else {
            transportRow.transform = .identity
            return
        }
```

- [ ] **Step 4: Toucher l'écran du bas pour réafficher la dalle**

Dans `setupGestures` (iOS), ajouter :

```swift
        // Mode table : toucher l'écran du bas bascule la dalle (pas de double
        // toucher pour avancer / reculer ici : ce n'est pas la vidéo).
        let deckTap = UITapGestureRecognizer(target: self, action: #selector(handleDeckTap))
        tabletopBackdrop.addGestureRecognizer(deckTap)
```

```swift
    @objc private func handleDeckTap() {
        if controlsVisible {
            if PlayerPostureLayout.tapHides(mode: layoutMode, locked: hudLocked) { hideControlsImmediately() }
        } else {
            showControls(); scheduleHideControls()
        }
    }
```

Même règle dans `handleTap` (toucher simple sur la vidéo), dans le bloc différé :

```swift
            if self.controlsVisible {
                if PlayerPostureLayout.tapHides(mode: self.layoutMode, locked: self.hudLocked) {
                    self.hideControlsImmediately()
                }
            } else { self.showControls(); self.scheduleHideControls() }
```

(`hudLocked` est introduit en Task 4 ; jusque-là, déclarer `private var hudLocked = false` ici et le brancher sur le réglage en Task 4.) `controlsContainer` est un `PassthroughView` et le voile du halo (Task 5) n'est pas interactif : les touchers hors des boutons, dans la moitié basse, tombent sur `tabletopBackdrop` (la vue vidéo, réduite à la moitié haute, ne les reçoit pas).

- [ ] **Step 5: Compiler avec les deux Xcode, installer sur le Duo**

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DD-x270 -skipPackagePluginValidation 2>&1 | grep -E "error:|\*\* BUILD" | head
set -o pipefail; DEVELOPER_DIR=/Applications/Xcode-27.1-RC.app/Contents/Developer xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'id=29BF9705-0E75-43E4-8433-C18666916ABF' -derivedDataPath build/DD-duo -skipPackagePluginValidation 2>&1 | grep -E "error:|\*\* BUILD" | head
xcrun simctl install 29BF9705-0E75-43E4-8433-C18666916ABF build/DD-duo/Build/Products/Debug-iphonesimulator/Cinemax.app && xcrun simctl launch 29BF9705-0E75-43E4-8433-C18666916ABF com.cinemax.ios
```

Expected : deux `** BUILD SUCCEEDED **`. Avec l'utilisateur (le simulateur ne se plie pas en ligne de commande) : Sintel en lecture, plier à moitié en portrait ⇒ vidéo centrée dans la moitié haute, moitié basse noire, HUD de toujours encore par-dessus (provisoire) ; déplier ⇒ lecteur actuel.

- [ ] **Step 6: Commit**

```bash
git add Shared/Screens/VideoPlayer/VLCStreamPresenter.swift
git commit -m "feat(lecteur): charnière du Duo, vidéo sur l'écran du haut en posture table"
```

---

### Task 4: La dalle — blocs, cadenas, menu Statistiques, chapitres

**Files:**
- Create: `Shared/Screens/VideoPlayer/TabletopHUDStyle.swift`
- Modify: `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift` — `buildIOSTransport`, `setPlayPauseIcon` (~4378), `selectAudioTrack` / `selectSubtitleTrack` / `setPlaybackRate` (~3189–3251), `applyServerTrackDefaultsIfNeeded`, `fetchChapters` (~2600), `scheduleHideControls` (~4397), `toggleStats` (~3301)
- Modify: `Shared/DesignSystem/SettingsKeys.swift`, `Resources/{fr,en,de}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `applyLayoutMode()`, `layoutMode`, `deckTint`, `tabletopBackdrop` (Task 3) ; `PlayerPostureLayout.autoHides` (Task 1) . `tabletopItemDetail` appelle `TabletopHalo.qualityLabel(width:)` de Task 5 : jusqu'à Task 5, y mettre provisoirement `nil` à la place de la définition.
- Produces:
  - `enum TabletopHUDStyle` : `static func block(symbol: String, pointSize: CGFloat, title: String? = nil, subtitle: String? = nil, emphasized: Bool = false) -> UIButton.Configuration`, `static func lock(locked: Bool, accent: UIColor) -> UIButton.Configuration`, `static func titleBlock(title: String, subtitle: String?, thumbnail: UIImage?) -> UIButton.Configuration`, `static let blockFill`, `static let cornerRadius: CGFloat = 20`.
  - Présentateur : `lockButton`, `titleBlockButton`, `chaptersButton`, `scrubBlock`, `chapterTitles: [String]`, `tabletopItemDetail: String?`, `tabletopThumbnail: UIImage?`, `hudLocked: Bool`, `refreshTabletopValues()`.
  - `SettingsKey.playerTabletopHUDLocked`, `SettingsKey.Default.playerTabletopHUDLocked`.

- [ ] **Step 1: Clé de réglage et chaînes**

`SettingsKeys.swift`, à côté de `autoPlayNextEpisode` :

```swift
    /// Cadenas de la dalle du lecteur en posture table (iPhone Duo) : `true` =
    /// la dalle ne se masque plus toute seule. Mémorisé d'une vidéo à l'autre.
    static let playerTabletopHUDLocked = "player.tabletopHUDLocked"
```

et dans `Default` :

```swift
        static let playerTabletopHUDLocked = false
```

`Resources/fr.lproj/Localizable.strings` :

```
"player.tabletop.lock.locked" = "Commandes verrouillées, toujours affichées";
"player.tabletop.lock.unlocked" = "Commandes masquées automatiquement";
```

`en.lproj` :

```
"player.tabletop.lock.locked" = "Controls locked, always shown";
"player.tabletop.lock.unlocked" = "Controls hide automatically";
```

`de.lproj` :

```
"player.tabletop.lock.locked" = "Steuerelemente gesperrt, immer sichtbar";
"player.tabletop.lock.unlocked" = "Steuerelemente werden automatisch ausgeblendet";
```

- [ ] **Step 2: `TabletopHUDStyle`**

```swift
#if os(iOS)
import UIKit

/// Les blocs de la dalle du lecteur en posture table (maquette « Pupitre »).
/// Configurations seulement : les boutons, leurs actions et leurs libellés
/// VoiceOver restent ceux du HUD de toujours.
enum TabletopHUDStyle {
    static let blockFill = UIColor.white.withAlphaComponent(0.075)
    static let emphasizedFill = UIColor.white.withAlphaComponent(0.13)
    static let cornerRadius: CGFloat = 20

    static func block(symbol: String, pointSize: CGFloat, title: String? = nil,
                      subtitle: String? = nil, emphasized: Bool = false) -> UIButton.Configuration {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: symbol,
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        cfg.baseForegroundColor = .white
        cfg.background.backgroundColor = emphasized ? emphasizedFill : blockFill
        cfg.background.cornerRadius = cornerRadius
        cfg.cornerStyle = .fixed
        if let title {
            cfg.imagePlacement = .top
            cfg.imagePadding = 5
            cfg.title = title
            cfg.titleAlignment = .center
            cfg.titleLineBreakMode = .byTruncatingTail
            cfg.titleTextAttributesTransformer = .init { a in
                var a = a; a.font = .systemFont(ofSize: 12, weight: .semibold); return a
            }
            cfg.subtitle = subtitle
            cfg.subtitleLineBreakMode = .byTruncatingTail
            cfg.subtitleTextAttributesTransformer = .init { a in
                var a = a; a.font = .systemFont(ofSize: 11); return a
            }
        }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
        return cfg
    }

    /// Ouvert : icône en couleur d'accent. Fermé : icône blanche — le bloc ne
    /// prend jamais l'accent, il resterait allumé en permanence.
    static func lock(locked: Bool, accent: UIColor) -> UIButton.Configuration {
        var cfg = block(symbol: locked ? "lock.fill" : "lock.open.fill", pointSize: 20)
        cfg.baseForegroundColor = locked ? .white : accent
        return cfg
    }

    static func titleBlock(title: String, subtitle: String?, thumbnail: UIImage?) -> UIButton.Configuration {
        var cfg = UIButton.Configuration.plain()
        cfg.baseForegroundColor = .white
        cfg.background.backgroundColor = blockFill
        cfg.background.cornerRadius = cornerRadius
        cfg.cornerStyle = .fixed
        cfg.title = title
        cfg.titleLineBreakMode = .byTruncatingTail
        cfg.titleTextAttributesTransformer = .init { a in
            var a = a; a.font = .systemFont(ofSize: 17, weight: .semibold); return a
        }
        cfg.subtitle = subtitle
        cfg.subtitleTextAttributesTransformer = .init { a in
            var a = a; a.font = .systemFont(ofSize: 13); a.foregroundColor = UIColor.white.withAlphaComponent(0.62); return a
        }
        cfg.image = thumbnail.map(Self.roundedThumbnail)
        cfg.imagePlacement = .leading
        cfg.imagePadding = 14
        cfg.indicator = .popup
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 16)
        return cfg
    }

    /// 82 × 46 pt, coins de 10 pt — la vignette de la barre du film.
    private static func roundedThumbnail(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 82, height: 46)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10).addClip()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif
```

- [ ] **Step 3: Nouveaux contrôles de la dalle**

Propriétés (iOS) :

```swift
    private let lockButton = UIButton(type: .system)
    private let titleBlockButton = UIButton(type: .system)
    private let chaptersButton = UIButton(type: .system)
    /// Fond du bloc curseur (le curseur et les deux temps sont posés dessus).
    private let scrubBlock = UIView()
    private var chapterTitles: [String] = []
    /// « 2010 », « 15 min » — remplis par `fetchChapters` (même `getItem`) ;
    /// la définition s'y ajoute à l'affichage, lue sur la piste vidéo en lecture.
    private var tabletopItemBase: [String] = []
    private var tabletopItemDetail: String? {
        let width = (player.videoTracks.first(where: { $0.isSelected }) ?? player.videoTracks.first)?.width
        let parts = tabletopItemBase + [width.map(TabletopHalo.qualityLabel(width:))].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// Miniature du film pour le bloc titre, capturée à chaque apparition de la dalle (Task 5).
    private var tabletopThumbnail: UIImage?
    // (remplace la déclaration provisoire de Task 3)
    private var hudLocked = UserDefaults.standard.bool(forKey: SettingsKey.playerTabletopHUDLocked)
```

À la fin de `buildIOSTransport`, avant `regularHUDConstraints = …` :

```swift
        for b in [lockButton, titleBlockButton, chaptersButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.isHidden = true
            controlsContainer.addSubview(b)
        }
        lockButton.addTarget(self, action: #selector(toggleHUDLock), for: .touchUpInside)
        chaptersButton.addTarget(self, action: #selector(openChapterMenu), for: .touchUpInside)
        chaptersButton.accessibilityLabel = loc.localized("player.chapters")
        titleBlockButton.showsMenuAsPrimaryAction = true
        titleBlockButton.accessibilityLabel = titleText
        scrubBlock.translatesAutoresizingMaskIntoConstraints = false
        scrubBlock.backgroundColor = TabletopHUDStyle.blockFill
        scrubBlock.layer.cornerRadius = TabletopHUDStyle.cornerRadius
        scrubBlock.isUserInteractionEnabled = false
        scrubBlock.isHidden = true
        controlsContainer.insertSubview(scrubBlock, belowSubview: slider)
```

Dans `fetchChapters`, à côté de `self.chapterStartTicks = …` :

```swift
            self.chapterTitles = chapters.enumerated().map { i, ch in
                (ch.name?.isEmpty == false ? ch.name : nil) ?? "\(self.loc.localized("player.chapter")) \(i + 1)"
            }
```

(remettre `chapterTitles = []` là où `chapterStartTicks = []` est remis à zéro, ligne ~2566). Juste avant le `guard let chapters = item.chapters` (le `item` y est déjà décodé), remplir le détail du bloc titre :

```swift
            #if os(iOS)
            self.tabletopItemBase = [item.productionYear.map(String.init),
                                     item.runTimeTicks.map { self.loc.runtime(minutes: $0.jellyfinMinutes) }]
                .compactMap { $0 }
            self.refreshTabletopValues()
            #endif
```

et, après la boucle qui crée les puces de chapitre :

```swift
            #if os(iOS)
            self.applyLayoutMode(force: true)   // le bloc Chapitres apparaît
            #endif
```

(Vérifier à l'exécution que `loc.runtime(minutes:)` et `jellyfinMinutes` sont accessibles depuis le présentateur — ils le sont dans `LibraryHeroSection` ; sinon utiliser `PlayerTimeFormat` sur `runTimeTicks / 10_000`.)

Actions :

```swift
    @objc private func toggleHUDLock() {
        hudLocked.toggle()
        UserDefaults.standard.set(hudLocked, forKey: SettingsKey.playerTabletopHUDLocked)
        refreshTabletopValues()
        if hudLocked { hideControlsWorkItem?.cancel() } else { scheduleHideControls() }
    }

    @objc private func openChapterMenu() {
        let current = PlayerChapterSelection.currentIndex(
            startTicks: chapterStartTicks, positionTicks: Int(currentMs) * 10_000)
        let opts: [(String, Bool, () -> Void)] = chapterTitles.enumerated().map { i, title in
            let ms = Int32(clamping: chapterStartTicks[i] / 10_000)
            return ("\(title) — \(PlayerTimeFormat.ms(ms))", i == current, { [weak self] in
                self?.seeks.accumulate(toAbsoluteMs: ms)
            })
        }
        presentPicker(loc.localized("player.chapters"), sourceView: chaptersButton, opts)
    }
```

(`currentMs` et `seeks.accumulate(toAbsoluteMs:)` sont ceux qu'utilisent déjà `selectAudioTrack` et `chapterChipTapped`.)

- [ ] **Step 4: Cadenas dans le masquage automatique**

En tête de `scheduleHideControls()`, après `hideControlsWorkItem?.cancel()` :

```swift
        #if os(iOS)
        if !PlayerPostureLayout.autoHides(mode: layoutMode, locked: hudLocked) { return }
        #endif
```

- [ ] **Step 5: Styles des deux modes et valeurs affichées**

Remplacer la `applyHUDStyle()` provisoire de Task 3 :

```swift
    /// Habille les MÊMES boutons pour le mode courant. Regular = les réglages
    /// de `buildIOSTransport`, rejoués à l'identique.
    private func applyHUDStyle() {
        let tabletop = layoutMode == .tabletop
        for b in [lockButton, titleBlockButton] { b.isHidden = !tabletop }
        chaptersButton.isHidden = !tabletop || chapterStartTicks.count <= 1
        scrubBlock.isHidden = !tabletop
        statsButton.isHidden = tabletop          // passe dans le menu du bloc titre
        chapterScroll.alpha = tabletop ? 0 : 1   // remplacé par le bloc Chapitres
        titleLabel.alpha = tabletop ? 0 : 1      // remplacé par le bloc titre ; garde sa place (la bande de présence s'y accroche)
        transportRow.alignment = tabletop ? .fill : .center
        transportRow.spacing = tabletop ? 10 : 24
        if tabletop {
            // `configureIOS` fige la largeur intrinsèque (priorité `.required`) ;
            // la dalle impose des largeurs égales : on relâche, le mode regular
            // les refige en rappelant `configureIOS`.
            for b in [subtitleButton, audioButton, speedButton, chaptersButton, pipButton,
                      prevButton, skipBackButton, playPauseButton, skipFwdButton, nextButton, closeButton] {
                b.setContentHuggingPriority(.defaultLow, for: .horizontal)
                b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            closeButton.configuration = TabletopHUDStyle.block(symbol: "xmark", pointSize: 18)
            prevButton.configuration = TabletopHUDStyle.block(symbol: "backward.end.fill", pointSize: 26)
            nextButton.configuration = TabletopHUDStyle.block(symbol: "forward.end.fill", pointSize: 26)
            skipBackButton.configuration = TabletopHUDStyle.block(symbol: PlayerSkipConfig.backwardSymbol, pointSize: 38)
            skipFwdButton.configuration = TabletopHUDStyle.block(symbol: PlayerSkipConfig.forwardSymbol, pointSize: 38)
            pipButton.configuration = TabletopHUDStyle.block(symbol: "pip.enter", pointSize: 22, title: loc.localized("player.pip"))
        } else {
            var closeConfig = UIButton.Configuration.plain()
            closeConfig.image = UIImage(systemName: "xmark",
                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
            closeConfig.baseForegroundColor = .white
            closeConfig.background.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            closeConfig.cornerStyle = .capsule
            closeConfig.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 15, bottom: 15, trailing: 15)
            closeButton.configuration = closeConfig
            configureIOS(prevButton, "backward.end.fill", pt: 24, loc.localized("player.previousEpisode"))
            configureIOS(nextButton, "forward.end.fill", pt: 24, loc.localized("player.nextEpisode"))
            configureIOS(skipBackButton, PlayerSkipConfig.backwardSymbol, pt: 30, hudA11y.skipBack)
            configureIOS(skipFwdButton, PlayerSkipConfig.forwardSymbol, pt: 30, hudA11y.skipForward)
            configureIOS(pipButton, "pip.enter", pt: 17, loc.localized("player.pip"), compact: true)
            configureIOS(audioButton, "waveform", pt: 17, loc.localized("player.audio"), compact: true)
            configureIOS(subtitleButton, "captions.bubble", pt: 17, loc.localized("player.subtitles"), compact: true)
            configureIOS(speedButton, "gauge.with.needle", pt: 17, loc.localized("player.speed"), compact: true)
        }
        setPlayPauseIcon(playing: player.isPlaying)
        refreshTabletopValues()
    }

    /// Valeurs affichées par les blocs (piste, vitesse, cadenas, titre).
    /// Appelée par chaque écrivain de ces valeurs ; sans effet en regular.
    private func refreshTabletopValues() {
        guard layoutMode == .tabletop else { return }
        let subValue: String = {
            guard let t = player.selectedSubtitleTrack,
                  let i = player.subtitleTracks.firstIndex(of: t) else { return loc.localized("player.subtitles.off") }
            return displayLabel(forSubtitleOrdinal: i, track: t)
        }()
        let audioValue: String? = {
            guard let t = player.selectedAudioTrack,
                  let i = player.audioTracks.firstIndex(of: t) else { return nil }
            return displayLabel(forAudioOrdinal: i, track: t)
        }()
        subtitleButton.configuration = TabletopHUDStyle.block(symbol: "captions.bubble", pointSize: 22,
                                                              title: loc.localized("player.subtitles"), subtitle: subValue)
        audioButton.configuration = TabletopHUDStyle.block(symbol: "waveform", pointSize: 22,
                                                           title: loc.localized("player.audio"), subtitle: audioValue)
        speedButton.configuration = TabletopHUDStyle.block(symbol: "gauge.with.needle", pointSize: 22,
                                                           title: loc.localized("player.speed"),
                                                           subtitle: String(format: "%g×", playbackRate))
        chaptersButton.configuration = TabletopHUDStyle.block(symbol: "list.bullet", pointSize: 22,
                                                              title: loc.localized("player.chapters"))
        lockButton.configuration = TabletopHUDStyle.lock(locked: hudLocked, accent: Self.accentColor())
        lockButton.accessibilityLabel = loc.localized(hudLocked ? "player.tabletop.lock.locked" : "player.tabletop.lock.unlocked")
        titleBlockButton.configuration = TabletopHUDStyle.titleBlock(title: titleText, subtitle: tabletopItemDetail,
                                                                     thumbnail: tabletopThumbnail)
        titleBlockButton.menu = UIMenu(children: [
            UIAction(title: loc.localized("player.stats"), image: UIImage(systemName: "chart.xyaxis.line"),
                     state: statsVisible ? .on : .off) { [weak self] _ in self?.toggleStats() }
        ])
    }
```

`Self.accentColor()` est la fonction existante (VSP ~3880) qui colore déjà la bande de présence (`option.palette.accentDark`).

Dans `setPlayPauseIcon(playing:)`, remplacer le `pointSize: 44` par `pointSize: layoutMode == .tabletop ? 54 : 44` et, en mode table, garder le fond du bloc :

```swift
        #if os(iOS)
        if layoutMode == .tabletop {
            config = TabletopHUDStyle.block(symbol: playing ? "pause.fill" : "play.fill", pointSize: 54, emphasized: true)
        }
        #endif
```

(placé après la lecture de `config` et avant `playPauseButton.configuration = config`.) `toggleStats()` doit appeler `refreshTabletopValues()` pour recocher le menu. Appeler aussi `refreshTabletopValues()` à la fin de `selectAudioTrack`, `selectSubtitleTrack`, `setPlaybackRate` et `applyServerTrackDefaultsIfNeeded`.

- [ ] **Step 6: Les contraintes de la dalle**

Remplacer la `makeTabletopHUDConstraints()` provisoire :

```swift
    /// La dalle : moitié basse, marges de 18 pt, rangées de 10 pt d'écart —
    /// barre du film (66) · lecture (le reste) · curseur (58) · réglages (86).
    private func makeTabletopHUDConstraints() -> [NSLayoutConstraint] {
        let safe = view.safeAreaLayoutGuide
        let top = controlsContainer.centerYAnchor
        let lead = safe.leadingAnchor, trail = safe.trailingAnchor
        var c: [NSLayoutConstraint] = [
            // Barre du film
            lockButton.topAnchor.constraint(equalTo: top, constant: 18),
            lockButton.leadingAnchor.constraint(equalTo: lead, constant: 18),
            lockButton.widthAnchor.constraint(equalToConstant: 66),
            lockButton.heightAnchor.constraint(equalToConstant: 66),
            closeButton.topAnchor.constraint(equalTo: lockButton.topAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trail, constant: -18),
            closeButton.widthAnchor.constraint(equalToConstant: 66),
            closeButton.heightAnchor.constraint(equalToConstant: 66),
            titleBlockButton.topAnchor.constraint(equalTo: lockButton.topAnchor),
            titleBlockButton.heightAnchor.constraint(equalToConstant: 66),
            titleBlockButton.leadingAnchor.constraint(equalTo: lockButton.trailingAnchor, constant: 10),
            titleBlockButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            // Lecture : la rangée remplit l'espace restant ; −10 / +10 de même
            // largeur, lecture 1,45×, épisodes 0,55× (masqués s'il n'y en a pas).
            transportRow.topAnchor.constraint(equalTo: lockButton.bottomAnchor, constant: 10),
            transportRow.leadingAnchor.constraint(equalTo: lead, constant: 18),
            transportRow.trailingAnchor.constraint(equalTo: trail, constant: -18),
            transportRow.bottomAnchor.constraint(equalTo: scrubBlock.topAnchor, constant: -10),
            skipFwdButton.widthAnchor.constraint(equalTo: skipBackButton.widthAnchor),
            playPauseButton.widthAnchor.constraint(equalTo: skipBackButton.widthAnchor, multiplier: 1.45),
            prevButton.widthAnchor.constraint(equalTo: skipBackButton.widthAnchor, multiplier: 0.55),
            nextButton.widthAnchor.constraint(equalTo: skipBackButton.widthAnchor, multiplier: 0.55),
            // Curseur
            scrubBlock.leadingAnchor.constraint(equalTo: lead, constant: 18),
            scrubBlock.trailingAnchor.constraint(equalTo: trail, constant: -18),
            scrubBlock.heightAnchor.constraint(equalToConstant: 58),
            scrubBlock.bottomAnchor.constraint(equalTo: subtitleButton.topAnchor, constant: -10),
            timeLabel.leadingAnchor.constraint(equalTo: scrubBlock.leadingAnchor, constant: 20),
            timeLabel.centerYAnchor.constraint(equalTo: scrubBlock.centerYAnchor),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            durationLabel.trailingAnchor.constraint(equalTo: scrubBlock.trailingAnchor, constant: -20),
            durationLabel.centerYAnchor.constraint(equalTo: scrubBlock.centerYAnchor),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            slider.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -16),
            slider.centerYAnchor.constraint(equalTo: scrubBlock.centerYAnchor),
            // Le titre caché garde la place de toujours : la bande « Regarder
            // ensemble » et l'encart Statistiques s'y accrochent (écran du haut).
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trail, constant: -24),
            // Les chapitres en bande sont cachés ; on les laisse au-dessus de la rangée.
            chapterScroll.leadingAnchor.constraint(equalTo: lead, constant: 16),
            chapterScroll.trailingAnchor.constraint(equalTo: trail, constant: -16),
            chapterScroll.bottomAnchor.constraint(equalTo: transportRow.topAnchor, constant: -16)
        ]
        // Réglages : blocs de même largeur, le bloc Chapitres seulement s'il y a des chapitres.
        let settings: [UIButton] = [subtitleButton, audioButton, speedButton]
            + (chapterStartTicks.count > 1 ? [chaptersButton] : [])
            + [pipButton]
        for (i, b) in settings.enumerated() {
            c.append(b.heightAnchor.constraint(equalToConstant: 86))
            c.append(b.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -22))
            c.append(i == 0
                ? b.leadingAnchor.constraint(equalTo: lead, constant: 18)
                : b.leadingAnchor.constraint(equalTo: settings[i - 1].trailingAnchor, constant: 10))
            if i > 0 { c.append(b.widthAnchor.constraint(equalTo: settings[0].widthAnchor)) }
        }
        c.append(settings.last!.trailingAnchor.constraint(equalTo: trail, constant: -18))
        return c
    }
```

- [ ] **Step 7: Compiler (deux Xcode), toute la suite, puis recette au Duo**

Mêmes commandes que Task 3 Step 5, plus la suite de tests (Task 2 Step 5). Recette avec l'utilisateur, Duo plié à moitié en portrait, Sintel :
- la dalle reproduit la maquette (barre du film, lecture, curseur, 5 réglages) ;
- chaque bloc agit (lecture/pause, ±10 s, curseur, sous-titres, audio, vitesse, chapitres, PiP, fermer) ;
- cadenas ouvert : la dalle se masque après 4 s ; fermé : elle reste ; état retrouvé à la vidéo suivante ;
- bloc titre : menu « Statistiques » cochable ;
- déplier : lecteur actuel intact (comparer à la capture de Task 2 Step 6).

- [ ] **Step 8: Commit**

```bash
xcodegen generate
git add Shared/Screens/VideoPlayer/TabletopHUDStyle.swift Shared/Screens/VideoPlayer/VLCStreamPresenter.swift Shared/DesignSystem/SettingsKeys.swift Resources/*.lproj/Localizable.strings Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(lecteur): dalle de blocs du mode table, cadenas mémorisé, menu Statistiques"
```

---

### Task 5: Le halo en direct et la vignette du bloc titre

**Files:**
- Create: `Shared/Screens/VideoPlayer/TabletopHalo.swift`
- Modify: `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift` — déclaration de `videoView` (~210), `viewDidLoad`, `applyLayoutMode`, `showControls` (~4423)

**Interfaces:**
- Consumes: `layoutMode`, `applyLayoutMode()`, `tabletopBackdrop` (Task 3) ; `tabletopThumbnail`, `refreshTabletopValues()` (Task 4).
- Produces:
  - `final class MirroringVideoView: UIView` — `func setMirror(enabled: Bool, pictureHeight: CGFloat, gapBelowFold: CGFloat)`.
  - `final class TabletopHaloVeil: UIView` — non interactif.
  - `enum TabletopHalo` — `static let opacity: Float = 0.38`, `static func thumbnail(of view: UIView, videoAspect: CGFloat?) -> UIImage?`, `static func qualityLabel(width: Int) -> String`, `static func pictureHeight(viewSize: CGSize, videoAspect: CGFloat?) -> CGFloat`.

- [ ] **Step 1: Test de `qualityLabel` et `pictureHeight` (purs)**

Ajouter à `Tests/CinemaxKitTests/PlayerPostureLayoutTests.swift` (sous `#if os(iOS)`, `TabletopHalo` est iOS) :

```swift
#if os(iOS)
@Suite("TabletopHalo")
struct TabletopHaloTests {
    @Test("définition affichée d'après la largeur de la piste vidéo")
    func quality() {
        #expect(TabletopHalo.qualityLabel(width: 4096) == "4K")
        #expect(TabletopHalo.qualityLabel(width: 3840) == "4K")
        #expect(TabletopHalo.qualityLabel(width: 1920) == "1080p")
        #expect(TabletopHalo.qualityLabel(width: 1280) == "720p")
        #expect(TabletopHalo.qualityLabel(width: 720) == "SD")
    }

    @Test("hauteur de l'image ajustée dans la moitié haute")
    func pictureHeight() {
        let half = CGSize(width: 700, height: 500)
        #expect(TabletopHalo.pictureHeight(viewSize: half, videoAspect: 2.35) == (700 / 2.35).rounded())
        #expect(TabletopHalo.pictureHeight(viewSize: half, videoAspect: 1.0) == 500)   // plus haut que large : bornée
        #expect(TabletopHalo.pictureHeight(viewSize: half, videoAspect: nil) == (700 / (16.0 / 9.0)).rounded())
    }
}
#endif
```

Lancer la suite (commande de Task 1 Step 4) : échec de compilation attendu (`TabletopHalo` inconnu).

- [ ] **Step 2: Créer `TabletopHalo.swift`**

```swift
#if os(iOS)
import UIKit

/// Le halo du mode table : un MIROIR EN DIRECT de l'image, pas une capture.
/// La couche de la vue vidéo est un `CAReplicatorLayer` : en mode table il
/// dessine une seconde instance retournée sous le pli, recomposée par le
/// serveur d'affichage à chaque image, sans travail du fil principal. Sonde du
/// 2026-10-07 au simulateur du Duo : l'image libVLC est bien recopiée (une
/// capture `Player.takeSnapshot` échouait, elle, sur l'image décodée en matériel).
enum TabletopHalo {
    static let opacity: Float = 0.38

    /// Hauteur de l'image du film ajustée (`aspect fit`) dans `viewSize`.
    static func pictureHeight(viewSize: CGSize, videoAspect: CGFloat?) -> CGFloat {
        let aspect = videoAspect ?? (16.0 / 9.0)
        return min(viewSize.height, (viewSize.width / aspect).rounded())
    }

    static func qualityLabel(width: Int) -> String {
        switch width {
        case 3200...: "4K"
        case 1800...: "1080p"
        case 1200...: "720p"
        default: "SD"
        }
    }

    /// Vignette du bloc titre (82 pt de large), rendue par UIKit au moment où
    /// la dalle apparaît (~4 ms mesurées) — jamais en continu.
    static func thumbnail(of view: UIView, videoAspect: CGFloat?) -> UIImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let picH = pictureHeight(viewSize: bounds.size, videoAspect: videoAspect)
        let rect = CGRect(x: 0, y: (bounds.height - picH) / 2, width: bounds.width, height: picH)
        let scale = 164 / rect.width   // 82 pt @2x
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 164, height: (picH * scale).rounded()), format: format).image { _ in
            _ = view.drawHierarchy(in: CGRect(x: 0, y: -rect.minY * scale,
                                              width: bounds.width * scale, height: bounds.height * scale),
                                   afterScreenUpdates: false)
        }
    }
}

/// La vue vidéo du lecteur. Une seule instance en regular : coût nul.
final class MirroringVideoView: UIView {
    override class var layerClass: AnyClass { CAReplicatorLayer.self }
    private var replicator: CAReplicatorLayer { layer as! CAReplicatorLayer }

    /// En mode table : seconde instance retournée, l'image reflétée commençant
    /// `gapBelowFold` pt sous le bas de la vue (= le pli).
    ///
    /// `instanceTransform` s'applique autour du point d'ancrage (le centre) :
    /// en coordonnées centrées, y′ = −y + k. Le bas de l'image (y = picH / 2)
    /// doit tomber à h / 2 + gap, donc k = (h + picH) / 2 + gap.
    func setMirror(enabled: Bool, pictureHeight: CGFloat, gapBelowFold: CGFloat) {
        replicator.masksToBounds = false
        guard enabled else {
            replicator.instanceCount = 1
            return
        }
        let k = (bounds.height + pictureHeight) / 2 + gapBelowFold
        replicator.instanceCount = 2
        replicator.instanceTransform = CATransform3DConcat(CATransform3DMakeScale(1, -1, 1),
                                                           CATransform3DMakeTranslation(0, k, 0))
        replicator.instanceAlphaOffset = TabletopHalo.opacity - 1
    }
}

/// Par-dessus le reflet, dans la moitié basse : flou natif (en direct, sur le
/// GPU) puis dégradé vers le noir — le reflet s'éteint vers le bas comme sur
/// la maquette. Non interactif : les touchers passent au fond (`tabletopBackdrop`).
final class TabletopHaloVeil: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        blur.alpha = 0.7
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)
        fade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.45).cgColor, UIColor.black.cgColor]
        fade.locations = [0, 0.35, 0.8]
        layer.addSublayer(fade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        fade.frame = bounds
    }
}
#endif
```

`xcodegen generate`, relancer la suite : `Suite "TabletopHalo"` passe.

- [ ] **Step 3: Brancher dans le présentateur**

1. `private let videoView = UIView()` → sous iOS `private let videoView = MirroringVideoView()` (tvOS garde `UIView()` : `#if os(iOS) … #else … #endif`). Le `videoView.backgroundColor = .black` de `setupVideoView` est conservé : les bandes noires de la moitié haute sont reflétées en noir, invisibles.
2. Propriété `private let haloVeil = TabletopHaloVeil()` ; dans `viewDidLoad`, après l'insertion de `tabletopBackdrop` (Task 3) :

```swift
        haloVeil.translatesAutoresizingMaskIntoConstraints = false
        haloVeil.isHidden = true
        view.insertSubview(haloVeil, aboveSubview: videoView)   // sous controlsContainer
        NSLayoutConstraint.activate([
            haloVeil.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            haloVeil.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            haloVeil.topAnchor.constraint(equalTo: view.centerYAnchor),
            haloVeil.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
```

3. Aspect de la vidéo (déjà utile à la définition) :

```swift
    private var videoAspect: CGFloat? {
        guard let v = player.videoTracks.first(where: { $0.isSelected }) ?? player.videoTracks.first,
              let w = v.width, let h = v.height, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    /// À chaque passe de mise en page et à chaque bascule : la hauteur de la
    /// moitié haute et l'aspect de la piste fixent la position du reflet.
    private func updateMirror() {
        let tabletop = layoutMode == .tabletop
        haloVeil.isHidden = !tabletop
        videoView.setMirror(enabled: tabletop,
                            pictureHeight: TabletopHalo.pictureHeight(viewSize: videoView.bounds.size, videoAspect: videoAspect),
                            gapBelowFold: 24)
    }
```

4. Appeler `updateMirror()` à la fin de `applyLayoutMode` (après l'animation), dans `viewDidLayoutSubviews` après `applyLayoutMode()`, et quand les pistes changent (là où `applyServerTrackDefaultsIfNeeded` est appelé sur `.tracksChanged`).
5. Vignette : dans `showControls()`, avant l'animation :

```swift
        #if os(iOS)
        if layoutMode == .tabletop {
            tabletopThumbnail = TabletopHalo.thumbnail(of: videoView, videoAspect: videoAspect)
            refreshTabletopValues()
        }
        #endif
```

et une fois à l'entrée en mode table (fin de la branche `tabletop` d'`applyLayoutMode`, via `DispatchQueue.main.async`, l'image n'étant à jour qu'après la passe de mise en page).

- [ ] **Step 4: Compiler et vérifier au Duo**

Commandes de Task 3 Step 5. Avec l'utilisateur, Duo plié, Sintel :
- le reflet suit l'image en direct, retourné, commençant ~24 pt sous le pli, flou, éteint vers le bas ; si le sens ou la position est faux, corriger `k` (le probe n'a validé que la translation) et noter la formule exacte dans le commentaire ;
- dalle masquée : fond noir pur + même reflet ; dalle affichée : reflet visible à travers les blocs ;
- déplier : plus de reflet (une seule instance), lecteur identique à `main` ;
- 2 minutes de lecture sans à-coup visible (le miroir et le flou sont du travail GPU ; si le Duo simulé saccade, réduire le flou à `alpha` 0,5 et le noter).

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Shared/Screens/VideoPlayer/TabletopHalo.swift Shared/Screens/VideoPlayer/VLCStreamPresenter.swift Tests/CinemaxKitTests/PlayerPostureLayoutTests.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(lecteur): halo en direct sous le pli (miroir CAReplicatorLayer) et vignette du bloc titre"
```

---

### Task 6: Statistiques en deux colonnes sur l'écran du haut

**Files:**
- Modify: `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift` — `refreshStats()` (~3308), `applyLayoutMode`

**Interfaces:**
- Consumes: `statsLabel2` (Task 2), `layoutMode` (Task 3).

- [ ] **Step 1: Répartir les lignes**

À la fin de `refreshStats()`, remplacer `statsLabel.text = lines.joined(separator: "\n")` par :

```swift
        #if os(iOS)
        if layoutMode == .tabletop {
            // Deux colonnes : l'encart tient dans la bande noire au-dessus de
            // l'image au lieu de la couvrir.
            let half = (lines.count + 1) / 2
            statsLabel.text = lines.prefix(half).joined(separator: "\n")
            statsLabel2.text = lines.dropFirst(half).joined(separator: "\n")
            statsLabel2.isHidden = false
            return
        }
        statsLabel2.isHidden = true
        #endif
        statsLabel.text = lines.joined(separator: "\n")
```

Dans `applyLayoutMode`, après `applyHUDStyle()` : `if statsVisible { refreshStats() }`.

- [ ] **Step 2: Compiler, vérifier au Duo, commit**

Commandes de Task 3 Step 5. Au Duo plié : menu du bloc titre → Statistiques ⇒ encart en deux colonnes en haut à gauche, qui reste quand la dalle se masque ; déplier ⇒ une colonne, comme aujourd'hui.

```bash
git add Shared/Screens/VideoPlayer/VLCStreamPresenter.swift
git commit -m "feat(lecteur): statistiques en deux colonnes en mode table"
```

---

### Task 7: Règles, documentation, vérification finale

**Files:**
- Modify: `Shared/Screens/VideoPlayer/CLAUDE.md`, `Shared/Screens/Settings/CLAUDE.md`

- [ ] **Step 1: RULE dans `Shared/Screens/VideoPlayer/CLAUDE.md`** (section Video Playback)

```markdown
- **RULE — iPhone Duo à moitié replié en portrait = mode « table » du lecteur iOS** (`PlayerPostureLayout`, 2026-10-07) : vidéo dans la moitié haute (guide `videoArea`), dalle de blocs dans la moitié basse, halo en direct sous le pli (`TabletopHalo.swift`). Mêmes boutons, mêmes actions, mêmes libellés VoiceOver que le HUD de toujours : la dalle n'est qu'un autre jeu de contraintes (`makeTabletopHUDConstraints`) et d'habillages (`TabletopHUDStyle`) — **un nouveau contrôle du HUD doit trouver sa place dans les DEUX jeux**, sinon il disparaît (ou flotte) en mode table. Tout autre état (ouvert, fermé, paysage, iPhone, iPad, `hinge == nil`) = lecteur actuel. `UIHingeInteraction` est un symbole du SDK 27.1 : code sous `#if !NO_HINGE_API` (défini pour le SDK 27.0 dans `project.yml`, celui de la CI) **et** `#available(iOS 27.1, *)`. Halo = miroir EN DIRECT : la couche de `videoView` est un `CAReplicatorLayer` (`MirroringVideoView`, une instance en regular, deux en mode table) voilé par `TabletopHaloVeil` ; jamais `Player.takeSnapshot` (échec « Failed to convert image for snapshot » sur l'image décodée en matériel, 40–380 ms de blocage mesurés) ni capture périodique. Cadenas fermé (`player.tabletopHUDLocked`) : la dalle ne se masque ni au délai ni au toucher.
```

- [ ] **Step 2: Ligne de la clé dans le tableau de `Shared/Screens/Settings/CLAUDE.md`**

```markdown
| `player.tabletopHUDLocked` | `false` | Cadenas de la dalle du lecteur en posture table (iPhone Duo) : `true` = la dalle ne se masque plus d'elle-même. Écrit par le bouton cadenas, pas d'entrée dans Réglages. |
```

- [ ] **Step 3: Vérification complète**

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DD-x270 -skipPackagePluginValidation 2>&1 | grep -E "error:|\*\* BUILD"
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'generic/platform=tvOS Simulator' -derivedDataPath build/DD-iae-tv -skipPackagePluginValidation 2>&1 | grep -E "error:|\*\* BUILD"
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'id=2E531329-FC54-453A-85D4-6E6C27F97314' -derivedDataPath build/DD-tests -skipPackagePluginValidation 2>&1 | tee $SCRATCH/test.log | grep -E "\*\* TEST|✘"
grep -E 'Suite "PlayerPostureLayout" passed|✔ Test run with' $SCRATCH/test.log
python3 scripts/check-localization-parity.py
swiftlint lint --strict --baseline .swiftlint-baseline.json Shared/Screens/VideoPlayer/ Shared/DesignSystem/SettingsKeys.swift
```
Expected: builds OK (iOS avec Xcode 27.0, tvOS), tests OK avec la suite `PlayerPostureLayout`, parité OK, SwiftLint sans nouvelle violation.

Recette finale avec l'utilisateur :
- Duo : ouvert → plié → fermé → plié, en lecture, puis pendant un glissement du curseur, puis avec une feuille d'actions ouverte (Review Focus) ;
- non-régression : iPhone 17 Pro portrait/paysage, iPad Pro 13″, Duo ouvert et fermé : lecteur identique à `main` ;
- coût du halo : vérifier au simulateur du Duo qu'aucun à-coup n'apparaît pendant 2 minutes de lecture (le mode table n'existe que sur le Duo).

- [ ] **Step 4: Commit et PR**

```bash
git add Shared/Screens/VideoPlayer/CLAUDE.md Shared/Screens/Settings/CLAUDE.md
git commit -m "docs: règle du mode table du lecteur et clé du cadenas"
git push -u origin claude/duo-tabletop-player
gh pr create --base main --title "Lecteur : posture « table » sur l'iPhone Duo" --body "…"
```

La fusion reste manuelle (utilisateur).
