# Thèmes saisonniers : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** du 15 octobre au 2 novembre, l'app (iOS + tvOS) passe d'elle-même en « Nuit d'Halloween » : palette, accent, titres Fraunces, ambiance, rangée « Frissons d'Halloween ». Le socle est générique : Noël sera une entrée de catalogue.

**Architecture:** une saison est une valeur pure (`SeasonalTheme`) dans un catalogue. Une politique pure décide laquelle est active. Un contrôleur `@MainActor @Observable` la tient à jour. La palette passe par un trait UIKit personnalisé (`SeasonTrait`), ponté vers l'environnement SwiftUI (`\.seasonID`), que lit le fournisseur de `Color.dynamic` : les ~800 appels `CinemaColor` ne changent pas. Les vues lisent `\.seasonID` (valeur d'environnement, jamais d'objet requis), l'accent passe par `ThemeManager.setSeasonAccent`. L'icône est un processus de version (script), pas du code app.

**Tech Stack:** Swift 6 (mode strict), SwiftUI + UIKit (iOS 26 / tvOS 26), `UITraitDefinition` + `UITraitBridgedEnvironmentKey`, Core Animation, swift-testing, XcodeGen, Python 3 (Pillow + numpy) pour les images.

**Spec:** `docs/superpowers/specs/2026-09-28-seasonal-themes-design.md` (à lire avant chaque tâche).

## Global Constraints

- Swift 6 strict concurrency ; `import JellyfinAPI` sans `@preconcurrency`.
- Une propriété d'une classe `@Observable` n'a JAMAIS de `didSet`/`willSet` : mutateurs explicites + `Binding(get:set:)` (RULE racine).
- Toute chaîne visible passe par `loc.localized(…)`, clé présente dans `Resources/fr.lproj/Localizable.strings` ET `Resources/en.lproj/Localizable.strings`, mêmes spécificateurs de format.
- Dates formatées avec `loc.locale` (RULE Localisation) ; jamais `.formatted()` nu.
- Tout nouveau fichier sous `Shared/` ou `Tests/` ⇒ `xcodegen generate` avant de compiler.
- Un test n'écrit jamais `UserDefaults.standard` pour une clé lue par le code testé : `UserDefaults.isolatedForTesting()` ; jamais de `sleep` pour attendre.
- Jamais `-only-testing` (il exécute 0 test swift-testing) : suite complète, puis lecture de `✔ Test run with N tests` et des lignes `Suite "…"`.
- Toujours `set -o pipefail` devant un `xcodebuild … | grep` ; builds iOS et tvOS en SÉRIE, jamais en parallèle.
- Un test qui touche un type iOS-only est dans `#if os(iOS)` ; tvOS-only dans `#if os(tvOS)`.
- Pas de `Color(hex:)` pour un nouveau token ; les couleurs d'interface restent des `Color.dynamic`.
- Fenêtre Halloween : **15 octobre → 2 novembre, bornes incluses, heure locale**. Icône : variante `halloween_cloche-citrouille_tentacules-potion`.
- Rien n'est poussé et aucune PR n'est ouverte sans l'accord explicite de l'utilisateur.
- Commits : message en français, terminé par `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Minuit du 2 au 3 novembre, app ouverte** → la palette et l'accent reviennent sans relancer l'app (`.NSCalendarDayChanged`). Test : Task 3, `dayChangeEndsTheSeasonWithoutRelaunch`.
2. **Réglage « Désactivé » touché depuis Apparence** → l'app redevient normale immédiatement, sans perdre la navigation (on reste dans Réglages). Test : Task 2, `changingTheTraitRedrawsLive` ; recette Task 11.
3. **Mode clair pendant Halloween** → surfaces claires intactes, accent citrouille lisible (`#A84508`, ≥ 4,5:1). Tests : Task 2, `lightSurfaceIgnoresASeasonWithoutLightPalette` ; Task 1, contraste.
4. **Serveur sans genre Horreur, ou genre présent mais vide** → aucune rangée, aucun en-tête orphelin. Tests : Task 6, `noMatchingGenreHidesTheRow`, `emptyGenreHidesTheRow`.
5. **« Réduire les animations » activé en pleine saison** → brume, chauves-souris et lueur disparaissent (absentes, pas figées). Tests : Task 1, `reduceMotionRemovesEveryEffect` ; Task 7, `mist` (retrait des calques). Et l'accent arc-en-ciel déverrouillé pendant la saison → l'accent de saison gagne (Task 3, `seasonAccentBeatsRainbow`).

## File Structure

| Fichier | Rôle |
|---|---|
| `Shared/DesignSystem/Seasons/SeasonalTheme.swift` (créé) | Les types valeur : `MonthDay`, `SeasonWindow`, `SeasonToken`, `SeasonPalette`, `SeasonFont`, `AmbianceEffect`, `SeasonRow`, `SeasonalTheme`, `SeasonalSetting`. |
| `Shared/DesignSystem/Seasons/SeasonalThemeCatalogue.swift` (créé) | Les saisons (DONNÉES). Halloween. |
| `Shared/DesignSystem/Seasons/SeasonalThemePolicy.swift` (créé) | Quelle saison est active ; `AmbiancePolicy` ; `SeasonRowMatcher`. Tout pur. |
| `Shared/DesignSystem/Seasons/SeasonTrait.swift` (créé) | `SeasonTrait`, le pont `\.seasonID`, `SeasonalColor.resolve`, `SeasonTraitApplier`. |
| `Shared/DesignSystem/Seasons/SeasonalThemeController.swift` (créé) | L'état `@Observable` : saison active, réglages, réévaluation. |
| `Shared/DesignSystem/Seasons/SeasonalTypography.swift` (créé) | `SeasonalTypography.titleFont`, `HeroTitleStyle`. |
| `Shared/DesignSystem/Seasons/SeasonalAmbiance.swift` (créé) | `SeasonalAmbianceOverlay`, `AmbianceView` (brume, chauves-souris), `SeasonalFocusGlow` (tvOS). |
| `Shared/DesignSystem/CinemaGlassTheme.swift` (modifié) | `Color.dynamic(light:dark:season:)` ; les tokens de surface et de texte passent leur `SeasonToken`. |
| `Shared/DesignSystem/ThemeManager.swift` (modifié) | `setSeasonAccent(_:)`, `isSeasonAccentActive`. |
| `Shared/DesignSystem/AccentOption.swift` (modifié) | `Palette: Sendable, Equatable`. |
| `Shared/DesignSystem/SettingsKeys.swift` (modifié) | 4 clés + défauts. |
| `Shared/DesignSystem/FocusScaleModifier.swift` (modifié) | Lueur de saison sur tvOS. |
| `Shared/DesignSystem/Components/ContentRow.swift` (modifié) | Paramètre `titleFont`. |
| `Shared/DesignSystem/Components/ToastWindow.swift` (modifié) | La fenêtre des toasts reçoit `\.seasonID`. |
| `Shared/Navigation/AppNavigation.swift` (modifié) | Singleton, environnement, déclencheurs, application du trait. |
| `Shared/ViewModels/HomeViewModel.swift` + `Shared/Screens/HomeScreen.swift` (modifiés) | Rangée de saison, titre et ambiance du héros. |
| `Shared/Screens/LibraryHeroSection.swift`, `Shared/Screens/MediaDetailScreen.swift` (modifiés) | Titre et ambiance des héros. |
| `Shared/Screens/Settings/SettingsAppearanceView+iOS.swift`, `SettingsScreen+tvOS.swift`, `SettingsScreen.swift` (modifiés) | Section « Thème saisonnier », note d'accent, bascule Debug. |
| `Shared/Screens/LicensesView.swift`, `scripts/dependency-audit.py` (modifiés) | Crédit de Fraunces. |
| `Resources/Fonts/Fraunces-BlackItalic.ttf` (créé), `project.yml` (modifié) | La police, `UIAppFonts`. |
| `Resources/{fr,en}.lproj/Localizable.strings` (modifiés) | Chaînes. |
| `design/logo-variantes/recolor.py` (modifié), `scripts/seasonal-icon.py` (créé) | Variante `classique`, bascule d'icône. |
| `Tests/CinemaxKitTests/Seasonal*Tests.swift` (créés) | Tests. |
| `Shared/DesignSystem/CLAUDE.md`, `Shared/Screens/Settings/CLAUDE.md`, `CLAUDE.md` (modifiés) | RULE, table des clés, arborescence. |

Commandes réutilisées (référencées par les tâches) :

```bash
# RÉGÉNÉRER LE PROJET (après tout nouveau fichier)
xcodegen generate

# TESTS iOS — suite complète, log conservé
set -o pipefail; LOG=$(mktemp); xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation 2>&1 | tee "$LOG" | grep -E '✘|Suite "Season|✔ Test run|\*\* TEST' ; echo "log: $LOG"

# TESTS tvOS — APRÈS les tests iOS, jamais en même temps
set -o pipefail; LOG=$(mktemp); xcodebuild test -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -skipPackagePluginValidation 2>&1 | tee "$LOG" | grep -E '✘|Suite "Season|✔ Test run|\*\* TEST' ; echo "log: $LOG"
```

---

### Task 0: Branche de travail

**Files:** aucun.

- [ ] **Step 1: Créer la branche.** Si la PR de `design/logo-variantes` n'est pas encore fusionnée, partir de cette branche (elle porte les icônes carrées, la spec et ce plan) ; sinon partir de `main` à jour.

```bash
git switch design/logo-variantes && git switch -c claude/seasonal-themes
git rev-parse --abbrev-ref HEAD   # attendu : claude/seasonal-themes
```

---

### Task 1: Modèle, catalogue, politiques pures

**Files:**
- Create: `Shared/DesignSystem/Seasons/SeasonalTheme.swift`
- Create: `Shared/DesignSystem/Seasons/SeasonalThemeCatalogue.swift`
- Create: `Shared/DesignSystem/Seasons/SeasonalThemePolicy.swift`
- Modify: `Shared/DesignSystem/AccentOption.swift` (fin du fichier)
- Modify: `Resources/fr.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`
- Test: `Tests/CinemaxKitTests/SeasonalThemePolicyTests.swift`

**Interfaces:**
- Produces: `SeasonalTheme`, `SeasonWindow.contains(_:calendar:)`, `SeasonToken`, `SeasonPalette[_: SeasonToken] -> UInt`, `SeasonalSetting` (`.automatic`, `.off`), `SeasonalThemeCatalogue.all / .halloween / theme(id: String?) -> SeasonalTheme?`, `SeasonalThemePolicy.activeTheme(on:calendar:setting:forcedID:catalogue:) -> SeasonalTheme?`, `AmbiancePolicy.effects(theme:ambianceEnabled:motionEnabled:) -> Set<AmbianceEffect>`, `SeasonRowMatcher.match(candidates:in:) -> String?`.

- [ ] **Step 1: Écrire les tests (ils échouent : types absents).** Créer `Tests/CinemaxKitTests/SeasonalThemePolicyTests.swift` :

