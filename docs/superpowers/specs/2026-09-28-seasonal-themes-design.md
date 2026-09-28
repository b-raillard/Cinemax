# Thèmes saisonniers : le socle, et Halloween en premier

Date : 2026-09-28. Statut : design validé en discussion, spec à relire.
Maquette de référence : « Cinemax — Logo & Halloween » (canevas claude.ai), artboards *Thème*, *iPhone — Accueil*, *iPhone — Réglages › Apparence*, *Apple TV — Accueil*. Variantes de l'icône : `design/logo-variantes/`.

## 1. Intention

L'app prend l'ambiance d'une période de l'année, puis revient d'elle-même à la normale. Halloween 2026 est la première saison. Le socle doit servir telle quelle à Noël et aux suivantes : **ajouter une saison = écrire une entrée de catalogue**, sans nouvelle logique.

Critères de réussite :
- du 15 octobre au 2 novembre, sans rien toucher, l'app est en « Nuit d'Halloween » sur iOS et tvOS : palette, accent, titres, ambiance, rangée « Frissons d'Halloween » ;
- l'icône de l'App Store et de l'app installée est la méduse Halloween (A : cloche citrouille, tentacules potion) pendant la saison ;
- le 3 novembre, l'app revient à la palette et à l'accent de chacun, sans mise à jour ;
- on peut tout couper (Apparence), et l'ambiance respecte « Réduire les animations ».

## 2. Décisions prises

| Sujet | Décision |
|---|---|
| Périmètre | Palette + réglage + titres Fraunces + ambiance + rangée de saison + icône. **Livrés ensemble**, une version (2.3.0). |
| Généricité | Saison = donnée (`SeasonalTheme`) dans un catalogue ; Halloween est l'unique entrée pour l'instant. |
| Mode clair | Chaque saison déclare si elle a une palette claire. Halloween n'en a pas : en mode clair, seuls l'accent, les titres, l'ambiance et la rangée changent. |
| Réglage | **Automatique** (défaut) / **Désactivé**. Pas de « Toujours » ; une saison forcée existe dans la page Debug, pour la recette. |
| Accent | L'accent de saison remplace l'accent AFFICHÉ, jamais l'accent enregistré, qui revient à la fin de la saison. |
| Icône | Icône **principale** du binaire, donc celle de l'App Store et de tout le monde. Pas d'icône alternative ni de choix utilisateur pour l'instant. Changement par version (script), indépendant du réglage. |
| Hors périmètre | Widget, Top Shelf (processus séparés), écran de lancement (rendu avant tout code Swift), héros « Sélection d'Halloween » (le héros de l'Accueil ne change pas), icônes alternatives, icônes d'accent. |

## 3. Modèle

### 3.1 `SeasonalTheme` (valeur pure, `Sendable`)

```swift
struct SeasonalTheme: Sendable, Equatable, Identifiable {
    let id: String                     // "halloween"
    let nameKey: String                // "season.halloween.name" → « Nuit d'Halloween »
    let window: SeasonWindow           // 15/10 → 2/11
    let dark: SeasonPalette            // surfaces + textes, mode sombre
    let light: SeasonPalette?          // nil = la saison ne touche pas aux surfaces en clair
    let accent: AccentOption.Palette   // même forme que les accents existants
    let titleFont: SeasonFont?         // Fraunces Black Italic
    let ambiance: Set<AmbianceEffect>  // [.mist, .bats, .focusGlow]
    let row: SeasonRow?                // « Frissons d'Halloween »
}

struct SeasonWindow: Sendable, Equatable {
    let start: MonthDay                // inclus, 00:00 heure locale
    let end: MonthDay                  // inclus, jusqu'à 23:59:59 heure locale
    // start > end ⇒ la période chevauche le Nouvel An (cas Noël)
}
```

`SeasonPalette` couvre toutes les familles de surfaces et de textes de `CinemaColor` (surface, containerLowest…Highest, surfaceVariant, onSurface, onSurfaceVariant, onSurfaceMuted, outline, outlineVariant). Les tokens que la saison ne définit pas gardent leur valeur (`error`, `success`…).

### 3.2 Halloween

