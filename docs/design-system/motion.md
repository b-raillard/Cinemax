# Motion & Focus

How animations and focus indicators behave, and how the app honors the user's motion preference.

---

## The motion-effects flag

Users can disable every animation in the app via **Settings → Interface → Motion Effects**. Backed by `@AppStorage(SettingsKey.motionEffects)` (default `true`). Plumbed through a SwiftUI environment key:

```swift
// Shared/DesignSystem/FocusScaleModifier.swift
private struct MotionEffectsEnabledKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var motionEffectsEnabled: Bool { ... }
}
```

Set once at the app root:

```swift
// AppNavigation
.environment(\.motionEffectsEnabled, motionEffects)   // from @AppStorage
```

### Using it in your own view

Every `.animation()` call must consult this flag:

```swift
@Environment(\.motionEffectsEnabled) private var motionEnabled

// Then:
.animation(motionEnabled ? .easeInOut(duration: 0.2) : nil, value: someState)
```

The `nil` branch is the contract — SwiftUI interprets `nil` as "apply the state change instantly without animation." Don't use `.animation(motionEnabled ? .foo : .linear(duration: 0))` — it still animates, just with an invisible duration, and compounding zero-duration animations through multiple views can cause visible jank.

### Components that already honor it

You don't need to do anything if you use:

- `CinemaFocusModifier` (`.cinemaFocus()`)
- `CinemaTVButtonStyle`, `CinemaTVCardButtonStyle`, `TVFilterChipButtonStyle`
- `CinemaToggleIndicator` (takes an explicit `animated` parameter passed at call site)
- `ToastOverlay`

New components must consume `\.motionEffectsEnabled` or take an explicit `animated: Bool` parameter.

---

## Animation durations

Where they appear in the codebase, for consistency:

| Use | Duration | Curve |
| --- | --- | --- |
| Focus in/out (tvOS + iPad hover) | 0.2 s | `.easeInOut` |
| Button press down (tvOS) | 0.1 s | `.easeInOut` |
| Toggle indicator slide | 0.15 s | `.easeInOut` |
| tvOS settings-row focus border | 0.15 s | `.easeOut` |
| Toast enter/exit | spring | default spring |
| Rainbow easter egg tick | 33 ms (30 fps) | linear (hue increment) |
| `CinemaMotion.standard` | 0.3 s | used when "standard" feels right |

Don't invent new durations unless you have a specific reason. Match what's next to you on the screen.

---

## Focus

The focus model differs by platform. Every interactive surface must declare its focus behaviour — silent `Button`s on tvOS are unreachable.

### iOS & iPad

Apply `.cinemaFocus()` to any tappable card or row:

```swift
SomeCard()
    .cinemaFocus()
```

What it does:

- **iPhone**: no-op (no hover).
- **iPad** (pointer): `.hoverEffect(motionEnabled ? .lift : .highlight)`. Pointer over the card gently scales + shadows when motion is on; when off, just dims.
- **tvOS**: adds a 2 pt accent `strokeBorder` with radius `.large`, and a `surfaceTint` shadow. Both gated on `isFocused`. No scale — scale is applied by the button style, not the focus modifier.

**Do not compose `.cinemaFocus()` with a scale-applying button style on the same view** — the scale comes from one place, the ring from the other, and doubling either produces a wobble.

### tvOS focus recipes

| Surface | Apply |
| --- | --- |
| Primary action button | `Button { } label: { … }.buttonStyle(CinemaTVButtonStyle(cinemaStyle: .primary))` — handled by `CinemaButton(style: .primary)` |
| Accent button | `CinemaButton(style: .accent)` |
| Ghost button | `CinemaButton(style: .ghost)` |
| Filter chip (single-select capsule) | `.buttonStyle(TVFilterChipButtonStyle(accent: themeManager.accent))` |
| Poster / Wide card | `Button { … } label: { Card() }.buttonStyle(CinemaTVCardButtonStyle())` + `.cinemaFocus()` on inner card |
| Settings row | `Button { … } label: { … }.tvSettingsFocusable(isFocused:, accent:, colorScheme: themeManager.darkModeEnabled ? .dark : .light)` |
| Settings row with focus-state binding | use `@FocusState` + `tvSettingsFocusable` |

Baseline tvOS button behaviour (`CinemaTVButtonStyle`):

- `scaleEffect(1.05)` when focused, `0.95` when pressed
- Shadow matching the button style (primary → primary color, ghost → surfaceTint, accent → accentContainer)
- Focus animation 0.2 s, press animation 0.1 s
- All gated on `motionEnabled`