```swift
import Foundation
import Testing
@testable import Cinemax

@Suite("Seasonal theme policy")
struct SeasonalThemePolicyTests {
    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private let halloween = SeasonalThemeCatalogue.halloween

    /// A season that wraps the New Year, the Christmas case.
    private let winter = SeasonalTheme(
        id: "test.winter", nameKey: "season.halloween.name",
        window: SeasonWindow(start: MonthDay(month: 12, day: 20), end: MonthDay(month: 1, day: 6)),
        dark: SeasonalThemeCatalogue.halloween.dark, light: nil,
        accent: SeasonalThemeCatalogue.halloween.accent, titleFont: nil, ambiance: [], row: nil
    )

    @Test("Halloween starts on 15 October at midnight, local time")
    func startBoundary() {
        let paris = calendar("Europe/Paris")
        // 23:59:59 on the 14th in Paris is 21:59:59Z.
        #expect(halloween.window.contains(date("2026-10-14T21:59:59Z"), calendar: paris) == false)
        #expect(halloween.window.contains(date("2026-10-14T22:00:00Z"), calendar: paris) == true)
    }

    @Test("Halloween ends after 2 November, local time")
    func endBoundary() {
        let paris = calendar("Europe/Paris")
        // Paris is UTC+1 after the October DST change.
        #expect(halloween.window.contains(date("2026-11-02T22:59:59Z"), calendar: paris) == true)
        #expect(halloween.window.contains(date("2026-11-02T23:00:00Z"), calendar: paris) == false)
    }

    @Test("The same instant can be in season in Tokyo and not in Paris")
    func timeZoneDecides() {
        let instant = date("2026-10-14T20:00:00Z")
        #expect(halloween.window.contains(instant, calendar: calendar("Europe/Paris")) == false)
        #expect(halloween.window.contains(instant, calendar: calendar("Asia/Tokyo")) == true)
    }

    @Test("A window can wrap the New Year")
    func wrapsNewYear() {
        let utc = calendar("UTC")
        #expect(winter.window.contains(date("2026-12-19T12:00:00Z"), calendar: utc) == false)
        #expect(winter.window.contains(date("2026-12-20T00:00:00Z"), calendar: utc) == true)
        #expect(winter.window.contains(date("2026-12-31T12:00:00Z"), calendar: utc) == true)
        #expect(winter.window.contains(date("2027-01-06T23:59:59Z"), calendar: utc) == true)
        #expect(winter.window.contains(date("2027-01-07T00:00:00Z"), calendar: utc) == false)
    }

    @Test("Automatic picks the season whose window contains the date")
    func automatic() {
        let theme = SeasonalThemePolicy.activeTheme(
            on: date("2026-10-20T12:00:00Z"), calendar: calendar("UTC"),
            setting: .automatic, forcedID: "", catalogue: [halloween]
        )
        #expect(theme?.id == "halloween")
    }

    @Test("Off means no season, even inside the window")
    func off() {
        let theme = SeasonalThemePolicy.activeTheme(
            on: date("2026-10-20T12:00:00Z"), calendar: calendar("UTC"),
            setting: .off, forcedID: "", catalogue: [halloween]
        )
        #expect(theme == nil)
    }

    @Test("A forced season wins over the date and the setting")
    func forced() {
        let theme = SeasonalThemePolicy.activeTheme(
            on: date("2026-06-01T12:00:00Z"), calendar: calendar("UTC"),
            setting: .off, forcedID: "halloween", catalogue: [halloween]
        )
        #expect(theme?.id == "halloween")
    }

    @Test("An unknown forced id is ignored")
    func unknownForced() {
        let theme = SeasonalThemePolicy.activeTheme(
            on: date("2026-06-01T12:00:00Z"), calendar: calendar("UTC"),
            setting: .automatic, forcedID: "noel-2099", catalogue: [halloween]
        )
        #expect(theme == nil)
    }

    @Test("Catalogue lookup by id")
    func lookup() {
        #expect(SeasonalThemeCatalogue.theme(id: "halloween")?.id == "halloween")
        #expect(SeasonalThemeCatalogue.theme(id: nil) == nil)
        #expect(SeasonalThemeCatalogue.theme(id: "nope") == nil)
    }

    @Test("No two catalogue windows share a day")
    func noOverlap() {
        let utc = calendar("UTC")
        let all = SeasonalThemeCatalogue.all
        var day = date("2028-01-01T12:00:00Z")   // leap year: 29 February included
        for _ in 0..<366 {
            let hits = all.filter { $0.window.contains(day, calendar: utc) }
            #expect(hits.count <= 1, "overlap on \(day)")
            day = utc.date(byAdding: .day, value: 1, to: day)!
        }
    }

    @Test("Every season's keys exist in French and English")
    func keysExist() throws {
        for lang in ["fr", "en"] {
            let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang))
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            for theme in SeasonalThemeCatalogue.all {
                #expect(table[theme.nameKey] != nil, "\(lang): \(theme.nameKey)")
                if let row = theme.row { #expect(table[row.titleKey] != nil, "\(lang): \(row.titleKey)") }
            }
        }
    }

    // MARK: Contrast

    private func luminance(_ hex: UInt) -> Double {
        func channel(_ v: UInt) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 255) + 0.7152 * channel((hex >> 8) & 255) + 0.0722 * channel(hex & 255)
    }

    private func contrast(_ a: UInt, _ b: UInt) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("Season text and accent clear 4.5:1 on every season surface")
    func contrastDark() {
        for theme in SeasonalThemeCatalogue.all {
            let p = theme.dark
            for surface in [p.surface, p.surfaceContainerLow, p.surfaceContainer, p.surfaceContainerHigh] {
                for text in [p.onSurface, p.onSurfaceVariant, p.onSurfaceMuted, theme.accent.accentDark] {
                    #expect(contrast(text, surface) >= 4.5, "\(theme.id): \(String(text, radix: 16)) on \(String(surface, radix: 16))")
                }
            }
            #expect(contrast(theme.accent.onAccentDark, theme.accent.accentDark) >= 4.5)
        }
    }

    @Test("A season without a light palette keeps a readable light-mode accent")
    func contrastLightAccent() {
        for theme in SeasonalThemeCatalogue.all where theme.light == nil {
            // CinemaColor.surface / surfaceContainer, light mode.
            #expect(contrast(theme.accent.accentLight, 0xF7F7F8) >= 4.5)
            #expect(contrast(theme.accent.accentLight, 0xEAEAEC) >= 4.4)
        }
    }

    // MARK: Ambiance + row matching

    @Test("Ambiance: season effects only when enabled and motion allowed")
    func ambiance() {
        #expect(AmbiancePolicy.effects(theme: halloween, ambianceEnabled: true, motionEnabled: true) == [.mist, .bats, .focusGlow])
        #expect(AmbiancePolicy.effects(theme: halloween, ambianceEnabled: false, motionEnabled: true).isEmpty)
        #expect(AmbiancePolicy.effects(theme: nil, ambianceEnabled: true, motionEnabled: true).isEmpty)
    }

    @Test("Reduce Motion removes every effect")
    func reduceMotionRemovesEveryEffect() {
        #expect(AmbiancePolicy.effects(theme: halloween, ambianceEnabled: true, motionEnabled: false).isEmpty)
    }

    @Test("Genre matching ignores case and accents, first candidate wins")
    func matcher() {
        #expect(SeasonRowMatcher.match(candidates: ["Horror", "Horreur"], in: ["Action", "horreur"]) == "horreur")
        #expect(SeasonRowMatcher.match(candidates: ["Épouvante-horreur"], in: ["EPOUVANTE-HORREUR"]) == "EPOUVANTE-HORREUR")
        #expect(SeasonRowMatcher.match(candidates: ["Horror", "Horreur"], in: ["Horreur", "Horror"]) == "Horror")
        #expect(SeasonRowMatcher.match(candidates: ["Horror"], in: ["Comédie"]) == nil)
        #expect(SeasonRowMatcher.match(candidates: ["Horror"], in: []) == nil)
    }
}
```

- [ ] **Step 2: Vérifier l'échec.** `xcodegen generate` puis la commande TESTS iOS. Attendu : `** TEST FAILED **`, erreurs « cannot find 'SeasonalThemeCatalogue' in scope ».

- [ ] **Step 3: `AccentOption.Palette` devient `Sendable, Equatable`.** À la fin de `Shared/DesignSystem/AccentOption.swift` :

```swift
// Seasonal themes carry an accent palette (`SeasonalTheme.accent`), and a
// theme is a `Sendable` value read from a UIColor provider.
extension AccentOption.Palette: Sendable, Equatable {}
```

- [ ] **Step 4: Les types.** Créer `Shared/DesignSystem/Seasons/SeasonalTheme.swift` :

```swift
import Foundation

// MARK: - Seasonal themes
//
// A season is DATA: its dates, its palette, its accent, its title font, its
// ambiance and its Home row. `SeasonalThemeCatalogue` lists them; adding
// Christmas is one more entry, no new logic. See
// docs/superpowers/specs/2026-09-28-seasonal-themes-design.md.

struct MonthDay: Sendable, Equatable, Comparable {
    let month: Int   // 1…12
    let day: Int     // 1…31

    static func < (a: MonthDay, b: MonthDay) -> Bool {
        (a.month, a.day) < (b.month, b.day)
    }
}

/// Both ends INCLUDED, read in the calendar's time zone (the device's, in the
/// app). `start > end` means the window wraps the New Year.
struct SeasonWindow: Sendable, Equatable {
    let start: MonthDay
    let end: MonthDay

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return false }
        let today = MonthDay(month: month, day: day)
        if start <= end { return start <= today && today <= end }
        return today >= start || today <= end
    }
}

/// The `CinemaColor` tokens a season may repaint. Every other token (error,
/// success, primary…) keeps its value.
enum SeasonToken: Sendable, CaseIterable {
    case surface, surfaceContainerLowest, surfaceContainerLow, surfaceContainer
    case surfaceContainerHigh, surfaceContainerHighest, surfaceVariant
    case onSurface, onSurfaceVariant, onSurfaceMuted
    case outline, outlineVariant
}

struct SeasonPalette: Sendable, Equatable {
    let surface: UInt
    let surfaceContainerLowest: UInt
    let surfaceContainerLow: UInt
    let surfaceContainer: UInt
    let surfaceContainerHigh: UInt
    let surfaceContainerHighest: UInt
    let surfaceVariant: UInt
    let onSurface: UInt
    let onSurfaceVariant: UInt
    let onSurfaceMuted: UInt
    let outline: UInt
    let outlineVariant: UInt

    subscript(_ token: SeasonToken) -> UInt {
        switch token {
        case .surface: surface
        case .surfaceContainerLowest: surfaceContainerLowest
        case .surfaceContainerLow: surfaceContainerLow
        case .surfaceContainer: surfaceContainer
        case .surfaceContainerHigh: surfaceContainerHigh
        case .surfaceContainerHighest: surfaceContainerHighest
        case .surfaceVariant: surfaceVariant
        case .onSurface: onSurface
        case .onSurfaceVariant: onSurfaceVariant
        case .onSurfaceMuted: onSurfaceMuted
        case .outline: outline
        case .outlineVariant: outlineVariant
        }
    }
}

struct SeasonFont: Sendable, Equatable {
    let postScriptName: String
    let fileName: String
}

enum AmbianceEffect: String, Sendable, CaseIterable {
    case mist, bats, focusGlow
}

struct SeasonRow: Sendable, Equatable {
    let titleKey: String
    /// Compared case- and accent-insensitively with the server's genre names,
    /// which follow the library's metadata language.
    let genreCandidates: [String]
}

struct SeasonalTheme: Sendable, Equatable, Identifiable {
    let id: String
    let nameKey: String
    let window: SeasonWindow
    let dark: SeasonPalette
    /// `nil`: in light mode the season leaves the surfaces alone; only the
    /// accent, the titles, the ambiance and the row change.
    let light: SeasonPalette?
    let accent: AccentOption.Palette
    let titleFont: SeasonFont?
    let ambiance: Set<AmbianceEffect>
    let row: SeasonRow?
}

/// Settings → Appearance. No « always »: with several seasons it has no
/// meaning; the Debug page can force one for testing.
enum SeasonalSetting: String, Sendable {
    case automatic, off
}
```

- [ ] **Step 5: Le catalogue.** Créer `Shared/DesignSystem/Seasons/SeasonalThemeCatalogue.swift` :

```swift
import Foundation

/// Every season the app knows. DATA, not code — like `WhatsNewCatalogue`.
enum SeasonalThemeCatalogue {
    /// « Nuit d'Halloween » — the design canvas « Cinemax — Logo & Halloween ».
    /// Derived tokens (not on the canvas) are marked; their contrast is locked
    /// by `SeasonalThemePolicyTests`.
    static let halloween = SeasonalTheme(
        id: "halloween",
        nameKey: "season.halloween.name",
        window: SeasonWindow(start: MonthDay(month: 10, day: 15), end: MonthDay(month: 11, day: 2)),
        dark: SeasonPalette(
            surface: 0x0C0A10,                 // Nuit
            surfaceContainerLowest: 0x07060A,  // derived
            surfaceContainerLow: 0x15111C,     // Crypte
            surfaceContainer: 0x1D1726,        // Caveau
            surfaceContainerHigh: 0x262033,    // Tombe
            surfaceContainerHighest: 0x2E2740, // derived
            surfaceVariant: 0x2E2740,          // derived
            onSurface: 0xF1E9E0,               // Parchemin
            onSurfaceVariant: 0xB3A8B8,        // Cendre
            onSurfaceMuted: 0x9A90A2,          // derived
            outline: 0x7A6F84,                 // derived (strokes only)
            outlineVariant: 0x4A4058           // derived (strokes only)
        ),
        light: nil,
        accent: AccentOption.Palette(
            accentLight: 0xA84508, accentDark: 0xFF7A1A,     // Citrouille
            containerLight: 0xE06A1A, containerDark: 0xE06A1A,
            dimLight: 0x8A3806, dimDark: 0xCC5500,
            onAccentLight: 0xFFFFFF, onAccentDark: 0x1A0D05
        ),
        // PostScript name checked against the bundled file in Task 6.
        titleFont: SeasonFont(postScriptName: "Fraunces-BlackItalic", fileName: "Fraunces-BlackItalic.ttf"),
        ambiance: [.mist, .bats, .focusGlow],
        row: SeasonRow(
            titleKey: "season.halloween.row",
            genreCandidates: ["Horror", "Horreur", "Épouvante-horreur", "Épouvante"]
        )
    )

    static let all: [SeasonalTheme] = [halloween]

    private static let byID: [String: SeasonalTheme] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func theme(id: String?) -> SeasonalTheme? {
        id.flatMap { byID[$0] }
    }
}
```

- [ ] **Step 6: Les politiques.** Créer `Shared/DesignSystem/Seasons/SeasonalThemePolicy.swift` :

```swift
import Foundation

enum SeasonalThemePolicy {
    /// A non-empty `forcedID` naming a catalogue season wins (Debug page);
    /// otherwise `.off` means none, and `.automatic` the season whose window
    /// contains `date`.
    static func activeTheme(
        on date: Date, calendar: Calendar, setting: SeasonalSetting,
        forcedID: String, catalogue: [SeasonalTheme]
    ) -> SeasonalTheme? {
        if !forcedID.isEmpty, let forced = catalogue.first(where: { $0.id == forcedID }) {
            return forced
        }
        guard setting == .automatic else { return nil }
        return catalogue.first { $0.window.contains(date, calendar: calendar) }
    }
}

enum AmbiancePolicy {
    /// Nothing moves when the user turned ambiance off, or when the app's
    /// motion effects / the system's Reduce Motion say no (`motionEnabled` is
    /// the combined `\.motionEffectsEnabled`). Off means ABSENT, not frozen.
    static func effects(theme: SeasonalTheme?, ambianceEnabled: Bool, motionEnabled: Bool) -> Set<AmbianceEffect> {
        guard let theme, ambianceEnabled, motionEnabled else { return [] }
        return theme.ambiance
    }
}

enum SeasonRowMatcher {
    /// The server's spelling of the first candidate it carries, or `nil`.
    static func match(candidates: [String], in serverGenres: [String]) -> String? {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        for candidate in candidates {
            let key = fold(candidate)
            if let hit = serverGenres.first(where: { fold($0) == key }) { return hit }
        }
        return nil
    }
}
```

- [ ] **Step 7: Les chaînes des saisons.** Ajouter à la fin de `Resources/fr.lproj/Localizable.strings` :

```
"season.halloween.name" = "Nuit d'Halloween";
"season.halloween.row" = "Frissons d'Halloween";
```

et à la fin de `Resources/en.lproj/Localizable.strings` :

```
"season.halloween.name" = "Halloween Night";
"season.halloween.row" = "Halloween Chills";
```

