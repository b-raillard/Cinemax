# Visual & interaction consistency + responsive/edge-case

**Run the existing skills first — don't duplicate them.** Two skills already own big slices of this domain; this file covers only what they *don't*.

1. `design-system-review` → tokens, colors, toggles, borders, Liquid-Glass nesting, `CinemaLazyImage`, `.font(.system(...))`, backdrop `1920`. Run it, fold its findings in under **Visual Consistency**.
2. `localize-check` → FR/EN key parity + hardcoded strings. Run it, fold in under **Copy consistency**.

Then do the passes below, which are about *behavioral* and *responsive* consistency the grep-based skills miss.

## 1. Component behavior consistency (identical-looking, different-behaving)

Read for pairs of components that *look* the same but behave differently, or behave the same but are implemented twice.

- **Play affordances**: RULE says every play button is `PlayLink<Label>` (Button+coordinator tvOS / `NavigationLink` iOS) — flag any direct `NavigationLink` to `VideoPlayerView`. Two play buttons that route differently is the exact bug the RULE prevents.
  ```bash
  grep -rn --include='*.swift' 'NavigationLink' Shared | grep -i 'VideoPlayer'
  ```
- **Toggles**: one shared `CinemaToggleIndicator` everywhere except the *explicitly mandated* native `Toggle`/`Picker`/`Stepper` in `MenuSettingsScreen+iOS` (RULE — user-requested native chrome). Any *other* system `Toggle` is an inconsistency.
- **Buttons**: `CinemaButton` styles have assigned meanings — `.accent` = primary CTA, `.primary` = neutral (only `DestructiveConfirmSheet`), `.ghost` = secondary. Flag a Retry/Clear that uses `.accent`, or a primary CTA using `.ghost` — same-looking control, wrong semantic weight.
- **Destructive confirmations**: irreversible → `DestructiveConfirmSheet` (type-to-confirm); reversible → `.confirmationDialog` `.destructive` (RULE). Flag a delete that uses a plain alert or no confirm.

## 2. Interaction-state coverage

For each interactive component, verify the full state set is defined and consistent: **hover (iOS pointer/iPad), focus (tvOS), active/pressed, selected, disabled, loading, success, warning, destructive, error**. The common gaps:

- **Disabled state**: does a CTA visibly disable while its op runs (cross-ref `concurrency.md §1`), or just stop responding? A control that looks enabled but no-ops is both a UX and a race issue.
- **Loading state on the control itself** (spinner in the button), not only a full-screen overlay.
- **Pressed/focus feedback** consistent across tvOS cards (`CinemaTVCardButtonStyle`) vs settings rows (`.tvSettingsFocusable`) vs filter chips (`TVFilterChipButtonStyle`) — the documented "no press scale on wide rows" nuance.

## 3. Responsive & viewport

- **iPad split view / Stage Manager** is supported (`UIRequiresFullScreen` removed — RULE). Full-bleed heroes clamp height via `containerRelativeFrame(.vertical) { min(fixed, length * 0.55…0.62) }` (iOS only) so a short window keeps content-below reachable. Verify every new full-bleed hero follows it; flag a fixed-height hero on iOS that would eat a split-view window.
  ```bash
  grep -rn --include='*.swift' 'containerRelativeFrame\|heroSection\|backdropSection\|LibraryHeroSection' Shared/Screens
  ```
- **Compact vs regular width** (iPhone bottom tabs / iPad sidebar / tvOS top tabs) — the `MainTabView` split. The 5-tab cap (RULE — `UIMoreNavigationController`) is the load-bearing constraint; verify it holds across width classes.
- **Breakpoints via `horizontalSizeClass` / `#if os(tvOS)`** — flag hardcoded widths that assume iPhone portrait.

## 4. Edge-case content

Test each list/detail/card against hostile content — the server supplies these and they *will* occur:

- **Long titles / names** — movie titles, series names, usernames, email in account screens. Verify truncation (`.lineLimit` + `.truncationMode`) is intentional and consistent, not clipping mid-glyph or pushing layout. `PosterCard` uses a hidden 2-line placeholder for uniform height (RULE) — verify siblings do too.
- **Empty / nil metadata** — no year, no overview, no backdrop (`hasBackdropImage` → `BackdropFallbackView`, RULE — gate on `hasBackdropImage`, not `backdropItemID` which is always non-nil), no runtime, no rating.
- **Very large datasets** — a 5000-item library grid (LazyVGrid perf, jump-bar `> 20` gate), a long activity log (50/page infinite scroll), many downloads.
- **Zero-result states** — search with no hits, filtered library empty, no episodes, offline with no downloads.
- **Expanded/translated text** — FR is ~15-20% longer than EN; verify buttons/labels don't clip when the FR string is longer (cross-ref `localize-check`).

## 5. Copy & format consistency

- **Terminology drift** — same concept, different words across screens (e.g. "Lecture" vs "Lire" vs "Reprendre"; "Bibliothèque" vs "Médiathèque"). `localize-check` finds *missing* keys; it does NOT find *inconsistent* wording — read the `.strings` files for drift.
- **Capitalization / punctuation** — title case vs sentence case in buttons/headers; trailing periods on some toasts not others.
- **Date / number / size formats** — file sizes ("Zéro ko" regression history), durations (`PlayerTimeFormat` HH:MM:SS SSOT — verify no ad-hoc time formatting elsewhere), dates (`premiereDate` formatting), counts.
  ```bash
  grep -rn --include='*.swift' 'DateFormatter\|ByteCountFormatter\|String(format:\|.formatted(' Shared | head -30
  ```

## Severity guidance

- **High**: a play/destructive control that behaves inconsistently with its twin (wrong route / no confirm); a hero that eats a split-view window making content unreachable.
- **Medium**: missing disabled/loading state on a CTA; long-title clipping that hides meaning; terminology drift on primary actions.
- **Low/Info**: spacing/token nits (defer to `design-system-review`), punctuation/capitalization drift, cosmetic truncation.