| Token | Valeur | Source |
|---|---|---|
| surface | `#0C0A10` Nuit | maquette |
| surfaceContainerLow | `#15111C` Crypte | maquette |
| surfaceContainer | `#1D1726` Caveau | maquette |
| surfaceContainerHigh | `#262033` Tombe | maquette |
| surfaceContainerHighest, surfaceVariant | `#2E2740` | dérivé |
| surfaceContainerLowest | `#07060A` | dérivé |
| onSurface | `#F1E9E0` Parchemin | maquette (16,4:1 sur Nuit) |
| onSurfaceVariant | `#B3A8B8` Cendre | maquette (8,6:1) |
| onSurfaceMuted | `#9A90A2` | dérivé (≥ 5,1:1 sur toutes les surfaces) |
| outline / outlineVariant | `#7A6F84` / `#4A4058` | dérivés de Cendre (traits seulement, jamais du texte) |
| accentDark | `#FF7A1A` Citrouille | maquette (7,5:1 sur Nuit) |
| accentLight | `#A84508` | dérivé (5,6:1 sur la surface claire) |
| onAccentDark | `#1A0D05` | maquette (7,3:1 sur Citrouille) |
| containerLight / containerDark | `#E06A1A` / `#E06A1A` | alignés sur l'accent Orange |
| dimLight / dimDark | `#8A3806` / `#CC5500` | alignés sur l'accent Orange |
| onAccentLight | `#FFFFFF` | comme tous les accents |
| accent 2 (Potion) | `#A57BFF` | réservé à l'ambiance ; pas un token d'interface |

Fenêtre : 15 octobre → 2 novembre. Rangée : titre « Frissons d'Halloween » / « Halloween Chills », genres candidats `Horror`, `Horreur`, `Épouvante-horreur`, `Épouvante`.

### 3.3 `SeasonalThemeCatalogue`

Un tableau statique de `SeasonalTheme`, comme `WhatsNewCatalogue` : DONNÉES, pas code. Invariant testé : les fenêtres de deux saisons ne se chevauchent pas.

## 4. Activation

### 4.1 `SeasonalThemePolicy` (pure, testée)

`activeTheme(on date: Date, calendar: Calendar, setting: SeasonalSetting, forcedID: String?, catalogue: [SeasonalTheme]) -> SeasonalTheme?`

- `forcedID` non vide (Debug) → cette saison, quels que soient la date et le réglage.
- `setting == .off` → `nil`.
- `.automatic` → la saison dont la fenêtre contient `date` dans le calendrier et le fuseau passés, sinon `nil`.

### 4.2 `SeasonalThemeController` (`@MainActor @Observable`)

Singleton racine, ajouté à l'ensemble des « singleton root stores » d'`AppNavigation`. Il tient `activeTheme` et le réévalue :
- au lancement ;
- au retour au premier plan (`scenePhase == .active`) ;
- au changement de jour (`.NSCalendarDayChanged`) ;
- au changement du réglage ou de la saison forcée.

Pas de `didSet` (RULE `@Observable`) : `reevaluate()` calcule, puis n'assigne que si la valeur change, et pousse la saison vers ses consommateurs (§5, §6).

## 5. Palette dans toute l'app