- [ ] **Step 8: Vérifier le succès.** `xcodegen generate`, puis TESTS iOS. Attendu : `✔ Suite "Seasonal theme policy" passed`, aucune ligne `✘`, `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit.**

```bash
git add Shared/DesignSystem/Seasons Shared/DesignSystem/AccentOption.swift Resources/*/Localizable.strings Tests/CinemaxKitTests/SeasonalThemePolicyTests.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(saisons): modèle, catalogue Halloween et politiques pures

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(Le hook pre-commit remet le pbxproj en sortie xcodegen vierge dans l'index : c'est voulu.)

---

### Task 2: La palette de saison dans toute l'app (trait + `Color.dynamic`)

C'est la tâche qui décide du mécanisme (spec §5). Les tests de rendu sont permanents, pas jetables.

**Files:**
- Create: `Shared/DesignSystem/Seasons/SeasonTrait.swift`
- Modify: `Shared/DesignSystem/CinemaGlassTheme.swift:5-17` (`Color.dynamic`) et `:37-66` (tokens)
- Test: `Tests/CinemaxKitTests/SeasonalPaletteTests.swift`

**Interfaces:**
- Consumes: `SeasonalThemeCatalogue.theme(id:)`, `SeasonToken`, `SeasonPalette[_:]` (Task 1).
- Produces: `SeasonTrait` (`UITraitDefinition`, valeur `String?`), `EnvironmentValues.seasonID: String?` (ponté), `SeasonalColor.resolve(light:dark:token:isDark:season:) -> UInt`, `Color.dynamic(light:dark:season:)`, `SeasonTraitApplier(seasonID:)` (représentable qui pose le trait sur la scène).

- [ ] **Step 1: Écrire les tests.** Créer `Tests/CinemaxKitTests/SeasonalPaletteTests.swift` :

```swift
import SwiftUI
import Testing
import UIKit
@testable import Cinemax

@Suite("Seasonal palette")
@MainActor
struct SeasonalPaletteTests {
    private let halloween = SeasonalThemeCatalogue.halloween

    // MARK: Pure resolution

    @Test("No season: the token's own light / dark values")
    func noSeason() {
        #expect(SeasonalColor.resolve(light: 0xF7F7F8, dark: 0x0E0E0E, token: .surface, isDark: true, season: nil) == 0x0E0E0E)
        #expect(SeasonalColor.resolve(light: 0xF7F7F8, dark: 0x0E0E0E, token: .surface, isDark: false, season: nil) == 0xF7F7F8)
    }

    @Test("Dark mode in season: the season's value")
    func darkInSeason() {
        #expect(SeasonalColor.resolve(light: 0xF7F7F8, dark: 0x0E0E0E, token: .surface, isDark: true, season: halloween) == 0x0C0A10)
    }

    @Test("Light mode, season without light palette: untouched")
    func lightWithoutLightPalette() {
        #expect(SeasonalColor.resolve(light: 0xF7F7F8, dark: 0x0E0E0E, token: .surface, isDark: false, season: halloween) == 0xF7F7F8)
    }

    @Test("A token the season does not cover is never repainted")
    func uncoveredToken() {
        #expect(SeasonalColor.resolve(light: 0xC0392B, dark: 0xEE7D77, token: nil, isDark: true, season: halloween) == 0xEE7D77)
    }

    // MARK: Rendered through SwiftUI

    private func hex(of image: UIImage) -> UInt {
        let cg = image.cgImage!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -cg.width / 2, y: -cg.height / 2, width: cg.width, height: cg.height))
        return UInt(px[0]) << 16 | UInt(px[1]) << 8 | UInt(px[2])
    }

    private func close(_ a: UInt, _ b: UInt) -> Bool {
        [16, 8, 0].allSatisfy { abs(Int((a >> UInt($0)) & 255) - Int((b >> UInt($0)) & 255)) <= 2 }
    }

    /// A window of the test host's scene, painting `CinemaColor.surface` full size.
    private func makeWindow(style: UIUserInterfaceStyle) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: CinemaColor.surface.ignoresSafeArea())
        window.isHidden = false
        return window
    }

    private func render(_ window: UIWindow) -> UInt {
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return hex(of: image)
    }

    @Test("Dark surface without a season")
    func renderedNoSeason() throws {
        let window = try makeWindow(style: .dark)
        defer { window.isHidden = true }
        #expect(close(render(window), 0x0E0E0E))
    }

    @Test("Dark surface under the Halloween trait")
    func renderedHalloween() throws {
        let window = try makeWindow(style: .dark)
        defer { window.isHidden = true }
        window.traitOverrides[SeasonTrait.self] = "halloween"
        #expect(close(render(window), 0x0C0A10))
    }

    @Test("Light surface ignores a season without light palette")
    func lightSurfaceIgnoresASeasonWithoutLightPalette() throws {
        let window = try makeWindow(style: .light)
        defer { window.isHidden = true }
        window.traitOverrides[SeasonTrait.self] = "halloween"
        #expect(close(render(window), 0xF7F7F8))
    }

    @Test("Changing the trait redraws live, same window")
    func changingTheTraitRedrawsLive() throws {
        let window = try makeWindow(style: .dark)
        defer { window.isHidden = true }
        #expect(close(render(window), 0x0E0E0E))
        window.traitOverrides[SeasonTrait.self] = "halloween"
        #expect(close(render(window), 0x0C0A10))
        window.traitOverrides[SeasonTrait.self] = nil
        #expect(close(render(window), 0x0E0E0E))
    }
}
```

- [ ] **Step 2: Vérifier l'échec.** `xcodegen generate` puis TESTS iOS. Attendu : échec de compilation, « cannot find 'SeasonTrait' / 'SeasonalColor' in scope ».

- [ ] **Step 3: Le trait, le pont, la résolution, l'applicateur.** Créer `Shared/DesignSystem/Seasons/SeasonTrait.swift` :

```swift
import SwiftUI
import UIKit

// MARK: - Season trait
//
// The active season rides the UIKit trait system: set once on the window
// scene (`SeasonTraitApplier`), it reaches every window (the app's, the
// toasts', every UIKit presentation) and — through the bridge below — the
// SwiftUI environment as `\.seasonID`. `Color.dynamic` reads it in its
// provider, so the ~800 `CinemaColor` call sites repaint with no change.

struct SeasonTrait: UITraitDefinition {
    static let defaultValue: String? = nil
    static let affectsColorAppearance = true
    static let identifier = "com.cinemax.trait.season"
    static let name = "Season"
}

private struct SeasonEnvironmentKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension SeasonEnvironmentKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> String? {
        traitCollection[SeasonTrait.self]
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: String?) {
        mutableTraits[SeasonTrait.self] = value
    }
}

extension EnvironmentValues {
    /// The active season's id, or `nil`. Views read THIS (a value, never a
    /// required object — a context menu or a sheet without the root's
    /// injected objects must not crash), then `SeasonalThemeCatalogue.theme(id:)`.
    var seasonID: String? {
        get { self[SeasonEnvironmentKey.self] }
        set { self[SeasonEnvironmentKey.self] = newValue }
    }
}

enum SeasonalColor {
    /// The hex a `CinemaColor` token paints. `token == nil`: the season never
    /// touches it.
    static func resolve(light: UInt, dark: UInt, token: SeasonToken?, isDark: Bool, season: SeasonalTheme?) -> UInt {
        if let token, let season {
            if isDark { return season.dark[token] }
            if let palette = season.light { return palette[token] }
        }
        return isDark ? dark : light
    }
}

/// Zero-size view that writes the season onto its window SCENE, so the
/// toasts' own window and the UIKit player get it too.
struct SeasonTraitApplier: UIViewRepresentable {
    let seasonID: String?

    func makeUIView(context: Context) -> SeasonTraitApplierView {
        let view = SeasonTraitApplierView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SeasonTraitApplierView, context: Context) {
        view.setSeasonID(seasonID)
    }
}

final class SeasonTraitApplierView: UIView {
    private var seasonID: String?

    func setSeasonID(_ id: String?) {
        seasonID = id
        apply()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        guard let scene = window?.windowScene else { return }
        if scene.traitOverrides[SeasonTrait.self] != seasonID {
            scene.traitOverrides[SeasonTrait.self] = seasonID
        }
    }
}
```

- [ ] **Step 4: `Color.dynamic` lit la saison.** Dans `Shared/DesignSystem/CinemaGlassTheme.swift`, remplacer la fonction `dynamic(light:dark:)` (lignes 6-17) par :

```swift
    /// Resolves to `dark` hex when the trait collection is dark, otherwise `light` hex —
    /// or, for a token a season covers (`season:`), to the active season's value
    /// (`SeasonTrait`, set on the scene by `SeasonTraitApplier`). The scheme is set at
    /// the root via `.preferredColorScheme(themeManager.colorScheme)` in AppNavigation,
    /// so the UITraitCollection propagates to every UIHostingController automatically.
    static func dynamic(light: UInt, dark: UInt, season token: SeasonToken? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let season = token == nil ? nil : SeasonalThemeCatalogue.theme(id: traits[SeasonTrait.self])
            return UIColor(hexInt: SeasonalColor.resolve(
                light: light, dark: dark, token: token,
                isDark: traits.userInterfaceStyle != .light, season: season
            ))
        })
    }
```

et, dans `enum CinemaColor`, passer le token à chaque couleur couverte (les autres ne changent pas) :

```swift
    static let surface                 = Color.dynamic(light: 0xF7F7F8, dark: 0x0E0E0E, season: .surface)
    static let surfaceContainerLowest  = Color.dynamic(light: 0xFFFFFF, dark: 0x000000, season: .surfaceContainerLowest)
    static let surfaceContainerLow     = Color.dynamic(light: 0xF1F1F2, dark: 0x131313, season: .surfaceContainerLow)
    static let surfaceContainer        = Color.dynamic(light: 0xEAEAEC, dark: 0x191A1A, season: .surfaceContainer)
    static let surfaceContainerHigh    = Color.dynamic(light: 0xE2E2E5, dark: 0x1F2020, season: .surfaceContainerHigh)
    static let surfaceContainerHighest = Color.dynamic(light: 0xD9D9DD, dark: 0x252626, season: .surfaceContainerHighest)
    static let surfaceVariant          = Color.dynamic(light: 0xE2E2E5, dark: 0x252626, season: .surfaceVariant)

    // Text
    static let onSurface        = Color.dynamic(light: 0x14161A, dark: 0xE7E5E4, season: .onSurface)
    static let onSurfaceVariant = Color.dynamic(light: 0x55585E, dark: 0xACABAA, season: .onSurfaceVariant)
    /// Tertiary TEXT — card subtitles and detail lines. `outline` is a stroke
    /// colour and read 2.0:1 as text in light mode (4.2:1 in dark); this one
    /// clears 4.5:1 on `surface` in both (4.8 / 5.8). Audit §5, lot 9.
    static let onSurfaceMuted = Color.dynamic(light: 0x6B6E74, dark: 0x8E8D8D, season: .onSurfaceMuted)
```

et plus bas :

```swift
    static let outline        = Color.dynamic(light: 0xB0B1B5, dark: 0x767575, season: .outline)
    static let outlineVariant = Color.dynamic(light: 0xCFD0D3, dark: 0x484848, season: .outlineVariant)
```

- [ ] **Step 5: Vérifier.** TESTS iOS, puis TESTS tvOS. Attendu : `✔ Suite "Seasonal palette" passed` sur les deux.

  **Si `renderedHalloween` / `changingTheTraitRedrawsLive` échouent** (le trait n'atteint pas les couleurs SwiftUI), appliquer le **repli B** de la spec §5 et le noter dans le message de commit :
  1. Dans `SeasonTrait.swift`, ajouter :
     ```swift
     /// Fallback B (spec §5): the season the palette paints, written only by
     /// `SeasonalThemeController` on the main actor. Read by the UIColor provider.
     enum SeasonalPaletteState {
         nonisolated(unsafe) static var activeSeasonID: String?
     }
     ```
  2. Dans `Color.dynamic`, remplacer `traits[SeasonTrait.self]` par `traits[SeasonTrait.self] ?? SeasonalPaletteState.activeSeasonID`.
  3. Dans les tests de rendu, remplacer `window.traitOverrides[SeasonTrait.self] = X` par `SeasonalPaletteState.activeSeasonID = X` suivi de `window.rootViewController = UIHostingController(rootView: CinemaColor.surface.ignoresSafeArea())` (reconstruction), et remettre `SeasonalPaletteState.activeSeasonID = nil` dans un `defer`.
  4. Task 3 appliquera alors `.id(seasonal.activeTheme?.id ?? "none")` à la racine, et `SeasonalThemeController.reevaluate()` écrira `SeasonalPaletteState.activeSeasonID` (instructions notées dans Task 3, Step 6).

- [ ] **Step 6: Commit.**

```bash
git add Shared/DesignSystem/Seasons/SeasonTrait.swift Shared/DesignSystem/CinemaGlassTheme.swift Tests/CinemaxKitTests/SeasonalPaletteTests.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(saisons): palette de saison via un trait UIKit ponté vers SwiftUI

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Contrôleur, accent de saison, câblage racine

**Files:**
- Create: `Shared/DesignSystem/Seasons/SeasonalThemeController.swift`
- Modify: `Shared/DesignSystem/SettingsKeys.swift` (bloc « Appearance / theme » l.12-16, bloc « Debug » l.121-123, `enum Default`)
- Modify: `Shared/DesignSystem/ThemeManager.swift`
- Modify: `Shared/Navigation/AppNavigation.swift` (singletons l.28-41, `@State` l.43-72, modificateurs l.186-245, `onChange(of: scenePhase)` l.496)
- Modify: `Shared/DesignSystem/Components/ToastWindow.swift` (`ToastWindowHost`)
- Test: `Tests/CinemaxKitTests/SeasonalThemeControllerTests.swift`

**Interfaces:**
- Consumes: `SeasonalThemePolicy`, `SeasonalThemeCatalogue`, `SeasonalSetting` (Task 1) ; `SeasonTraitApplier`, `\.seasonID` (Task 2).
- Produces: `SeasonalThemeController(defaults:catalogue:calendar:now:)` avec `activeTheme: SeasonalTheme?`, `setting: SeasonalSetting`, `ambianceEnabled: Bool`, `rowEnabled: Bool`, `forcedSeasonID: String`, `setSetting(_:)`, `setAmbianceEnabled(_:)`, `setRowEnabled(_:)`, `setForcedSeason(_:)`, `@discardableResult reevaluate() -> Bool` ; `SettingsKey.seasonalTheme / seasonalAmbiance / seasonalRow / debugForcedSeason` (+ `Default`) ; `ThemeManager.setSeasonAccent(_ palette: AccentOption.Palette?)`, `ThemeManager.isSeasonAccentActive: Bool`.

- [ ] **Step 1: Écrire les tests.** Créer `Tests/CinemaxKitTests/SeasonalThemeControllerTests.swift` :

```swift
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Cinemax

/// A clock a test can move. Read from the controller's `@Sendable` `now`.
private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ iso: String) { date = ISO8601DateFormatter().date(from: iso)! }
    func set(_ iso: String) { date = ISO8601DateFormatter().date(from: iso)! }
}

@Suite("Seasonal theme controller")
@MainActor
struct SeasonalThemeControllerTests {
    private var paris: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }

    private func make(_ clock: TestClock, defaults: UserDefaults = .isolatedForTesting()) -> SeasonalThemeController {
        SeasonalThemeController(defaults: defaults, calendar: paris, now: { clock.date })
    }

    @Test("Active inside the window on first evaluation")
    func activeAtLaunch() {
        let c = make(TestClock("2026-10-20T12:00:00Z"))
        #expect(c.activeTheme?.id == "halloween")
    }

    @Test("Inactive outside the window")
    func inactiveOutside() {
        let c = make(TestClock("2026-06-20T12:00:00Z"))
        #expect(c.activeTheme == nil)
    }

    @Test("Day change ends the season without relaunch")
    func dayChangeEndsTheSeasonWithoutRelaunch() {
        let clock = TestClock("2026-11-02T22:30:00Z")   // 23:30 in Paris, 2 Nov
        let c = make(clock)
        #expect(c.activeTheme?.id == "halloween")
        clock.set("2026-11-02T23:00:01Z")               // 00:00:01, 3 Nov
        #expect(c.reevaluate() == true)
        #expect(c.activeTheme == nil)
        #expect(c.reevaluate() == false)                // nothing changed
    }

    @Test("Turning the setting off ends the season now, and persists")
    func settingOff() {
        let defaults = UserDefaults.isolatedForTesting()
        let c = make(TestClock("2026-10-20T12:00:00Z"), defaults: defaults)
        c.setSetting(.off)
        #expect(c.activeTheme == nil)
        #expect(defaults.string(forKey: SettingsKey.seasonalTheme) == "off")
        let reborn = make(TestClock("2026-10-20T12:00:00Z"), defaults: defaults)
        #expect(reborn.setting == .off)
        #expect(reborn.activeTheme == nil)
    }

    @Test("Forcing a season works outside its window; clearing restores the date rule")
    func forcing() {
        let c = make(TestClock("2026-06-20T12:00:00Z"))
        c.setForcedSeason("halloween")
        #expect(c.activeTheme?.id == "halloween")
        c.setForcedSeason("")
        #expect(c.activeTheme == nil)
    }

    @Test("Ambiance and row switches persist")
    func switches() {
        let defaults = UserDefaults.isolatedForTesting()
        let c = make(TestClock("2026-10-20T12:00:00Z"), defaults: defaults)
        #expect(c.ambianceEnabled && c.rowEnabled)
        c.setAmbianceEnabled(false)
        c.setRowEnabled(false)
        #expect(defaults.bool(forKey: SettingsKey.seasonalAmbiance) == false)
        #expect(defaults.bool(forKey: SettingsKey.seasonalRow) == false)
    }

    // MARK: ThemeManager

    private func darkHex(_ color: Color) -> UInt {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt((r * 255).rounded()) << 16 | UInt((g * 255).rounded()) << 8 | UInt((b * 255).rounded())
    }

    @Test("Season accent replaces the displayed accent, never the stored one")
    func seasonAccent() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("blue", forKey: SettingsKey.accentColor)
        let tm = ThemeManager(defaults: defaults)
        tm.setSeasonAccent(SeasonalThemeCatalogue.halloween.accent)
        #expect(tm.isSeasonAccentActive)
        #expect(darkHex(tm.accent) == 0xFF7A1A)
        #expect(tm.accentColorKey == "blue")
        tm.setSeasonAccent(nil)
        #expect(!tm.isSeasonAccentActive)
        #expect(darkHex(tm.accent) == 0x679CFF)
    }

    @Test("Season accent beats the rainbow easter egg")
    func seasonAccentBeatsRainbow() {
        let defaults = UserDefaults.isolatedForTesting()
        defaults.set("rainbow", forKey: SettingsKey.accentColor)
        let tm = ThemeManager(defaults: defaults)
        tm.setSeasonAccent(SeasonalThemeCatalogue.halloween.accent)
        #expect(darkHex(tm.accent) == 0xFF7A1A)
        #expect(darkHex(tm.accentContainer) == 0xE06A1A)
    }
}
```

- [ ] **Step 2: Vérifier l'échec.** `xcodegen generate`, TESTS iOS. Attendu : « cannot find 'SeasonalThemeController' in scope ».

- [ ] **Step 3: Les clés.** Dans `Shared/DesignSystem/SettingsKeys.swift`, sous `static let appLanguage = "appLanguage"` :

```swift
    /// Seasonal themes (`SeasonalThemeController`): `SeasonalSetting` raw value.
    static let seasonalTheme = "appearance.seasonalTheme"
    static let seasonalAmbiance = "appearance.seasonalAmbiance"
    static let seasonalRow = "appearance.seasonalRow"
```

sous `static let debugShowSkipToEnd = "debug.showSkipToEnd"` :

```swift
    /// Debug: id of a catalogue season to force regardless of the date ("" = none).
    static let debugForcedSeason = "debug.forcedSeason"
```

dans `enum Default`, sous `static let appLanguage = "fr"` :

```swift
        static let seasonalTheme = SeasonalSetting.automatic.rawValue
        static let seasonalAmbiance = true
        static let seasonalRow = true
```

et sous `static let debugShowSkipToEnd = false` :

```swift
        static let debugForcedSeason = ""
```

- [ ] **Step 4: Le contrôleur.** Créer `Shared/DesignSystem/Seasons/SeasonalThemeController.swift` :

```swift
import Foundation
import Observation

/// Owns « which season is on now ». A process singleton hosted by
/// `AppNavigation`, re-evaluated at launch, on return to the foreground, on
/// the day change and whenever a setting moves. Plain stored properties +
/// explicit mutators — no `didSet` on an `@Observable` (root RULE).
@MainActor @Observable
final class SeasonalThemeController {
    private(set) var activeTheme: SeasonalTheme?
    private(set) var setting: SeasonalSetting
    private(set) var ambianceEnabled: Bool
    private(set) var rowEnabled: Bool
    private(set) var forcedSeasonID: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalogue: [SeasonalTheme]
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults = .standard,
        catalogue: [SeasonalTheme] = SeasonalThemeCatalogue.all,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.catalogue = catalogue
        self.calendar = calendar
        self.now = now
        setting = SeasonalSetting(rawValue: defaults.string(forKey: SettingsKey.seasonalTheme) ?? "") ?? .automatic
        ambianceEnabled = defaults.object(forKey: SettingsKey.seasonalAmbiance) as? Bool ?? SettingsKey.Default.seasonalAmbiance
        rowEnabled = defaults.object(forKey: SettingsKey.seasonalRow) as? Bool ?? SettingsKey.Default.seasonalRow
        forcedSeasonID = defaults.string(forKey: SettingsKey.debugForcedSeason) ?? SettingsKey.Default.debugForcedSeason
        reevaluate()
    }

    /// Recomputes the active season; writes only when it changed. Returns
    /// whether it did.
    @discardableResult
    func reevaluate() -> Bool {
        let theme = SeasonalThemePolicy.activeTheme(
            on: now(), calendar: calendar, setting: setting,
            forcedID: forcedSeasonID, catalogue: catalogue
        )
        guard theme != activeTheme else { return false }
        activeTheme = theme
        return true
    }

    func setSetting(_ value: SeasonalSetting) {
        setting = value
        defaults.set(value.rawValue, forKey: SettingsKey.seasonalTheme)
        reevaluate()
    }

    func setAmbianceEnabled(_ value: Bool) {
        ambianceEnabled = value
        defaults.set(value, forKey: SettingsKey.seasonalAmbiance)
    }

    func setRowEnabled(_ value: Bool) {
        rowEnabled = value
        defaults.set(value, forKey: SettingsKey.seasonalRow)
    }

    func setForcedSeason(_ id: String) {
        forcedSeasonID = id
        defaults.set(id, forKey: SettingsKey.debugForcedSeason)
        reevaluate()
    }
}
```

- [ ] **Step 5: L'accent de saison dans `ThemeManager`.** Dans `Shared/DesignSystem/ThemeManager.swift` :
  1. Sous `private var _rainbowTick: Int = 0`, ajouter :
     ```swift
         /// The active season's accent (`SeasonalThemeController` → `AppNavigation`).
         /// Replaces the DISPLAYED accent — rainbow included — and never touches
         /// `accentColorKey`, which comes back as soon as the season ends.
         private var _seasonAccent: AccentOption.Palette?

         var isSeasonAccentActive: Bool { _seasonAccent != nil }

         func setSeasonAccent(_ palette: AccentOption.Palette?) {
             guard palette != _seasonAccent else { return }
             _seasonAccent = palette
             _accentRevision += 1
         }
     ```
  2. Remplacer `var isRainbow: Bool { accentColorKey == "rainbow" }` par :
     ```swift
         var isRainbow: Bool { accentColorKey == "rainbow" && _seasonAccent == nil }
     ```
  3. Remplacer le getter `palette` par :
     ```swift
         private var palette: AccentOption.Palette {
             _seasonAccent ?? (AccentOption(rawValue: accentColorKey) ?? .green).palette
         }
     ```
  (`startRainbowIfNeeded` lit `isRainbow` : la tâche arc-en-ciel s'arrête d'elle-même pendant la saison.)

- [ ] **Step 6: Câblage racine.** Dans `Shared/Navigation/AppNavigation.swift` :
  1. Sous `private static let sharedParentalLock = ParentalLockController()` :
     ```swift
         /// Seasonal themes — a process singleton like the stores above, so a
         /// scene-struct recreation never re-reads the defaults.
         private static let sharedSeasonal = SeasonalThemeController()
     ```
  2. Sous `@State private var parentalLock = AppNavigation.sharedParentalLock` :
     ```swift
         @State private var seasonal = AppNavigation.sharedSeasonal
     ```
  3. Remplacer `.background(ToastWindowHost(toasts: toasts, loc: loc, themeManager: themeManager))` par :
     ```swift
             .background(ToastWindowHost(toasts: toasts, loc: loc, themeManager: themeManager, seasonal: seasonal))
             // The season rides the SCENE's traits: every window (toasts, the
             // UIKit player) and — bridged — SwiftUI's `\.seasonID` follow it.
             .background(SeasonTraitApplier(seasonID: seasonal.activeTheme?.id))
     ```
  4. Sous `.environment(parentalLock)` :
     ```swift
             .environment(seasonal)
             .onChange(of: seasonal.activeTheme?.id, initial: true) { _, _ in
                 themeManager.setSeasonAccent(seasonal.activeTheme?.accent)
             }
             // Midnight: a season can start or end while the app stays open.
             .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                 seasonal.reevaluate()
             }
     ```
  5. Dans `.onChange(of: scenePhase) { _, newPhase in`, en tête du corps :
     ```swift
                 if newPhase == .active { seasonal.reevaluate() }
     ```
  6. **Seulement si Task 2 a basculé sur le repli B** : ajouter `.id(seasonal.activeTheme?.id ?? "none")` sur la vue qui porte `.background(ToastWindowHost…)` (en tête de la chaîne de modificateurs), et dans `SeasonalThemeController.reevaluate()` écrire `SeasonalPaletteState.activeSeasonID = theme?.id` juste avant `activeTheme = theme`.

  Le fichier importe déjà `Combine` si `.receive(on:)` compile ; sinon ajouter `import Combine` en tête.

- [ ] **Step 7: La fenêtre des toasts.** Dans `Shared/DesignSystem/Components/ToastWindow.swift`, `ToastWindowHost` reçoit le contrôleur et le repasse (l'overlay est une autre fenêtre de la même scène : le trait de scène lui parvient déjà ; l'objet sert à ce que `\.seasonID` soit aussi posé explicitement si le pont échoue) :

```swift
struct ToastWindowHost: UIViewRepresentable {
    let toasts: ToastCenter
    let loc: LocalizationManager
    let themeManager: ThemeManager
    let seasonal: SeasonalThemeController

    func makeUIView(context: Context) -> ToastWindowInstallerView {
        let view = ToastWindowInstallerView()
        view.isUserInteractionEnabled = false
        view.makeRoot = { [toasts, loc, themeManager, seasonal] window in
            AnyView(ToastWindowRoot(window: window)
                .environment(toasts)
                .environment(loc)
                .environment(themeManager)
                .environment(seasonal))
        }
        return view
    }

    func updateUIView(_ uiView: ToastWindowInstallerView, context: Context) {}
}
```

et dans `ToastWindowRoot`, ajouter `@Environment(SeasonalThemeController.self) private var seasonal` et, sur la vue renvoyée par `body`, `.environment(\.seasonID, seasonal.activeTheme?.id)`.

- [ ] **Step 8: Vérifier.** TESTS iOS puis TESTS tvOS. Attendu : `✔ Suite "Seasonal theme controller" passed` sur les deux, aucune régression (`✔ Test run with N tests`).

- [ ] **Step 9: Commit.**

```bash
git add Shared/DesignSystem/Seasons/SeasonalThemeController.swift Shared/DesignSystem/SettingsKeys.swift Shared/DesignSystem/ThemeManager.swift Shared/Navigation/AppNavigation.swift Shared/DesignSystem/Components/ToastWindow.swift Tests/CinemaxKitTests/SeasonalThemeControllerTests.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(saisons): contrôleur, accent de saison et câblage racine

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Réglages (Apparence iOS + tvOS, note d'accent, Debug)

**Files:**
- Modify: `Shared/Screens/Settings/SettingsAppearanceView+iOS.swift`
- Modify: `Shared/Screens/Settings/SettingsScreen+tvOS.swift` (`tvAppearanceDetail`, l.317)
- Modify: `Shared/Screens/Settings/SettingsScreen.swift` (`struct SettingsScreen` l.138, `debugToggleRows` l.351)
- Create: `Shared/DesignSystem/Seasons/SeasonalSettingsText.swift`
- Modify: `Resources/{fr,en}.lproj/Localizable.strings`
- Test: `Tests/CinemaxKitTests/SeasonalThemePolicyTests.swift` (ajout)

**Interfaces:**
- Consumes: `SeasonalThemeController` (Task 3), `SeasonalThemeCatalogue` (Task 1).
- Produces: `SeasonalSettingsText.windowSummary(for:name:template:locale:calendar:) -> String`, `SeasonalSettingsText.catalogueSummary(loc:calendar:) -> String`.

**Choix d'interface (à signaler à l'utilisateur à la remise du plan) :** la spec parle d'un « sélecteur Automatique / Désactivé ». Le réglage n'a que deux états ; il est rendu comme une **bascule « Thème saisonnier »** (activée = Automatique), identique sur iOS et tvOS, sous-titrée par les dates. Aucun autre changement de comportement.

- [ ] **Step 1: Test du résumé de dates.** `LocalizationManager` lit `UserDefaults.standard` sans point d'injection : le test porte donc sur la fonction PURE (nom, gabarit, locale passés en clair). Ajouter à `SeasonalThemePolicyTests` :

```swift
    @Test("Settings summary: season name and dates, day-month order of the locale")
    @MainActor
    func windowSummary() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let fr = SeasonalSettingsText.windowSummary(
            for: halloween, name: "Nuit d'Halloween", template: "%1$@, du %2$@ au %3$@",
            locale: Locale(identifier: "fr_FR"), calendar: utc
        )
        let en = SeasonalSettingsText.windowSummary(
            for: halloween, name: "Halloween Night", template: "%1$@, %2$@ to %3$@",
            locale: Locale(identifier: "en_US"), calendar: utc
        )
        #expect(fr == "Nuit d'Halloween, du 15 octobre au 2 novembre")
        #expect(en == "Halloween Night, October 15 to November 2")
    }
```

- [ ] **Step 2: Vérifier l'échec.** TESTS iOS. Attendu : « cannot find 'SeasonalSettingsText' in scope ».

- [ ] **Step 3: Chaînes.** Ajouter en fin de `Resources/fr.lproj/Localizable.strings` :

```
"settings.seasonal.section" = "Thème saisonnier";
"settings.seasonal.toggle" = "Thème saisonnier";
"settings.seasonal.window" = "%1$@, du %2$@ au %3$@";
"settings.seasonal.ambiance" = "Animations d'ambiance";
"settings.seasonal.row" = "Rangée de saison";
"settings.seasonal.accentNote" = "Pendant « %@ », la couleur de la saison remplace la vôtre.";
"settings.debug.forceSeason" = "Forcer « %@ »";
```

et en fin de `Resources/en.lproj/Localizable.strings` :

```
"settings.seasonal.section" = "Seasonal theme";
"settings.seasonal.toggle" = "Seasonal theme";
"settings.seasonal.window" = "%1$@, %2$@ to %3$@";
"settings.seasonal.ambiance" = "Ambient animations";
"settings.seasonal.row" = "Seasonal row";
"settings.seasonal.accentNote" = "During “%@”, the season's colour replaces yours.";
"settings.debug.forceSeason" = "Force “%@”";
```

- [ ] **Step 4: Le résumé.** Créer `Shared/DesignSystem/Seasons/SeasonalSettingsText.swift` :

```swift
import Foundation

@MainActor
enum SeasonalSettingsText {
    /// « Nuit d'Halloween, du 15 octobre au 2 novembre » — pure: the caller
    /// passes the localized name, the `settings.seasonal.window` template and
    /// the APP's locale (`loc.locale`, Localisation RULE). This year's dates.
    static func windowSummary(for theme: SeasonalTheme, name: String, template: String, locale: Locale, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: Date())
        func text(_ md: MonthDay) -> String {
            let date = calendar.date(from: DateComponents(year: year, month: md.month, day: md.day)) ?? Date()
            var style = Date.FormatStyle(date: .omitted, time: .omitted).day().month(.wide).locale(locale)
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
        return String(format: template, locale: locale, name, text(theme.window.start), text(theme.window.end))
    }

    /// Every catalogue season, one line each, in the app's language.
    static func catalogueSummary(loc: LocalizationManager, calendar: Calendar = .autoupdatingCurrent) -> String {
        SeasonalThemeCatalogue.all.map {
            windowSummary(
                for: $0, name: loc.localized($0.nameKey),
                template: loc.localized("settings.seasonal.window"),
                locale: loc.locale, calendar: calendar
            )
        }.joined(separator: "\n")
    }
}
```

- [ ] **Step 5: iOS.** Dans `IOSAppearanceDetailView` (`SettingsAppearanceView+iOS.swift`) :
  1. Sous `@Environment(LocalizationManager.self) var loc` : `@Environment(SeasonalThemeController.self) private var seasonal`.
  2. Dans la ligne d'accent, juste après le `HStack(spacing: 0) { ForEach(…) { accentDot(option) } }`, ajouter :
     ```swift
                        if let theme = seasonal.activeTheme {
                            Text(loc.localized("settings.seasonal.accentNote", loc.localized(theme.nameKey)))
                                .font(CinemaFont.dynamicLabel(.small))
                                .foregroundStyle(CinemaColor.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
     ```
  3. Après le `.glassPanel(cornerRadius: CinemaRadius.extraLarge)` du panneau existant (fin du `VStack` principal), ajouter une section :
     ```swift
            iOSSettingsSectionHeader(loc.localized("settings.seasonal.section"))
                .padding(.top, CinemaSpacing.spacing4)

            VStack(spacing: 0) {
                Button {
                    seasonal.setSetting(seasonal.setting == .automatic ? .off : .automatic)
                    Haptics.tap()
                } label: {
                    iOSSettingsRow {
                        SettingsRowAdaptiveLayout {
                            HStack {
                                iOSRowIcon(systemName: "calendar", color: themeManager.accent)
                                VStack(alignment: .leading, spacing: CinemaSpacing.spacing1) {
                                    Text(loc.localized("settings.seasonal.toggle"))
                                        .font(CinemaFont.dynamicLabel(.large))
                                        .foregroundStyle(CinemaColor.onSurface)
                                    Text(SeasonalSettingsText.catalogueSummary(loc: loc))
                                        .font(CinemaFont.dynamicLabel(.small))
                                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } control: {
                            CinemaToggleIndicator(isOn: seasonal.setting == .automatic, accent: themeManager.accent, animated: motionEffects)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(loc.localized("settings.seasonal.toggle"))
                .accessibilityValue(loc.localized(seasonal.setting == .automatic ? "a11y.toggle.on" : "a11y.toggle.off"))
                .accessibilityHint(SeasonalSettingsText.catalogueSummary(loc: loc))
                .accessibilityAddTraits(.isToggle)

                iOSSettingsDivider

                iOSToggleRow(
                    icon: "sparkles",
                    label: loc.localized("settings.seasonal.ambiance"),
                    value: Binding(get: { seasonal.ambianceEnabled }, set: { seasonal.setAmbianceEnabled($0) }),
                    accent: themeManager.accent, animated: motionEffects, loc: loc
                )

                iOSSettingsDivider

                iOSToggleRow(
                    icon: "rectangle.stack",
                    label: loc.localized("settings.seasonal.row"),
                    value: Binding(get: { seasonal.rowEnabled }, set: { seasonal.setRowEnabled($0) }),
                    accent: themeManager.accent, animated: motionEffects, loc: loc
                )
            }
            .glassPanel(cornerRadius: CinemaRadius.extraLarge)
     ```

- [ ] **Step 6: tvOS.** Dans `SettingsScreen.swift`, `struct SettingsScreen`, sous `@Environment(ToastCenter.self) var toasts` : `@Environment(SeasonalThemeController.self) var seasonal`. Puis dans `tvAppearanceDetail` (`SettingsScreen+tvOS.swift`), remplacer la ligne `tvAccentColorPicker` par :

```swift
            tvAccentColorPicker

            if let theme = seasonal.activeTheme {
                Text(loc.localized("settings.seasonal.accentNote", loc.localized(theme.nameKey)))
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
```

et, juste avant `tvFontSizeRow`, ajouter :

```swift
            tvGlassToggle(
                icon: "calendar",
                label: loc.localized("settings.seasonal.toggle"),
                key: "seasonalTheme",
                value: Binding(
                    get: { seasonal.setting == .automatic },
                    set: { seasonal.setSetting($0 ? .automatic : .off) }
                ),
                subtitle: SeasonalSettingsText.catalogueSummary(loc: loc)
            )

            tvGlassToggle(
                icon: "sparkles",
                label: loc.localized("settings.seasonal.ambiance"),
                key: "seasonalAmbiance",
                value: Binding(get: { seasonal.ambianceEnabled }, set: { seasonal.setAmbianceEnabled($0) })
            )

            tvGlassToggle(
                icon: "rectangle.stack",
                label: loc.localized("settings.seasonal.row"),
                key: "seasonalRow",
                value: Binding(get: { seasonal.rowEnabled }, set: { seasonal.setRowEnabled($0) })
            )
```

- [ ] **Step 7: Debug.** Dans `SettingsScreen.swift`, remplacer le corps de `debugToggleRows` par :

```swift
        [
            .init(id: "debugFastSleep", icon: "moon.zzz.fill", label: loc.localized("settings.debug.fastSleepTimer"), value: $debugFastSleepTimer, tint: .orange),
            .init(id: "debugSkipToEnd", icon: "forward.end.fill", label: loc.localized("settings.debug.skipToEnd"), value: $debugShowSkipToEnd, tint: .orange)
        ] + SeasonalThemeCatalogue.all.map { theme in
            .init(
                id: "debugSeason.\(theme.id)",
                icon: "calendar.badge.exclamationmark",
                label: loc.localized("settings.debug.forceSeason", loc.localized(theme.nameKey)),
                value: Binding(
                    get: { seasonal.forcedSeasonID == theme.id },
                    set: { seasonal.setForcedSeason($0 ? theme.id : "") }
                ),
                tint: .orange
            )
        }
```

- [ ] **Step 8: Vérifier.** `xcodegen generate`, TESTS iOS, TESTS tvOS, puis la parité :

```bash
python3 scripts/check-localization-parity.py
```

Attendu : tests verts sur les deux schémas ; le script de parité ne signale rien.

- [ ] **Step 9: Commit.**

```bash
git add Shared/Screens/Settings Shared/DesignSystem/Seasons/SeasonalSettingsText.swift Resources/*/Localizable.strings Tests/CinemaxKitTests/SeasonalThemePolicyTests.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(saisons): réglages Apparence (iOS, tvOS), note d'accent, saison forcée en Debug

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Titres de saison (Fraunces)

