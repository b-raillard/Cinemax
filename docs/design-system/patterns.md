# Patterns

Reusable compositions. Each pattern below is a "shape" the app repeats across screens. If you're building something that looks like one of these, use the pattern — don't reinvent it.

| Pattern | When |
| --- | --- |
| [Glass panels](#glass-panels) | Floating a content block over a backdrop |
| [Hero + rows](#hero--rows) | Home, MediaDetail landing |
| [Backdrop with scrim](#backdrop-with-scrim) | Any hero / detail header |
| [Filter chips](#filter-chips) | Library filtering (genre, decade, watch status) |
| [Settings rows](#settings-rows) | Any settings-style list |
| [Toasts vs alerts](#toasts-vs-alerts) | Feedback after an action |
| [Empty / error / loading](#empty--error--loading) | Screens with no content |
| [Navigation](#navigation) | Routing between screens |
| [Sheets](#sheets) | Modal presentation |
| [Pre-auth mobile layout](#pre-auth-mobile-layout) | Server setup, login |

---

## Glass panels

A "glass panel" is a translucent rounded rectangle that sits over a backdrop. Implemented by `GlassPanelModifier`:

```swift
RoundedRectangle(cornerRadius: cornerRadius)
    .fill(.ultraThinMaterial)
    .overlay(
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(CinemaColor.surfaceVariant.opacity(0.6))
    )
```

### Usage

```swift
VStack { … }
    .padding(spacing4)
    .glassPanel()                         // default radius .extraLarge (24)
    .glassPanel(cornerRadius: .large)     // tighter for smaller surfaces
```

### When to use

- Login / server-setup form panels over an ambient backdrop.
- Video-player overlay cards ("Still watching?", "You finished {series}").
- Search / filter sheets.

### When not to use

- Already inside a list / settings area — rows read as glass already via tonal surfaces.
- On a flat `surface` page with no backdrop — the material effect is invisible against solid grey.

---

## Hero + rows

The signature Cinemax layout: one full-bleed editorial hero at the top, followed by horizontally-scrolling `ContentRow`s.

### Structure

```text
LazyVStack(alignment: .leading) {                 // ← LazyVStack, not VStack
    HeroSection(item: heroItem)                   // 2:3 poster left, details right (tvOS)
                                                   // full-bleed backdrop (iOS)
    ContentRow("Reprendre", data: resumeItems)
    ContentRow("Récemment ajoutés", data: latestItems)
    ForEach(genreRows) { row in
        ContentRow(row.name, data: row.items)
    }
    ContentRow("En ce moment", data: activeSessions)
}
```

### Rules

- **Hero is never gated** by user settings. The rows below it are toggleable via `home.showContinueWatching`, `home.showRecentlyAdded`, `home.showGenreRows`, `home.showWatchingNow`.
- **Every hero-adjacent image must use `CinemaLazyImage` with `.frame(maxWidth: .infinity, maxHeight: .infinity)`** when nested in a `ZStack` — otherwise the image takes its natural 1920-px size and pushes the title VStack off-screen.
- **tvOS landing screens wrap in `ScrollViewReader` + zero-height `.id("home.top")` sentinel** and call `proxy.scrollTo("home.top", anchor: .top)` on `.onAppear` so the top tab bar resurfaces after deep navigation. Same pattern in `MovieLibraryScreen`, `SearchScreen`, and Settings tvOS landing.

---

## Backdrop with scrim

Backdrops are full-bleed. Text over them needs a gradient scrim so it stays legible regardless of the image.

```swift
ZStack(alignment: .bottomLeading) {
    CinemaLazyImage(url: ImageURLBuilder.backdropURL(
        itemID: item.backdropItemID,
        width: ImageURLBuilder.screenPixelWidth      // never hardcode 1920
    ))
    .frame(maxWidth: .infinity, maxHeight: .infinity)

    LinearGradient(colors: [.clear, .black.opacity(0.85)],
                   startPoint: .top, endPoint: .bottom)

    VStack(alignment: .leading, spacing: spacing2) {
        Text(item.name).font(CinemaFont.display(.medium))
        Text(item.taglineOrYear).font(CinemaFont.label(.medium))
    }
    .padding(spacing4)
}
.frame(height: AdaptiveLayout.heroHeight(for: form))
.clipped()
```

- `ImageURLBuilder.screenPixelWidth` adapts to the device — never pass `1920` literally.
- Fallback to `item.backdropItemID` (→ `parentBackdropItemID ?? seriesID ?? id`) via `BaseItemDto+Metadata`.
- The pre-baked `CinemaGradient.heroOverlay` covers the common case (fade to surface bottom).

---

## Filter chips

Multi-select chip clusters (genre, decade) and single-select pills (sort, watch-status) share the same visual language:

```text
● Selected          ○ Deselected
[ Drama     ]       [  Action  ]
accentContainer     surfaceContainerHigh
onAccent text       onSurface text
```

### Rules

- Capsule shape (`CinemaRadius.full`).
- `FlowLayout(spacing: 8)` for multi-line chip clusters.
- tvOS uses `TVFilterChipButtonStyle(accent: themeManager.accent)` — stroke on focus, no scale.
- iOS uses a plain `Button` with a selected/deselected background swap and light haptic on toggle.
- **Don't use `SegmentedControl` / `Picker(.segmented)`** — the chrome fights the glass language.

---

## Settings rows

See [components.md § Settings row kit](./components.md#settings-row-kit). In short:

1. Declare rows once as `[SettingsToggleRow]` on the screen.
2. Render with `iOSToggleRowsJoined(...)` (iOS) or `tvToggleList(...)` (tvOS).
3. Non-toggle rows:
   - Navigation: `navigationRow(icon:label:action:)` on iOS, `tvActionRow(…, showsChevron: true)` on tvOS.
   - One-shot action (refresh, clear cache): `tvActionRow(…)` / iOS builds an inline row with `Button`.

Settings layout has **two levels** on both platforms:

- **Landing** — one-page category list (Appearance, Account, Server, Interface).
- **Detail pages** — category-specific content, pushed via `NavigationStack` (iOS) or conditionally rendered (tvOS `selectedCategory`).

tvOS detail pages must handle the Menu button:

```swift
.onExitCommand { selectedCategory = nil }
```

---

## Toasts vs alerts

A simple two-rule model:

| Situation | Use |
| --- | --- |
| Action succeeded, informational, recoverable error | `ToastCenter.success/.info/.error` |
| User must make a decision (confirm destructive action, enter password), playback error on tvOS | `UIAlertController` |

### Toasts

```swift
toasts.success("Paramètres enregistrés")
toasts.error("Connexion impossible", message: "Vérifie l'URL du serveur")
toasts.info("Catalogue actualisé")
```

- Single active toast at a time — a new one replaces the current.
- Top-anchored glass pill. Spring enter/exit. Dismissible with the close button.
- Default durations: success/info 2.5 s, error 4.0 s. Override with `duration:`.
- Mount `ToastOverlay()` once at the app root (already in `AppNavigation`).

### Alerts

- tvOS: always `UIAlertController` via `present(_:animated:)`. SwiftUI `.alert` has focus bugs inside `TabView`.
- iOS: SwiftUI `.alert` is fine for simple confirm/cancel; `UIAlertController` when stacking inside an active playback session (see `showPlaybackErrorAlert`).

---

## Empty / error / loading

Every remote-backed screen must handle four states. Use the four components, in this order of preference:

| State | Component |
| --- | --- |
| Loading | `LoadingStateView` |
| Loaded, non-empty | the screen's normal content |
| Loaded, empty | `EmptyStateView(…)` — with a Clear Filters action if filtered |
| Failed | `ErrorStateView(message:, retryTitle:, onRetry:)` |

Inline row-level errors (e.g. one genre row failed on Home) don't use `ErrorStateView` — render a small retry capsule inline and keep the rest of the screen functional. See `HomeViewModel.retryGenre`.

---

## Navigation

- **Pre-auth**: `AppNavigation` drives the whole flow. Keychain check → `ServerSetupScreen` → `LoginScreen` → `MainTabView`. It also injects `ThemeManager`, `LocalizationManager`, `ToastCenter`, applies `.preferredColorScheme`, and sets `.dynamicTypeSize(.xSmall ... .accessibility2)`.
- **Post-auth shell**: `MainTabView` — top tabs on tvOS, sidebar on iPad (`NavigationSplitView`), bottom tabs on iPhone.
- **Push transitions**:
  - tvOS — nothing special; system handles.
  - iOS — `NavigationStack` + `navigationDestination(item:)`. See the iOS caveat in CLAUDE.md about destinations needing to be standalone `View` structs to observe `@Environment` objects.
- **Disconnecting the server**: `AppState.disconnectServer()` clears keychain URL + flips `hasServer = false`, returning the user to `ServerSetupScreen`. Surfaced as the "Change server" link on the login screen.

---

## Sheets

- Use SwiftUI `.sheet(item:)` on iOS. Good enough for discovery sheets, user-switch, server-discovery.
- On tvOS sheets, apply the same "one focusable unit per row" rule — system sheet chrome is fine, but settings-kit rows inside must be `tvSettingsFocusable(colorScheme:)`.
- Video player is the one exception — always UIKit modal (`UIViewController.present(…)`), never SwiftUI modal. See CLAUDE.md § Video Playback.

---

## Pre-auth mobile layout

ServerSetup and Login share a mobile template so users experience the two as one journey:

```text
┌───────────────────────────────────┐
│        ┌────────┐                 │
│        │  ICON  │                 │  rounded surfaceContainerHigh rect,
│        └────────┘                 │  accent-tinted SF Symbol, shadow
│                                   │  — this is also the rainbow easter-egg tap target
│       TRACKED · SMALL             │  label(.small), tracking(1.2)
│                                   │
│       Big Black Title             │  display(.medium) or headline(.large)
│                                   │
│   Centered subtitle (280 pt max)  │  dynamicBody, onSurfaceVariant
│                                   │
│   ┌───────────────────────────┐   │
│   │    Glass form panel       │   │  .glassPanel(), maxWidth: 350
│   │    GlassTextField         │   │
│   │    …                      │   │
│   └───────────────────────────┘   │
│                                   │
│   [     PRIMARY BUTTON        ]   │  CinemaButton(style: .primary),
│                                   │  maxWidth: 350
│      Helper link (bottom)         │
└───────────────────────────────────┘
```

Known gotcha (iOS 26): `.padding(.horizontal, spacing4)` around the login form panel is silently dropped. Workaround in `LoginScreen.mobileLayout`: `.frame(maxWidth: 350)` on both the form panel and the actions `VStack`, letting the outer `VStack` center them. Don't "fix" this back to padding without verifying with pixel sampling.