**Mécanisme visé.** Un trait UIKit personnalisé `SeasonTrait: UITraitDefinition` (valeur : l'identifiant de la saison, ou `nil`), posé par le contrôleur sur la scène (`UIWindowScene.traitOverrides`). `Color.dynamic(light:dark:)` reçoit un troisième paramètre, `season: KeyPath<SeasonPalette, UInt>?`, que chaque token de `CinemaColor` couvert par la palette passe (`\.surface`, `\.onSurface`…). Le fournisseur `UIColor { traits in … }` lit `traits[SeasonTrait.self]` avant `userInterfaceStyle` :

```
saison active ET (mode sombre OU saison.light != nil) → valeur de la palette de saison
sinon → light / dark actuels
```

Les ~800 appels `CinemaColor.*` ne changent pas. La fenêtre des toasts (`ToastWindow`, même scène) et le lecteur UIKit suivent aussi.

**Prototype jetable, en premier.** Vérifier sur iOS 26 ET tvOS 26 qu'un changement de trait sur la scène redessine les couleurs SwiftUI (`Color(uiColor:)`) sans relancer l'app. Si ça ne passe pas, un pont `UITraitBridgedEnvironmentKey` est le second essai.

**Repli si le trait n'atteint pas SwiftUI.** La palette active est lue dans une valeur globale (`nonisolated(unsafe) static`, écrite uniquement par le contrôleur sur le main actor), et la racine de l'app porte `.id(activeTheme?.id)`, ce qui reconstruit l'arbre. Acceptable : ça n'arrive qu'aux déclencheurs du §4.2. Point à surveiller si on en arrive là : l'état de navigation est perdu à la bascule ; il faut alors garder la bascule pour le lancement ou le retour au premier plan, jamais au milieu d'une session.

**Accent.** `ThemeManager` expose `setSeasonAccent(_ palette: AccentOption.Palette?)`. Le getter `palette` renvoie l'accent de saison s'il est présent, sinon l'accent enregistré. `accentColorKey` et le sélecteur d'accent ne changent pas. Pendant la saison, le sélecteur d'accent d'Apparence affiche une note : « Pendant la Nuit d'Halloween, l'accent citrouille remplace le vôtre. »

## 6. Titres de saison

- Police : **Fraunces Black Italic**, instance statique (pas la police variable), licence OFL. Fichier dans `Resources/Fonts/`, déclaré via `UIAppFonts` dans `project.yml` pour `Cinemax` et `CinemaxTV` (plus `xcodegen generate`), crédité dans `LicensesView`, et `scripts/dependency-audit.py` vérifié (la police n'est pas un paquet SwiftPM).
- `CinemaFont.seasonalDisplay(_ size: DisplaySize, theme: SeasonalTheme?) -> Font` : `Font.custom(postScriptName, size: CinemaScale.pt(…))` si la saison a une police, sinon `CinemaFont.display(size)` exact. Taille via `CinemaScale.pt`, donc aucun effet Dynamic Type (ces surfaces portent déjà `.layoutBoundDynamicType()`).
- Appliqué à : titre du héros de l'Accueil, `LibraryHeroSection`, titre de `MediaDetailScreen.backdropSection`, sur iOS et tvOS ; titre de la rangée de saison. Nulle part ailleurs.
- Un titre de héros qui est un LOGO (image) reste une image.

## 7. Ambiance

- `AmbianceEffect` : `.mist`, `.bats`, `.focusGlow` (Noël ajoutera ses cas, `.snow` par exemple).
- *(Révisé le 2026-09-28 après essai sur iPhone : l'ambiance couvre TOUTE l'app connectée, un seul calque posé à la racine ; la brume devient une fumée qui monte — émetteur de particules ; dix chauves-souris en boucle et des citrouilles qui tombent, le tout dès l'ouverture — on lance un film en 20 à 30 s et le lecteur n'en montre rien.)*
- `SeasonalAmbianceLayer` : un calque unique posé sur les trois héros, `allowsHitTesting(false)`, `accessibilityHidden(true)`, animé par Core Animation (même approche que la dérive de `HeroBackdropImage` sur tvOS), sans travail SwiftUI par image.
  - Brume : deux ou trois ellipses floues couleur `#CFC3E6` (8–18 % d'opacité), qui dérivent lentement en bas du héros.
  - Chauves-souris : deux ou trois silhouettes vectorielles (tracé de la maquette), qui traversent une fois, au premier affichage du héros dans la session.
- Lueur (`.focusGlow`, tvOS seulement) : un halo Citrouille qui vacille lentement autour de l'élément focalisé, greffé sur `FocusScaleModifier`. Relu par `tvos-focus-reviewer`.
- Coupée si l'une de ces conditions est vraie : l'interrupteur « Animations d'ambiance » est éteint, les effets de mouvement de l'app sont désactivés, ou « Réduire les animations » est actif (même lecture que `\.motionEffectsEnabled`). Coupée = absente, pas figée.

## 8. Rangée de saison

- `SeasonRow` : `titleKey` et `genreCandidates: [String]`. Noël aura besoin de tags ; ce cas s'ajoutera avec Noël.
- Correspondance pure et testée, `SeasonRowMatcher.match(candidates:, in serverGenres:) -> String?` : comparaison insensible à la casse et aux accents (`folding(options: [.caseInsensitive, .diacriticInsensitive], locale:)`), premier candidat trouvé.
- `HomeViewModel` réutilise la liste de genres déjà chargée par `loadGenreRows`, puis la requête des rangées de genre. État propre (`seasonRow`), affiché juste après « Reprendre ». Absente si aucun genre ne correspond, si le résultat est vide, si l'interrupteur est éteint, ou hors saison. Un échec réseau n'affiche pas de puce « Réessayer » : la rangée est décorative, elle disparaît.
- Rechargée quand la saison change (§4.2), avec le même principe de génération que `reloadGenreRows`.

## 9. Réglages

Apparence (iOS : `SettingsAppearanceView+iOS` ; tvOS : la section Apparence de `SettingsScreen+tvOS`), une section « Thème saisonnier » :
- sélecteur **Automatique / Désactivé** ; sous-titre calculé depuis le catalogue et formaté avec `loc.locale` (« Nuit d'Halloween, du 15 octobre au 2 novembre ») ;
- « Animations d'ambiance » (activé par défaut) ;
- « Rangée de saison » (activé par défaut) ;
- page Debug : « Forcer une saison » (Aucune / Halloween).

Clés `@AppStorage` (à ajouter à la table de `Shared/Screens/Settings/CLAUDE.md`) : `appearance.seasonalTheme` (`"automatic"` | `"off"`), `appearance.seasonalAmbiance` (Bool, true), `appearance.seasonalRow` (Bool, true), `debug.forcedSeason` (String, `""`). Les bascules passent par des mutateurs explicites et des `Binding(get:set:)` (RULE `@Observable`).

Chaînes FR/EN via `loc.localized` : nom de chaque saison, titre de sa rangée, libellés et sous-titres de la section, note sur l'accent, libellés Debug. Parité vérifiée par `localize-check` et la CI.

## 10. Icône de saison (processus de version, pas de code app)

- `scripts/seasonal-icon.py <halloween|classique>` recopie, depuis `design/logo-variantes/declinaisons/<variante>/` (Halloween = `halloween_cloche-citrouille_tentacules-potion`), l'icône iOS claire et sombre, les faces des piles tvOS et `app_logo_tv.png` dans `Resources/Assets.xcassets/`. `app_logo.png` reçoit l'icône claire. « classique » recopie `design/logo-variantes/declinaisons/classique/`, variante identité (coins remplis, teinte d'origine) que `recolor.py` produira désormais comme les autres. La version teintée ne change pas.
- Le script vérifie que chaque fichier cible existe et a la même taille et le même mode d'image que la source.

## 11. Tests (swift-testing, schémas `Cinemax` et `CinemaxTV`)

- `SeasonalThemePolicy` : veille, premier jour, dernier jour 23:59, lendemain ; fuseau de Paris et fuseau de Tokyo ; période qui chevauche le Nouvel An (saison de test) ; `.off` ; saison forcée hors fenêtre.
- Catalogue : pas de chevauchement ; clés FR/EN présentes ; contraste ≥ 4,5:1 de `onSurface`, `onSurfaceVariant`, `onSurfaceMuted` et de l'accent sur chaque surface de chaque palette de saison ; `onAccent` ≥ 4,5:1 sur l'accent.
- `SeasonRowMatcher` : casse, accents, plusieurs candidats (ordre), aucun trouvé.
- `ThemeManager` : l'accent de saison remplace l'accent affiché, l'accent enregistré est intact, le retrait de la saison le restitue (`UserDefaults.isolatedForTesting()`).
- Palette : résolution d'un token `CinemaColor` avec et sans `SeasonTrait`, en clair et en sombre, pour une saison avec et sans palette claire.

Avant tout push : builds Debug et Release des deux applis, tests des deux schémas (lecture de la ligne `✔ Test run with N tests`), `localize-check`, `design-system-review`, agents `tvos-focus-reviewer` et `swift6-concurrency-reviewer`, recette au simulateur avec la saison forcée (iPhone, iPad, Apple TV ; clair et sombre ; « Réduire les animations »).

## 12. Mise en production

1. PR de `design/logo-variantes` vers `main` (icônes carrées, déclinaisons, cette spec).
2. Branche du thème depuis `main`, en trois lots de commits : socle + palette + réglages ; titres ; ambiance + rangée. Puis l'icône Halloween posée par le script. Une seule PR.
3. `MARKETING_VERSION` 2.3.0. Soumission vers le **10 octobre** en **publication manuelle** dans App Store Connect, publication déclenchée le **15 octobre**, pour que l'icône n'arrive pas avant la saison.
4. Début novembre : version 2.3.1, qui remet l'icône classique avec le script.

## 13. Risques

| Risque | Parade |
|---|---|
| Le trait de scène n'atteint pas les couleurs SwiftUI | Prototype en premier ; repli `.id(saison)` décrit au §5. |
| Contraste d'un écran qui utilise un token non couvert par la palette de saison | Test de contraste du catalogue ; recette en saison forcée sur chaque onglet et le lecteur. |
| Chauves-souris ou brume trop voyantes ou coûteuses sur Apple TV | Core Animation uniquement ; trois éléments au plus ; coupées par les réglages. |
| Genre « Horreur » absent ou nommé autrement sur un serveur | La rangée disparaît simplement ; les candidats sont une donnée facile à étendre. |
| Revue App Store plus longue que prévu | Soumettre le 10/10 laisse cinq jours ; la palette s'active par date même si l'icône arrive en retard. |

## 14. Ouvert (hors de cette spec)

- Une page « Quoi de neuf » pour la 2.3.0 : à décider à la release.
- Noël : palette (avec version claire ?), rangée par tag, effet neige. Écrit comme une nouvelle entrée de catalogue plus ses nouveaux cas.
- Donner à l'utilisateur le choix de l'icône (icônes alternatives) : plus tard.