**Files:**
- Create: `Resources/Fonts/Fraunces-BlackItalic.ttf`
- Create: `Shared/DesignSystem/Seasons/SeasonalTypography.swift`
- Modify: `project.yml` (les deux blocs `info.properties` : `Cinemax` l.101, `CinemaxTV` l.228)
- Modify: `Shared/DesignSystem/Seasons/SeasonalThemeCatalogue.swift` (nom PostScript, si différent)
- Modify: `Shared/Screens/HomeScreen.swift:773-778`, `Shared/Screens/LibraryHeroSection.swift:74-79`, `Shared/Screens/MediaDetailScreen.swift:602-608`
- Modify: `Shared/DesignSystem/Components/ContentRow.swift` (paramètre `titleFont`)
- Modify: `Shared/Screens/LicensesView.swift` (liste), `scripts/dependency-audit.py` (`LICENSE_UNPINNED`)
- Test: `Tests/CinemaxKitTests/SeasonalPaletteTests.swift` (ajout)

**Interfaces:**
- Consumes: `SeasonalTheme.titleFont`, `\.seasonID`.
- Produces: `SeasonalTypography.titleFont(for: SeasonalTheme?, size: CGFloat) -> Font?`, `View.heroTitleStyle(size: CGFloat, uppercase: Bool) -> some View`, `ContentRow(title:titleFont:data:id:itemView:)`.