### tvOS focus rules (non-negotiable)

From CLAUDE.md, repeated here because they are easy to break:

1. **One focusable unit per row.** A settings row must be one `Button` — never a row with three individually focusable sub-controls. Multi-state rows (accent picker, language row) use `onMoveCommand` to cycle values inside the one focusable unit.
2. **No individually-focusable nested items.** Same reason — Siri Remote swipes get confused.
3. **`.focusEffectDisabled()` is REQUIRED, not a hack — it is how Cinemax draws its own indicator.** This rule used to read "no `.focusEffectDisabled()` hacks", which contradicted both the app (~25 call sites) and the focus model documented in [platforms.md](./platforms.md#focus-model): the app suppresses the system halo precisely so the accent ring or stroke is the only thing on screen. Pair it with `.hoverEffectDisabled()` at every call site. What IS still a hack, and still banned: reaching for it to paper over focus that lands somewhere wrong. If focus goes to the wrong control, the layout or the focus sections are wrong.
4. **Use `.tvSettingsFocusable(colorScheme:)` for settings-row-shaped surfaces.** It forces the correct colour scheme so `Color.dynamic` tokens don't flip to light-mode values inside focused buttons. Always pass `themeManager.darkModeEnabled ? .dark : .light`.
5. **Back button** on detail settings uses `.focused($focusedItem, equals: .back)` and renders highlighted with `themeManager.accent`.

### The "focus inside AVPlayerViewController" special case

**Scope: the opt-in native engine only.** Online playback defaults to `VLCStreamPresenter`, a plain `UIViewController` that draws its own focusable HUD, cards and overlays and overrides `preferredFocusEnvironments` freely. What follows applies when the user has turned on Settings → Playback → "Use native player".

`AVPlayerViewController` locks the focus environment on tvOS while playback is on-screen. Custom overlay views with their own `preferredFocusEnvironments` **cannot** become focusable. The only approved mechanism for in-player affordances is:

- **tvOS**: `AVPlayerViewController.contextualActions = [UIAction(…)]` — appears as a small button above the transport bar.
- **iOS**: floating `UIButton` added to `AVPlayerViewController.view` (no focus needed on touch).

See the Skip Intro / Skip Credits implementation in `NativeVideoPresenter.swift`.

---

## Pressed / hover / selected states

Across both platforms:

| State | Visual |
| --- | --- |
| Hover (iPad pointer) | `.hoverEffect(.lift)` — subtle scale + shadow |
| Hover, motion off | `.hoverEffect(.highlight)` — dim only |
| Pressed (tvOS) | `scaleEffect(0.95)` for buttons, `0.97` for card-style buttons |
| Pressed (iOS) | Default SwiftUI press darkening (plain button style) |
| Focused (tvOS) | `scaleEffect(1.05)` + style-specific shadow + accent stroke (when via `.cinemaFocus()`) |
| Selected (chip) | `accentContainer` fill + `onAccent` label text. Deselected chips use `surfaceContainerHigh` fill. |

---

## Progress, loading, transitions

- **Loading**: always `LoadingStateView` (spinner, scaled 1.5×). Don't build ad-hoc `ProgressView()` screens.
- **Empty**: `EmptyStateView` with a 56 pt semi-transparent SF Symbol, title (headline), optional subtitle, optional 200 pt ghost action button.
- **Error**: `ErrorStateView` with 48 pt `exclamationmark.triangle` in `CinemaColor.error`, message, 160 pt ghost retry button.
- **Transient feedback**: `toasts.success(…)` / `.error(…)` / `.info(…)` — see [patterns.md § Toasts vs alerts](./patterns.md#toasts-vs-alerts).

---

## What to avoid

- Custom `@State private var isAnimating` toggles that aren't wired to `motionEnabled`.
- `withAnimation { }` blocks without checking the flag — use `withAnimation(motionEnabled ? .default : nil) { }`.
- tvOS: white-background focus indicators; a third focus treatment beside the two in `CinemaTVFocus`; overriding `preferredFocusEnvironments` inside `AVPlayerViewController` (the opt-in native path, where its focus environment is locked). The default VLC presenter is a plain `UIViewController` and DOES override it — that is how its HUD, its next-episode countdown and its end-of-series card take focus.
- iOS: SwiftUI modal presentation for the video player — corrupts `TabView` focus on dismiss. Always present the player view controller via UIKit (`UIViewController.present(…)`), whichever engine it hosts.