- [ ] **Step 1: Récupérer la police — DEMANDER L'ACCORD d'abord** (téléchargement de fichier : règle de sécurité). Proposer à l'utilisateur : « Télécharger l'archive de la dernière version de Fraunces (licence OFL) depuis github.com/undercasetype/Fraunces/releases, environ N Mo, pour n'en garder que l'instance statique Black Italic ? ». Après accord, dans le scratchpad :

```bash
cd "$SCRATCH" && gh release download --repo undercasetype/Fraunces --pattern '*.zip' && unzip -o -q *.zip -d fraunces && find fraunces -iname '*BlackItalic*.ttf'
```

Choisir l'instance statique de taille optique 72 pt si plusieurs existent (`*72pt*BlackItalic*.ttf`), sinon l'instance `BlackItalic` par défaut. La copier :

```bash
mkdir -p Resources/Fonts && cp "<fichier choisi>" Resources/Fonts/Fraunces-BlackItalic.ttf && cp fraunces/**/OFL.txt "$SCRATCH/OFL.txt" 2>/dev/null; ls -l Resources/Fonts
```

- [ ] **Step 2: Lire son nom PostScript.**

```bash
cat > "$SCRATCH/psname.swift" <<'EOF'
import CoreText
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let d = (CTFontManagerCreateFontDescriptorsFromURL(url) as! [CTFontDescriptor])[0]
print(CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as! String)
EOF
swift "$SCRATCH/psname.swift" Resources/Fonts/Fraunces-BlackItalic.ttf
```

Si le nom affiché n'est pas `Fraunces-BlackItalic`, remplacer `postScriptName: "Fraunces-BlackItalic"` dans `SeasonalThemeCatalogue.swift` par le nom affiché.

- [ ] **Step 3: Déclarer la police.** Dans `project.yml`, dans les `properties` de `Cinemax` (après `CFBundleDisplayName: JellyGlass`) ET de `CinemaxTV` (même endroit) :

```yaml
        # Seasonal title font (SeasonalThemeCatalogue → SeasonFont), OFL.
        UIAppFonts:
          - Fraunces-BlackItalic.ttf
```

Le dossier `Resources` est déjà une source des deux cibles : le fichier est embarqué. Le hook PostToolUse relance `xcodegen generate` ; sinon le lancer.

- [ ] **Step 4: Test d'enregistrement de la police.** Ajouter à `SeasonalPaletteTests` :

```swift
    @Test("Every season title font is bundled and registered")
    func seasonFontsRegistered() {
        for theme in SeasonalThemeCatalogue.all {
            guard let font = theme.titleFont else { continue }
            #expect(UIFont(name: font.postScriptName, size: 20) != nil, "\(font.postScriptName) not registered")
            #expect(SeasonalTypography.titleFont(for: theme, size: 40) != nil)
        }
    }

    @Test("No season: no title font override")
    func noSeasonNoFont() {
        #expect(SeasonalTypography.titleFont(for: nil, size: 40) == nil)
    }
```

Lancer TESTS iOS : échec attendu (« cannot find 'SeasonalTypography' »).

- [ ] **Step 5: La typographie.** Créer `Shared/DesignSystem/Seasons/SeasonalTypography.swift` :

```swift
import SwiftUI
import UIKit

@MainActor
enum SeasonalTypography {
    /// The season's display face at a FIXED size (`fixedSize:`): heroes and row
    /// titles size through `CinemaScale.pt`, never Dynamic Type — see the
    /// Dynamic Type RULE. `nil` when no season, no font, or the font failed to
    /// register (the caller keeps its system font).
    static func titleFont(for theme: SeasonalTheme?, size: CGFloat) -> Font? {
        guard let name = theme?.titleFont?.postScriptName, UIFont(name: name, size: size) != nil else { return nil }
        return .custom(name, fixedSize: size)
    }
}

/// The hero title: black system caps, or the season's italic display face in
/// title case (the canvas's « Nosferatu »).
private struct HeroTitleStyle: ViewModifier {
    @Environment(\.seasonID) private var seasonID
    let size: CGFloat
    let uppercase: Bool

    func body(content: Content) -> some View {
        if let font = SeasonalTypography.titleFont(for: SeasonalThemeCatalogue.theme(id: seasonID), size: size) {
            content.font(font).tracking(-0.5)
        } else {
            content
                .font(.system(size: size, weight: .black))
                .tracking(-1.5)
                .textCase(uppercase ? .uppercase : nil)
        }
    }
}

extension View {
    func heroTitleStyle(size: CGFloat, uppercase: Bool) -> some View {
        modifier(HeroTitleStyle(size: size, uppercase: uppercase))
    }
}
```

- [ ] **Step 6: Les trois héros.** Remplacer :
  - `HomeScreen.swift` (dans `heroSectionContent`) :
    ```swift
                    Text(item.name ?? "")
                        .heroTitleStyle(size: heroTitleSize, uppercase: true)
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(2)
    ```
    (à la place des lignes `.font(.system(size: heroTitleSize, weight: .black))`, `.tracking(-1.5)`, `.foregroundStyle(…)`, `.textCase(.uppercase)`, `.lineLimit(2)`).
  - `LibraryHeroSection.swift` : même remplacement, `heroTitleStyle(size: heroTitleSize, uppercase: true)`.
  - `MediaDetailScreen.swift`, `titleText(_:)` :
    ```swift
        private func titleText(_ item: BaseItemDto) -> some View {
            Text(item.name ?? "")
                .heroTitleStyle(size: detailTitleSize, uppercase: false)
                .foregroundStyle(CinemaColor.onSurface)
                .lineLimit(2)
        }
    ```

- [ ] **Step 7: `ContentRow.titleFont`.** Dans `ContentRow.swift`, sous `var onViewAll: (() -> Void)? = nil` : `var titleFont: Font? = nil`, et dans le `Text(title)` de l'en-tête remplacer `.font(CinemaFont.headline(.large))` par `.font(titleFont ?? CinemaFont.headline(.large))`.

- [ ] **Step 8: Crédit.** Dans `LicensesView.swift`, ajouter à la fin du tableau (avant `]`) :

```swift
            OSSLicense(
                name: "Fraunces",
                version: "<version de l'archive, ex. 1.000>",
                url: "github.com/undercasetype/Fraunces",
                text: "Copyright 2020 The Fraunces Project Authors (https://github.com/undercasetype/Fraunces)\n\nThis Font Software is licensed under the SIL Open Font License, Version 1.1.\nhttps://openfontlicense.org"
            ),
```

(la version = celle du nom de l'archive téléchargée à l'étape 1). Dans `scripts/dependency-audit.py`, `LICENSE_UNPINNED` :

```python
    "Fraunces": "font file bundled in Resources/Fonts (OFL), seasonal title face",
```

- [ ] **Step 9: Vérifier.**

```bash
python3 scripts/dependency-audit.py check --offline
```

Attendu : aucune erreur. Puis TESTS iOS et TESTS tvOS : `seasonFontsRegistered` vert sur les deux.

- [ ] **Step 10: Commit.**

```bash
git add Resources/Fonts project.yml Shared/DesignSystem/Seasons Shared/Screens/HomeScreen.swift Shared/Screens/LibraryHeroSection.swift Shared/Screens/MediaDetailScreen.swift Shared/DesignSystem/Components/ContentRow.swift Shared/Screens/LicensesView.swift scripts/dependency-audit.py Tests/CinemaxKitTests/SeasonalPaletteTests.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(saisons): titres de saison en Fraunces Black Italic (OFL)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Rangée de saison sur l'Accueil

**Files:**
- Modify: `Shared/ViewModels/HomeViewModel.swift` (état ~l.66, `clearContent` ~l.186, phase 2 l.432-460, nouvelles méthodes près de `reloadGenreRows` l.966)
- Modify: `Shared/Screens/HomeScreen.swift` (propriétés, `.task`, ligne après `continueWatchingRow` l.456, nouvelle vue près de `genreRow` l.542)
- Test: `Tests/CinemaxKitTests/SeasonalHomeRowTests.swift`

**Interfaces:**
- Consumes: `SeasonRow`, `SeasonRowMatcher` (Task 1) ; `SeasonalTypography.titleFont` + `ContentRow(titleFont:)` (Task 5) ; `\.seasonID` ; `SettingsKey.seasonalRow` (Task 3).
- Produces: `HomeViewModel.seasonRowItems: [BaseItemDto]`, `HomeViewModel.setSeasonRow(_ row: SeasonRow?)`, `HomeViewModel.refreshSeasonRow(using: AppState) async`.

- [ ] **Step 1: Tests.** Créer `Tests/CinemaxKitTests/SeasonalHomeRowTests.swift` :

```swift
import Foundation
import Testing
import JellyfinAPI
@testable import Cinemax
@testable import CinemaxKit

@Suite("Seasonal Home row")
@MainActor
struct SeasonalHomeRowTests {
    private let defaults = UserDefaults.isolatedForTesting()
    private let row = SeasonRow(titleKey: "season.halloween.row", genreCandidates: ["Horror", "Horreur"])

    private func item(_ id: String) -> BaseItemDto {
        var i = BaseItemDto(); i.id = id; i.name = id; return i
    }

    private func appState(_ api: MockAPIClient) -> AppState {
        let s = AppState(apiClient: api, keychain: MockKeychain())
        s.currentUserId = "user1"
        return s
    }

    @Test("The row queries the server's spelling of the genre")
    func loadsMatchingGenre() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Action", "Horreur"]
        api.stubbedLatestItems = [item("nosferatu")]
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(row)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.map(\.id) == ["nosferatu"])
        #expect(api.getItemsQueries.contains { $0.genres == ["Horreur"] })
    }

    @Test("No matching genre hides the row")
    func noMatchingGenreHidesTheRow() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Comédie"]
        api.stubbedLatestItems = [item("x")]
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(row)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.isEmpty)
        #expect(!api.getItemsQueries.contains { $0.genres == ["Comédie"] })
    }

    @Test("A matching genre with no items hides the row")
    func emptyGenreHidesTheRow() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Horror"]
        api.stubbedLatestItems = []
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(row)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.isEmpty)
    }

    @Test("A network failure hides the row, no retry chip")
    func failureHidesTheRow() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Horror"]
        api.shouldThrow = true
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(row)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.isEmpty)
    }

    @Test("Out of season: no request at all")
    func outOfSeasonNoRequest() async {
        let api = MockAPIClient()
        api.stubbedGenres = ["Horror"]
        let vm = HomeViewModel(defaults: defaults)
        vm.setSeasonRow(nil)
        await vm.refreshSeasonRow(using: appState(api))
        #expect(vm.seasonRowItems.isEmpty)
        #expect(api.getGenresCallCount == 0)
    }
}
```

Note sur le mock : `MockAPIClient.getItems` renvoie `stubbedLatestItems` pour toute requête `includeItemTypes == [.movie, .series]` sans `isFavorite` — la forme exacte de la requête de genre (`fetchGenreItems`) : c'est pourquoi ces tests stubbent `stubbedLatestItems`.

- [ ] **Step 2: Vérifier l'échec.** `xcodegen generate`, TESTS iOS : « value of type 'HomeViewModel' has no member 'setSeasonRow' ».

- [ ] **Step 3: Le view model.** Dans `HomeViewModel.swift` :
  1. Sous `var genreRows: [GenreRow] = []` :
     ```swift
         /// « Frissons d'Halloween » and the like — the active season's row
         /// (`SeasonRow`). Decorative: empty on no match, no items or failure,
         /// never a retry chip.
         var seasonRowItems: [BaseItemDto] = []
         /// Set by `HomeScreen` from the active season + the row switch.
         @ObservationIgnored private var seasonRowConfig: SeasonRow?
     ```
  2. Dans `clearContent()`, sous `genreRows = []` : `seasonRowItems = []`.
  3. Dans `load`, avec les autres `async let` de la phase 2 :
     ```swift
             async let seasonRowDone: Void = loadSeasonRow(userId: userId, appState: appState, generation: generation)
     ```
     et remplacer `_ = await (genreRowsDone, sessionsDone, becauseYouWatchedDone)` par `_ = await (genreRowsDone, sessionsDone, becauseYouWatchedDone, seasonRowDone)`.
  4. Sous `reloadGenreRows(using:)` :
     ```swift
         func setSeasonRow(_ row: SeasonRow?) {
             seasonRowConfig = row
         }

         /// Re-fetches only the season row — the season or its switch changed.
         func refreshSeasonRow(using appState: AppState) async {
             guard let userId = appState.currentUserId else { return }
             await loadSeasonRow(userId: userId, appState: appState, generation: loadGeneration)
         }

         private func loadSeasonRow(userId: String, appState: AppState, generation: Int) async {
             guard let row = seasonRowConfig else {
                 if isCurrent(generation) { seasonRowItems = [] }
                 return
             }
             guard let genres = try? await appState.apiClient.getGenres(userId: userId, includeItemTypes: [.movie, .series]),
                   let genre = SeasonRowMatcher.match(candidates: row.genreCandidates, in: genres),
                   let items = try? await Self.fetchGenreItems(genre: genre, userId: userId, appState: appState)
             else {
                 if isCurrent(generation) { seasonRowItems = [] }
                 return
             }
             guard isCurrent(generation) else { return }
             seasonRowItems = items
         }
     ```

- [ ] **Step 4: L'écran.** Dans `HomeScreen.swift` :
  1. Avec les autres propriétés d'environnement : `@Environment(\.seasonID) private var seasonID` et `@AppStorage(SettingsKey.seasonalRow) private var showSeasonRow: Bool = SettingsKey.Default.seasonalRow`.
  2. Propriétés calculées :
     ```swift
         private var activeSeason: SeasonalTheme? { SeasonalThemeCatalogue.theme(id: seasonID) }
         private var seasonRow: SeasonRow? { showSeasonRow ? activeSeason?.row : nil }
     ```
  3. Après le `.task { await viewModel.loadInitial(using: appState) … }` du `body` :
     ```swift
             // The season (or its row switch) changed: re-fetch just that row.
             // `initial` also runs it before the first load reads the config.
             .onChange(of: "\(seasonID ?? "")-\(showSeasonRow)", initial: true) { _, _ in
                 viewModel.setSeasonRow(seasonRow)
                 Task { await viewModel.refreshSeasonRow(using: appState) }
             }
     ```
  4. Juste après le bloc « Continue Watching » (`if showContinueWatching … continueWatchingRow …`) :
     ```swift
                     // The season's row (« Frissons d'Halloween ») — right under
                     // Continue Watching, as on the design canvas.
                     if let row = seasonRow, !viewModel.seasonRowItems.isEmpty {
                         seasonalRow(title: loc.localized(row.titleKey), items: viewModel.seasonRowItems)
                             .padding(.bottom, CinemaSpacing.spacing6)
                     }
     ```
  5. Sous `genreRow(genre:items:)` :
     ```swift
         @ViewBuilder
         private func seasonalRow(title: String, items: [BaseItemDto]) -> some View {
             ContentRow(
                 title: title,
                 titleFont: SeasonalTypography.titleFont(for: activeSeason, size: CinemaScale.pt(32)),
                 data: items, id: \.id
             ) { item in
                 recentlyAddedCard(item, surface: "home.season")
                     .frame(width: posterCardWidth)
             }
         }
     ```

- [ ] **Step 5: Vérifier.** TESTS iOS puis TESTS tvOS : `✔ Suite "Seasonal Home row" passed`, et `HomeViewModelTests` / `HomeRailGatingTests` toujours verts (la rangée hors saison ne fait aucune requête : les budgets de requêtes testés ne bougent pas).

- [ ] **Step 6: Commit.**

```bash
git add Shared/ViewModels/HomeViewModel.swift Shared/Screens/HomeScreen.swift Tests/CinemaxKitTests/SeasonalHomeRowTests.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(saisons): rangée de saison sur l'Accueil (Frissons d'Halloween)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Ambiance (brume, chauves-souris, lueur tvOS)

**Files:**
- Create: `Shared/DesignSystem/Seasons/SeasonalAmbiance.swift`
- Modify: `Shared/Screens/HomeScreen.swift` (`heroSectionContent`, après `.overlay { CinemaGradient.heroOverlay… }`), `Shared/Screens/LibraryHeroSection.swift`, `Shared/Screens/MediaDetailScreen.swift` (`backdropSectionContent`)
- Modify: `Shared/DesignSystem/FocusScaleModifier.swift` (`CinemaFocusModifier`)
- Test: `Tests/CinemaxKitTests/SeasonalAmbianceTests.swift`

**Interfaces:**
- Consumes: `AmbiancePolicy`, `AmbianceEffect` (Task 1) ; `\.seasonID` ; `SettingsKey.seasonalAmbiance` (Task 3).
- Produces: `SeasonalAmbianceOverlay()` (vue SwiftUI), `AmbianceView` (`setEffects(_:)`, `mistLayers`, `batLayers`, `static var batsFlownThisSession`, `mistKey`, `batKey`), `SeasonalFocusGlowView` (`setGlowing(_:)`, `animationKey`, tvOS).

- [ ] **Step 1: Tests.** Créer `Tests/CinemaxKitTests/SeasonalAmbianceTests.swift` :

```swift
import Testing
import UIKit
@testable import Cinemax

@MainActor
@Suite("Seasonal ambiance", .serialized)
struct SeasonalAmbianceTests {
    private func hosted() -> (UIWindow, AmbianceView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 600))
        let view = AmbianceView(frame: window.bounds)
        window.addSubview(view)
        return (window, view)
    }

    @Test("Mist: three drifting layers, gone when turned off")
    func mist() {
        let (window, view) = hosted()
        view.setEffects([.mist])
        #expect(view.mistLayers.count == 3)
        #expect(view.mistLayers.allSatisfy { $0.animation(forKey: AmbianceView.mistKey) != nil })
        view.setEffects([])
        #expect(view.mistLayers.isEmpty)
        _ = window
    }

    @Test("Bats fly once per session")
    func batsOnce() {
        AmbianceView.batsFlownThisSession = false
        let (w1, first) = hosted()
        first.setEffects([.bats])
        first.layoutIfNeeded()
        #expect(first.batLayers.count == 3)
        #expect(AmbianceView.batsFlownThisSession)
        let (w2, second) = hosted()
        second.setEffects([.bats])
        second.layoutIfNeeded()
        #expect(second.batLayers.isEmpty)
        _ = (w1, w2)
    }

    @Test("Off-window, nothing is added until the window")
    func offWindow() {
        let view = AmbianceView(frame: CGRect(x: 0, y: 0, width: 1200, height: 600))
        view.setEffects([.mist])
        #expect(view.mistLayers.isEmpty)
        let window = UIWindow(frame: view.frame)
        window.addSubview(view)
        #expect(view.mistLayers.count == 3)
    }

    #if os(tvOS)
    @Test("Focus glow pulses only while focused")
    func focusGlow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let glow = SeasonalFocusGlowView(frame: CGRect(x: 50, y: 50, width: 200, height: 120))
        window.addSubview(glow)
        glow.setGlowing(true)
        #expect(glow.layer.animation(forKey: SeasonalFocusGlowView.animationKey) != nil)
        glow.setGlowing(false)
        #expect(glow.layer.animation(forKey: SeasonalFocusGlowView.animationKey) == nil)
        #expect(glow.layer.shadowOpacity == 0)
    }
    #endif
}
```

- [ ] **Step 2: Vérifier l'échec.** `xcodegen generate`, TESTS iOS : « cannot find 'AmbianceView' in scope ».

- [ ] **Step 3: L'ambiance.** Créer `Shared/DesignSystem/Seasons/SeasonalAmbiance.swift` :

```swift
import SwiftUI
import UIKit

// MARK: - Seasonal ambiance
//
// Core Animation only (render server), like `HeroDrift`: a SwiftUI
// `.repeatForever` ticks on the main thread every frame, which cost the Apple
// TV 4K ~10–12 % CPU on an idle Home (lot 8). Not interactive, hidden from
// VoiceOver, ABSENT (not frozen) when `AmbiancePolicy` says no.

/// Laid over a hero, above its gradient.
struct SeasonalAmbianceOverlay: View {
    @Environment(\.seasonID) private var seasonID
    @Environment(\.motionEffectsEnabled) private var motionEnabled
    @AppStorage(SettingsKey.seasonalAmbiance) private var ambianceEnabled: Bool = SettingsKey.Default.seasonalAmbiance

    var body: some View {
        let effects = AmbiancePolicy.effects(
            theme: SeasonalThemeCatalogue.theme(id: seasonID),
            ambianceEnabled: ambianceEnabled, motionEnabled: motionEnabled
        ).intersection([.mist, .bats])
        if !effects.isEmpty {
            AmbianceRepresentable(effects: effects)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct AmbianceRepresentable: UIViewRepresentable {
    let effects: Set<AmbianceEffect>
    func makeUIView(context: Context) -> AmbianceView { AmbianceView() }
    func updateUIView(_ view: AmbianceView, context: Context) { view.setEffects(effects) }
}

final class AmbianceView: UIView {
    static let mistKey = "cinemax.ambiance.mist"
    static let batKey = "cinemax.ambiance.bat"
    /// Bats cross ONE hero per app session — rare, as the canvas asks.
    static var batsFlownThisSession = false

    private(set) var mistLayers: [CAGradientLayer] = []
    private(set) var batLayers: [CALayer] = []
    private var effects: Set<AmbianceEffect> = []
    private var batsPending = false

    /// Mist blobs, in fractions of the hero: frame, peak opacity, drift, period.
    private static let mist: [(frame: CGRect, opacity: CGFloat, drift: CGFloat, period: CFTimeInterval)] = [
        (CGRect(x: -0.10, y: 0.70, width: 0.80, height: 0.40), 0.14, 0.06, 22),
        (CGRect(x: 0.35, y: 0.76, width: 0.80, height: 0.34), 0.10, -0.05, 26),
        (CGRect(x: 0.05, y: 0.84, width: 1.00, height: 0.32), 0.18, 0.04, 30),
    ]
    private static let mistColor = UIColor(red: 0xCF / 255, green: 0xC3 / 255, blue: 0xE6 / 255, alpha: 1)
    private static let batColor = UIColor(red: 0xB3 / 255, green: 0xA8 / 255, blue: 0xB8 / 255, alpha: 0.75)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setEffects(_ newValue: Set<AmbianceEffect>) {
        guard newValue != effects else { return }
        effects = newValue
        rebuild()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        rebuild()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutMist()
        if batsPending, bounds.width > 0 { launchBats() }
    }

    private func rebuild() {
        mistLayers.forEach { $0.removeFromSuperlayer() }
        mistLayers = []
        batLayers.forEach { $0.removeFromSuperlayer() }
        batLayers = []
        batsPending = false
        guard window != nil else { return }
        if effects.contains(.mist) { addMist() }
        if effects.contains(.bats), !Self.batsFlownThisSession {
            Self.batsFlownThisSession = true
            batsPending = true
            if bounds.width > 0 { launchBats() }
        }
    }

    private func addMist() {
        for blob in Self.mist {
            let l = CAGradientLayer()
            l.type = .radial
            l.colors = [Self.mistColor.withAlphaComponent(blob.opacity).cgColor, Self.mistColor.withAlphaComponent(0).cgColor]
            l.startPoint = CGPoint(x: 0.5, y: 0.5)
            l.endPoint = CGPoint(x: 1, y: 1)
            layer.addSublayer(l)
            mistLayers.append(l)
        }
        layoutMist()
        for (l, blob) in zip(mistLayers, Self.mist) {
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = 0
            a.toValue = max(bounds.width, 1) * blob.drift
            a.duration = blob.period
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.isRemovedOnCompletion = false
            l.add(a, forKey: Self.mistKey)
        }
    }

    private func layoutMist() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, blob) in zip(mistLayers, Self.mist) {
            l.frame = CGRect(x: blob.frame.minX * bounds.width, y: blob.frame.minY * bounds.height,
                             width: blob.frame.width * bounds.width, height: blob.frame.height * bounds.height)
        }
        CATransaction.commit()
    }

    /// The canvas's bat silhouette, 80 × 20 around its origin.
    private static func batPath() -> CGPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: -6, y: -8))
        p.addLine(to: CGPoint(x: -7, y: -3))
        p.addCurve(to: CGPoint(x: -40, y: -6), controlPoint1: CGPoint(x: -14, y: -10), controlPoint2: CGPoint(x: -26, y: -12))
        p.addCurve(to: CGPoint(x: -28, y: 8), controlPoint1: CGPoint(x: -32, y: -4), controlPoint2: CGPoint(x: -28, y: 2))
        p.addCurve(to: CGPoint(x: -10, y: 10), controlPoint1: CGPoint(x: -22, y: 3), controlPoint2: CGPoint(x: -14, y: 4))
        p.addCurve(to: CGPoint(x: 0, y: 6), controlPoint1: CGPoint(x: -8, y: 5), controlPoint2: CGPoint(x: -4, y: 4))
        p.addCurve(to: CGPoint(x: 10, y: 10), controlPoint1: CGPoint(x: 4, y: 4), controlPoint2: CGPoint(x: 8, y: 5))
        p.addCurve(to: CGPoint(x: 28, y: 8), controlPoint1: CGPoint(x: 14, y: 4), controlPoint2: CGPoint(x: 22, y: 3))
        p.addCurve(to: CGPoint(x: 40, y: -6), controlPoint1: CGPoint(x: 28, y: 2), controlPoint2: CGPoint(x: 32, y: -4))
        p.addCurve(to: CGPoint(x: 7, y: -3), controlPoint1: CGPoint(x: 26, y: -12), controlPoint2: CGPoint(x: 14, y: -10))
        p.addLine(to: CGPoint(x: 6, y: -8))
        p.close()
        return p.cgPath
    }

    private func launchBats() {
        batsPending = false
        let w = bounds.width, h = bounds.height
        let flights: [(scale: CGFloat, y: CGFloat, delay: CFTimeInterval, duration: CFTimeInterval)] = [
            (1.0, 0.22, 0.4, 6.5), (0.7, 0.30, 1.6, 7.5), (0.5, 0.16, 2.4, 8.5),
        ]
        for flight in flights {
            let container = CALayer()
            container.position = CGPoint(x: -100, y: -100)   // off-screen between flights
            let shape = CAShapeLayer()
            shape.path = Self.batPath()
            shape.fillColor = Self.batColor.cgColor
            shape.setAffineTransform(CGAffineTransform(scaleX: flight.scale, y: flight.scale))
            container.addSublayer(shape)
            layer.addSublayer(container)
            batLayers.append(container)

            let path = UIBezierPath()
            path.move(to: CGPoint(x: -60, y: h * (flight.y + 0.08)))
            path.addQuadCurve(to: CGPoint(x: w + 60, y: h * flight.y), controlPoint: CGPoint(x: w * 0.5, y: h * (flight.y - 0.1)))
            let fly = CAKeyframeAnimation(keyPath: "position")
            fly.path = path.cgPath
            fly.duration = flight.duration
            fly.beginTime = CACurrentMediaTime() + flight.delay
            fly.fillMode = .backwards
            fly.calculationMode = .paced
            container.add(fly, forKey: Self.batKey)

            let flap = CABasicAnimation(keyPath: "transform.scale.y")
            flap.fromValue = flight.scale
            flap.toValue = flight.scale * 0.55
            flap.duration = 0.16
            flap.autoreverses = true
            flap.repeatCount = .infinity
            shape.add(flap, forKey: Self.batKey)
        }
    }
}

#if os(tvOS)
/// The canvas's « lueur » — a pumpkin halo that flickers slowly behind the
/// focused card. A layer shadow animated by Core Animation.
struct SeasonalFocusGlow: UIViewRepresentable {
    let active: Bool
    let color: Color
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> SeasonalFocusGlowView { SeasonalFocusGlowView() }

    func updateUIView(_ view: SeasonalFocusGlowView, context: Context) {
        view.glowColor = UIColor(color)
        view.cornerRadius = cornerRadius
        view.setGlowing(active)
    }
}

final class SeasonalFocusGlowView: UIView {
    static let animationKey = "cinemax.season.focusGlow"
    var glowColor: UIColor = .clear
    var cornerRadius: CGFloat = 0
    private(set) var isGlowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.shadowOffset = .zero
        layer.shadowRadius = 30
        layer.shadowOpacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setGlowing(_ glowing: Bool) {
        guard glowing != isGlowing else { return }
        isGlowing = glowing
        apply()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        layer.shadowColor = glowColor.resolvedColor(with: traitCollection).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        if isGlowing, window != nil {
            layer.shadowOpacity = 0.35
            if layer.animation(forKey: Self.animationKey) == nil {
                let a = CABasicAnimation(keyPath: "shadowOpacity")
                a.fromValue = 0.35
                a.toValue = 0.75
                a.duration = 1.4
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.isRemovedOnCompletion = false
                layer.add(a, forKey: Self.animationKey)
            }
        } else if !isGlowing {
            layer.removeAnimation(forKey: Self.animationKey)
            layer.shadowOpacity = 0
        }
    }
}
#endif
```

- [ ] **Step 4: Sur les trois héros.** Ajouter `.overlay { SeasonalAmbianceOverlay() }` :
  - `HomeScreen.heroSectionContent` : juste après `.overlay { CinemaGradient.heroOverlay.allowsHitTesting(false) }`.
  - `LibraryHeroSection` : juste après son overlay de dégradé (`grep -n "heroOverlay" Shared/Screens/LibraryHeroSection.swift`).
  - `MediaDetailScreen.backdropSectionContent` : juste après son overlay de dégradé (`grep -n "heroOverlay\|Gradient" Shared/Screens/MediaDetailScreen.swift`).

- [ ] **Step 5: La lueur tvOS.** Dans `CinemaFocusModifier` (`FocusScaleModifier.swift`) :
  1. Propriétés, sous `@Environment(\.motionEffectsEnabled) private var motionEnabled` :
     ```swift
         #if os(tvOS)
         @Environment(\.seasonID) private var seasonID
         @AppStorage(SettingsKey.seasonalAmbiance) private var ambianceEnabled: Bool = SettingsKey.Default.seasonalAmbiance

         private var seasonGlow: Bool {
             AmbiancePolicy.effects(
                 theme: SeasonalThemeCatalogue.theme(id: seasonID),
                 ambianceEnabled: ambianceEnabled, motionEnabled: motionEnabled
             ).contains(.focusGlow)
         }
         #endif
     ```
  2. Dans la branche `#if os(tvOS)` du `body`, en PREMIER modificateur après `content` :
     ```swift
            // Seasonal « lueur » behind the focused card. The closure keeps the
            // content's identity when the season toggles; nothing is created
            // out of season.
            .background {
                if seasonGlow {
                    SeasonalFocusGlow(active: isFocused, color: themeManager.accent, cornerRadius: CinemaRadius.large)
                }
            }
     ```

- [ ] **Step 6: Vérifier.** TESTS iOS puis TESTS tvOS : `✔ Suite "Seasonal ambiance" passed` sur les deux (la lueur n'est testée que sur tvOS). `HeroBackdropDriftTests` toujours vert.

- [ ] **Step 7: Commit.**

```bash
git add Shared/DesignSystem/Seasons/SeasonalAmbiance.swift Shared/DesignSystem/FocusScaleModifier.swift Shared/Screens/HomeScreen.swift Shared/Screens/LibraryHeroSection.swift Shared/Screens/MediaDetailScreen.swift Tests/CinemaxKitTests/SeasonalAmbianceTests.swift Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(saisons): ambiance Core Animation (brume, chauves-souris) et lueur de focus tvOS

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Icône de saison (variante classique + script de bascule)

**Files:**
- Modify: `design/logo-variantes/recolor.py` (`main()`, boucle d'écriture)
- Create: `scripts/seasonal-icon.py`
- Modify: `design/logo-variantes/README.md`

**Interfaces:**
- Produces: `design/logo-variantes/declinaisons/classique/<chemin>` pour chaque fichier de `RECOLOURED` ; `python3 scripts/seasonal-icon.py halloween|classique`.

- [ ] **Step 1: `recolor.py` écrit la variante identité `classique`.** Dans `main()`, juste avant la boucle `# 2. Every variant of every recoloured source`, ajouter :

```python
    # 1b. « classique » — the identity variant (corners filled, original hue),
    # written for EVERY recoloured file: scripts/seasonal-icon.py restores it.
    for rel in RECOLOURED:
        rgb, alpha, _ = sources[rel]
        path = os.path.join(OUT, "classique", rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        to_image(rgb, alpha).save(path, optimize=True)
```

Régénérer et vérifier :

```bash
python3 design/logo-variantes/recolor.py && find design/logo-variantes/declinaisons/classique -name '*.png' | wc -l
```

Attendu : `9` (icône claire, sombre, logo tvOS, 3 faces, 3 fonds).

- [ ] **Step 2: Le script.** Créer `scripts/seasonal-icon.py` :

```python
#!/usr/bin/env python3
"""Pose l'icône d'une saison — ou la classique — comme icône PRINCIPALE de l'app.

    python3 scripts/seasonal-icon.py halloween
    python3 scripts/seasonal-icon.py classique

L'icône principale est celle de l'App Store et de tout le monde : elle change
avec une VERSION, jamais depuis l'app (spec 2026-09-28, §10). Sources :
design/logo-variantes/declinaisons/<variante>/ (produites par recolor.py) ; un
fichier qu'une variante ne change pas vient de la variante « classique ».
L'icône teintée ne change jamais ; app_logo.png reçoit l'icône claire.
"""
import shutil
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Resources/Assets.xcassets"
DECLINAISONS = ROOT / "design/logo-variantes/declinaisons"
VARIANTS = {
    "halloween": "halloween_cloche-citrouille_tentacules-potion",
    "classique": "classique",
}
TV = "App Icon & Top Shelf Image.brandassets"
FILES = [
    "AppIcon.appiconset/app_icon_1024.png",
    "AppIcon.appiconset/app_icon_1024_dark.png",
    "AppLogo.imageset/app_logo_tv.png",
    f"{TV}/App Icon - Large.imagestack/Front.imagestacklayer/Content.imageset/front_appstore.png",
    f"{TV}/App Icon - Small.imagestack/Front.imagestacklayer/Content.imageset/front_1x.png",
    f"{TV}/App Icon - Small.imagestack/Front.imagestacklayer/Content.imageset/front_2x.png",
    f"{TV}/App Icon - Large.imagestack/Back.imagestacklayer/Content.imageset/back_appstore.png",
    f"{TV}/App Icon - Small.imagestack/Back.imagestacklayer/Content.imageset/back_1x.png",
    f"{TV}/App Icon - Small.imagestack/Back.imagestacklayer/Content.imageset/back_2x.png",
]
LOGO = "AppLogo.imageset/app_logo.png"


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in VARIANTS:
        sys.exit(f"usage: seasonal-icon.py {'|'.join(VARIANTS)}")
    folder = DECLINAISONS / VARIANTS[sys.argv[1]]
    for rel in FILES:
        src = folder / rel
        if not src.exists():
            src = DECLINAISONS / "classique" / rel
        dst = ASSETS / rel
        if not src.exists() or not dst.exists():
            sys.exit(f"{rel}: source or target missing ({src})")
        a, b = Image.open(src), Image.open(dst)
        if (a.size, a.mode) != (b.size, b.mode):
            sys.exit(f"{rel}: {a.size} {a.mode} != {b.size} {b.mode}")
        shutil.copyfile(src, dst)
        print(f"{sys.argv[1]:>10}  {rel}")
    shutil.copyfile(ASSETS / FILES[0], ASSETS / LOGO)
    print(f"{sys.argv[1]:>10}  {LOGO}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Vérifier l'aller-retour.**

```bash
python3 scripts/seasonal-icon.py classique && git status --short Resources/
```

Attendu : AUCUN fichier modifié (la variante classique est pixel pour pixel l'icône sans coins déjà installée ; si `git status` montre des PNG, comparer les pixels avant de conclure — seul l'encodage PNG peut différer) :

```bash
python3 - <<'EOF'
import subprocess, io, numpy as np
from PIL import Image
for f in subprocess.check_output(["git","diff","--name-only","Resources/"]).decode().split():
    old = np.asarray(Image.open(io.BytesIO(subprocess.check_output(["git","show",f"HEAD:{f}"]))).convert("RGBA")).astype(int)
    new = np.asarray(Image.open(f).convert("RGBA")).astype(int)
    print(f, "max|Δ|", np.abs(old-new).max())
EOF
```

Attendu : `max|Δ| 0` partout (sinon `git checkout -- Resources/` et investiguer). Puis :

```bash
python3 scripts/seasonal-icon.py halloween
```

Attendu : 10 lignes `halloween …`. Contrôle visuel : ouvrir `Resources/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png` (méduse cloche citrouille, tentacules potion).

- [ ] **Step 4: README.** Dans `design/logo-variantes/README.md`, section « Pour aller plus loin », ajouter :

```markdown
Icône de saison : `python3 scripts/seasonal-icon.py halloween` pose la variante Halloween comme icône principale (App Store compris), `python3 scripts/seasonal-icon.py classique` la retire. Chaque bascule part dans une version.
```

- [ ] **Step 5: Commit.**

```bash
git add design/logo-variantes scripts/seasonal-icon.py Resources/Assets.xcassets
git commit -m "feat(saisons): icône Halloween comme icône principale, script de bascule

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Documentation des règles et version

**Files:**
- Modify: `Shared/DesignSystem/CLAUDE.md`, `Shared/Screens/Settings/CLAUDE.md`, `CLAUDE.md`, `project.yml`

- [ ] **Step 1: RULE dans `Shared/DesignSystem/CLAUDE.md`,** à la fin de la section « Design System » :

```markdown
- **RULE — seasonal themes are DATA (`Shared/DesignSystem/Seasons/`).** A season (`SeasonalTheme`: window, dark palette, optional light palette, accent, title font, ambiance, Home row) is one entry of `SeasonalThemeCatalogue`; adding Christmas adds an entry, never logic. Which season is on is `SeasonalThemePolicy` (pure, tested) held by `SeasonalThemeController` (root singleton, re-evaluated at launch, `.active`, `.NSCalendarDayChanged`, settings). The palette rides `SeasonTrait` on the window SCENE (`SeasonTraitApplier`), bridged to SwiftUI as `\.seasonID`; `Color.dynamic(light:dark:season:)` reads it, so a new `CinemaColor` surface/text token passes its `SeasonToken` or is never repainted. Views read `\.seasonID` (a value — never require the controller object outside Settings), the accent goes through `ThemeManager.setSeasonAccent` (display only, `accentColorKey` untouched, beats rainbow). Ambiance is Core Animation only, absent when `AmbiancePolicy` says no. The icon is NOT runtime: `scripts/seasonal-icon.py` swaps the primary icon in a release. Spec: `docs/superpowers/specs/2026-09-28-seasonal-themes-design.md`.
```

- [ ] **Step 2: Table des clés** dans `Shared/Screens/Settings/CLAUDE.md`, sous la ligne `accentColor` :

```markdown
| `appearance.seasonalTheme` | `"automatic"` | `SeasonalSetting` — **via `SeasonalThemeController.setSetting`**, which re-evaluates the season |
| `appearance.seasonalAmbiance` | `true` | Mist / bats / tvOS focus glow; also off with motion effects or Reduce Motion (`AmbiancePolicy`) |
| `appearance.seasonalRow` | `true` | The season's Home row (« Frissons d'Halloween ») |
| `debug.forcedSeason` | `""` | Debug: force a catalogue season whatever the date |
```

- [ ] **Step 3: Arborescence** dans `CLAUDE.md` racine, bloc « Project Structure », après la ligne `DesignSystem/Components/ …` :

```
  DesignSystem/Seasons/      Seasonal themes — SeasonalTheme (data types), SeasonalThemeCatalogue (DATA: Halloween), SeasonalThemePolicy (+ AmbiancePolicy, SeasonRowMatcher — pure), SeasonTrait (UIKit trait + `\.seasonID` bridge + SeasonalColor), SeasonalThemeController (root singleton), SeasonalTypography (hero / row title face), SeasonalAmbiance (Core Animation mist, bats, tvOS focus glow), SeasonalSettingsText — see the RULE in Shared/DesignSystem/CLAUDE.md
```

- [ ] **Step 4: Version.** `project.yml` : `MARKETING_VERSION: "2.3.0"` (le hook régénère le projet).

- [ ] **Step 5: Commit.**

```bash
git add Shared/DesignSystem/CLAUDE.md Shared/Screens/Settings/CLAUDE.md CLAUDE.md project.yml Cinemax.xcodeproj/project.pbxproj
git commit -m "docs(saisons): RULE, table des clés, arborescence ; version 2.3.0

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Vérification complète et recette

**Files:** aucun (corrections éventuelles dans les fichiers concernés, chacune en son commit).

- [ ] **Step 1: Builds Debug + Release, en série.**

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation 2>&1 | grep -E 'error:|\*\* BUILD'
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -skipPackagePluginValidation 2>&1 | grep -E 'error:|\*\* BUILD'
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -configuration Release -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation 2>&1 | grep -E 'error:|\*\* BUILD'
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -configuration Release -destination 'generic/platform=tvOS Simulator' -skipPackagePluginValidation 2>&1 | grep -E 'error:|\*\* BUILD'
```

Attendu : quatre `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Tests des deux schémas** (commandes TESTS iOS puis TESTS tvOS). Attendu : `✔ Test run with N tests` (N > 0) sur les deux, aucune ligne `✘`, les suites `Seasonal …` présentes, et sur tvOS la suite `tvOS layout metrics`.

- [ ] **Step 3: Contrôles projet.**

```bash
python3 scripts/check-localization-parity.py
python3 scripts/dependency-audit.py check --offline
```

Puis les skills `localize-check` et `design-system-review`, et les agents `tvos-focus-reviewer` (sur `FocusScaleModifier.swift`, `SeasonalAmbiance.swift`, `SettingsScreen+tvOS.swift`) et `swift6-concurrency-reviewer` (sur `Shared/DesignSystem/Seasons/`, `ThemeManager.swift`, `AppNavigation.swift`). Corriger chaque constat retenu dans son propre commit.

- [ ] **Step 4: Recette au simulateur, saison forcée** (Réglages → Debug → « Forcer « Nuit d'Halloween » »). iPhone 17 Pro, iPad, Apple TV 4K ; pour chacun, capture et contrôle :
  - Accueil sombre : fond `#0C0A10`, accent citrouille, titre du héros en Fraunces italique, brume en bas du héros, chauves-souris une seule fois, rangée « Frissons d'Halloween » sous « Reprendre » (si le serveur a un genre Horreur) ;
  - Accueil en mode clair : surfaces claires d'origine, accent `#A84508`, titres Fraunces ;
  - Réglages → Apparence : note d'accent affichée ; décocher « Thème saisonnier » (avec la saison forcée décochée aussi) → retour immédiat à la normale SANS quitter l'écran Réglages ;
  - « Réduire les animations » activé (Réglages système → Accessibilité) → brume, chauves-souris et lueur absentes ;
  - Apple TV : lueur vacillante sur la carte focalisée ; aucune saccade en faisant défiler l'Accueil ;
  - un toast (ex. « Ajouté aux favoris ») et le lecteur vidéo : couleurs de saison cohérentes.

- [ ] **Step 5: Rapport à l'utilisateur.** Résumer : ce qui passe, ce qui a été corrigé, les captures, et demander l'accord avant tout push / PR (règle du plan). Rappeler le calendrier : soumission vers le 10/10 en publication manuelle, publication le 15/10, version 2.3.1 début novembre avec `python3 scripts/seasonal-icon.py classique`.
