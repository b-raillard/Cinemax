# Interface animations — nine state changes that stop being instant (2026-11-14)

Decided with the product owner on 2026-11-14 from an interactive page of ten proposals, each with a before/after demo: « Animations JellyGlass », https://claude.ai/artifact/311HFECLXQ5cUC7TxMkrVS. His choices are stored in that page's database (collection `decisions`, one document per id below). File references were taken on `main` at `2cb95b15` (2.6.0).

Nothing is built yet. This document is the brief for the builder.

## Why

The app's motion is uneven. Apple TV focus, toasts, the Home hero crossfade, the card → fiche zoom, skeleton shimmer and the Halloween ambiance are carefully animated. Almost everything else on iPhone and iPad changes state in one frame.

Measured in the code on 2026-11-14 (`Shared/`, `iOS/`, `tvOS/`):

| Pattern | Occurrences |
|---|---|
| `.animation(` | 41, most of them tvOS focus |
| `withAnimation` | 14 |
| `.transition(` | 5 |
| `symbolEffect` | 1 (the search microphone) |
| `contentTransition` | 0 |
| `scrollTransition` | 0 |

The owner wants the interface to feel finished on iPhone and iPad without becoming busy. He accepted nine proposals and dropped one.

## Decisions (product owner)

| Id | Proposal | Decision |
|---|---|---|
| `coeur` | Favourite heart and « Vu » check react to the tap | Do |
| `affiches` | Posters fade in when the image arrives | Do |
| `squelette` | Home content replaces the skeleton smoothly | Do |
| `chiffres` | Numbers change smoothly | Do, **variant A**: the digits that change slide upward. Variants B (blur to sharp) and C (count through) were shown and not chosen. |
| `progression` | Progress bar fills | Do |
| `parallaxe` | Fiche backdrop follows the scroll | Do |
| `rangee` | Edge posters of a row recede | Do |
| `saisons` | Changing season slides the episodes | Do |
| `lecteur` | Player: play/pause morphs, « Passer l'intro » slides | Do |
| `vide` | Empty-state illustrations breathe | **Dropped. Do not build.** |

The demos on the page are the visual reference for timing and amplitude. They are HTML approximations: match the feel, not the pixels.

## Goals, non-goals, anti-goals

**Goals**
- Each of the nine state changes is animated as demoed, on the platforms listed for it.
- Every animation is off when Motion Effects is off or the system's Reduce Motion is on, and the screen then behaves exactly as today.
- No measurable loss of scroll smoothness (see *Measurement gates*).

**Non-goals**
- No change to tvOS focus. There are exactly two focus levels (`CinemaTVFocus`); none of this adds a third.
- No new animation on empty states, on the tab bar, in context menus (system menus close before anything could play), or anywhere not listed here.
- No rework of screens for the sake of animating them. If a site needs restructuring to animate, say so and leave it out.
- No third-party animation library.

**Anti-goals** (failures even if it "works")
- Motion that delays input: nothing may block a tap, a focus move or a scroll while it plays.
- An animation that replays on every re-render or every time a lazy cell is recycled.
- A stutter while scrolling a large grid on Apple TV or iPhone.
- Any new defensive state machine in the player. If the player part cannot be done as a small, local change, stop and report.

## Constraints already in the project

Read `Shared/DesignSystem/CLAUDE.md` and `docs/design-system/motion.md` first; for the player, `Shared/Screens/VideoPlayer/CLAUDE.md`; for the fiche, `docs/rules/media-detail.md`; for Home, `docs/rules/home.md`; for the library, `docs/rules/media-library.md`.

- **Motion gate.** SwiftUI views read `@Environment(\.motionEffectsEnabled)` and pass `nil` as the animation when it is false (never a zero-duration animation). UIKit code with no environment uses `MotionEffects.isEnabledNow`. Never read the raw `@AppStorage` key.
- **`AppNavigation.body` is at the type-checker's limit**: one more modifier there broke the CI Release build once. Nothing in this work needs to touch it. If something seems to, attach it to an existing handler instead.
- **Never nest a large lazy grid in a `LazyVStack`**, never `ForEach` over an index snapshot, and `navigationDestination(item:)` stays outside lazy containers. Animating must not reintroduce any of these.
- **`@Observable` properties carry no `didSet`/`willSet`.**
- **A new file under `Shared/` needs `xcodegen generate`**, and a new test file too. Prefer adding to existing files where that is natural.
- **tvOS heroes drift, they do not rotate**; leave `HeroBackdropImage` alone.
- **Haptics** stay as they are (`Haptics` enum; the fiche buttons already use `.sensoryFeedback(.selection, …)`).
- `docs/design-system/motion.md` cites a `CinemaMotion.standard` token that **does not exist in the code** (checked by grep). See *Shared foundation*.

## Approaches

1. **Local modifiers at each site, timings from one small token set** (chosen). Each animation is a few lines in the component or screen that owns the state, gated by the motion flag, with durations and curves read from shared constants. It matches how the 41 existing animations are written, keeps each change reviewable on its own, and lets any one be removed without touching the others.
2. **A generic animation layer** (wrappers such as an "animated state" container or a transition coordinator). Rejected: nine unrelated state changes do not share enough behaviour to justify an abstraction, and the project's own feedback favours the smallest change that fixes the cause.
3. **A library (Lottie or similar).** Rejected: every dependency must be reviewed, pinned and credited, the app's download size already grew from 26.8 MB to 65.8 MB, and nothing here needs designer-authored animation.

The owner handed over the how; approach 1 is my call.

## Shared foundation

Add a `CinemaMotion` enum in `Shared/DesignSystem/` (the doc already names it) holding the timings used below, so that no site carries a literal. Suggested values, to be tuned on device against the demos:

| Token | Value | Used by |
|---|---|---|
| `symbolPop` | bounce, about 0.45 s | `coeur` |
| `imageFade` | 0.3 s ease-out | `affiches` |
| `contentReveal` | 0.45 s, 0.08 s stagger | `squelette` |
| `numeric` | 0.35 s | `chiffres` |
| `progressFill` | 0.7 s ease-out | `progression` |
| `listSwap` | 0.15 s out, 0.34 s in | `saisons` |
| `overlaySlide` | 0.3 s in, 0.2 s out | `lecteur` |

A helper that returns `nil` when motion is off (`CinemaMotion.gated(_:enabled:)` or similar) is welcome if it shortens call sites. Update `docs/design-system/motion.md` (duration table, the `CinemaMotion` mention) and add the rule for new animations to `Shared/DesignSystem/CLAUDE.md`, not to the root `CLAUDE.md`.

## The nine animations

### 1. `coeur` — favourite and watched icons react (iPhone, iPad, Apple TV)

**Today.** The SF Symbol swaps from outline to filled in one frame.
- iOS: `MediaDetailScreen.secondaryActionCell(systemImage:active:accessibility:trigger:action:)`. It already receives a `trigger` Bool used for the haptic.
- tvOS: `TVAccessoryActionButton` in `MediaDetailButtonStyles.swift` (`isActive`).

**Wanted.** On toggle, the symbol is replaced with a symbol transition and bounces once, as in the demo. Colour change to the accent stays.

**Notes.**
- Applies to the favourite and watched buttons. Other cells of the same rows (playlist, Watch Together, « Lire sur… ») keep their current behaviour unless the same modifier costs nothing and looks right; if you extend it, say so.
- The view model flips the flag optimistically; the animation follows the flag, so a server failure that flips it back animates back. That is acceptable.
- On tvOS the button already scales on focus and press through `CinemaTVButtonStyle`. The bounce is on the glyph only and must not add a second scale to the button.
- Context menus on posters are out of scope.

### 2. `affiches` — images fade in (iPhone, iPad, Apple TV)

**Today.** `CinemaLazyImage` (`Shared/DesignSystem/Components/CinemaLazyImage.swift`) wraps NukeUI's `LazyImage` and switches from the fallback background to the image with no transition. Every card, still and backdrop goes through it.

**Wanted.** A 0.3 s fade when an image arrives from the network or the disk cache.

**Requirements.**
- **No fade on a memory-cache hit.** An image that is already decoded must appear immediately, or scrolling back through a grid would shimmer. Check how Nuke 13.2.0's `LazyImage` exposes transitions and whether it skips them for memory-cache hits; do not assume.
- The fallback and loading states keep their current look.
- Give `CinemaLazyImage` an opt-out (for example `fadesIn: Bool = true`) and turn it off wherever a fade would fight another animation: at least the Home hero crossfade and the card → fiche zoom destination. Review the call sites.
- **Measurement gate applies** (see below). If the gate fails on Apple TV, ship the fade on iOS only, or drop it, and report the numbers.

### 3. `squelette` — content replaces the skeleton smoothly (iPhone, iPad, Apple TV)

**Today.** `HomeScreen.body` chooses between `loadingSkeleton` (`MediaPageSkeleton`) and `content` with a plain `if`, so the swap is instant. `MovieLibraryScreen` uses the same skeleton (line 788).

**Wanted.** The skeleton fades out; the hero, then the rows, fade in and rise a few points, about 80 ms apart, as in the demo.

**Notes.**
- Scope: Home and the library screens. Other skeleton users (`MediaDetailSimilarSection`, `MissingTitlesRow`, `RequestsSettingsScreen`) are out.
- The reveal plays **each time the skeleton leaves**, and only then. Today `HomeViewModel.load()` sets `isLoading = true` unconditionally (line 415) and both `.refreshable` and `performFullReload` go through `reload`, so a pull-to-refresh really does put the skeleton back; the content that follows is revealed the same way as on first load. Do not change when the skeleton is shown. *(My call: one rule, no "already revealed" state.)*
- It must **not** play when content changes in place: a later row arriving, a targeted refresh that never shows the skeleton, returning to the tab.
- Cold start: the disk snapshot replaces the skeleton first, then phase 1 replaces the snapshot. Reveal on the snapshot only; phase 1 replacing it is silent. *(My call.)*
- `reload()` sets `activeSessions = []` as its first statement (the index-snapshot crash rule); read `docs/rules/home.md` before touching the branch.
- The error and empty branches of the same `if` may simply crossfade.
- tvOS: the reveal must not move or delay default focus. If a transition on the content makes focus land late or on the wrong element, keep the fade and drop the rise on tvOS.
- Stagger only the first screenful (hero plus the first two or three rows). Rows further down are lazy and must appear as today.

### 4. `chiffres` — numbers roll, variant A (iPhone, iPad, Apple TV)

**Today.** A number that changes in place is replaced in one frame.

**Wanted.** Only the digits that change slide vertically; the rest of the label does not move. In SwiftUI this is a numeric-text content transition animated on the value.

**Sites.** The demo showed three examples; one of them, a search result counter, **does not exist in the app** (no such label in `SearchScreen`). Apply the transition where a number really changes while its label stays on screen:
- library title count: `MovieLibraryScreen` lines 578 and 848 (changes when a filter is applied);
- remaining time on the fiche (`MediaDetailScreen` line 1401), on episode lines (`MediaDetailEpisodeMetadataLine`) and on Home resume cards (`HomeScreen` line 1540), which change when returning from the player;
- the next-episode countdown in the player, `NextUpCountdownView.countdownLabel`. This one is a `UILabel` updated once per second: a short push-from-bottom transition on the label, gated by `MotionEffects.isEnabledNow`. It belongs with the player work (item 9), not with the SwiftUI sites;
- any other in-place counter you find that fits the same description. List what you added.

**Notes.** Strings come from `loc.counted` / `loc.remainingTime` and stay that way; the transition is applied to the `Text`. Do not animate a number on first appearance, only on change.

### 5. `progression` — the progress bar fills (iPhone, iPad, Apple TV)

**Today.** `ProgressBarView` (`Shared/DesignSystem/Components/ProgressBarView.swift`) draws the accent capsule at its final width.

**Wanted.** The bar animates to a new value when `progress` changes (for example on return from the player), and fills from zero when it first appears where that is cheap.

**Requirements.**
- Animate on **value change** everywhere.
- Fill **on appear** only where few bars are on screen: `WideCard` (the « Reprendre » row) and the fiche's own bar (`MediaDetailScreen` lines 2408 and 2411). Episode rows and episode cards (`MediaDetailEpisodeRow`, `MediaDetailEpisodeCard`) and the poster overlay (`mediaCardStatusOverlay`, `ProgressBarView.swift` line 148, drawn on library and search posters) animate on change only, so a long list or a grid does not refill bar after bar while scrolling. A parameter such as `fillsOnAppear: Bool = false` expresses this.
- Because the poster overlay puts a bar in every grid cell, the value-change animation must cost nothing while the value is constant (an implicit animation keyed on `progress`, no per-cell state).
- A lazy cell that is recycled must not replay the fill each time it comes back on screen if that is visible when scrolling a row back and forth. If it cannot be avoided cheaply, keep value-change only and report.
- **Measurement gate applies** to the « Reprendre » row and to a library grid whose posters carry bars.

### 6. `parallaxe` — the fiche backdrop follows the scroll (iPhone, iPad only)

**Today.** `MediaDetailScreen.detailContent` is a `ScrollView` over a `LazyVStack` whose first element is `backdropSection`. I found no scroll-linked effect in the file (grep for scroll transitions, geometry-driven offsets and animations; the screen was not run). The navigation bar is `.inline` and I found no `navigationTitle` in the file, so it appears to show no title.

**Wanted.**
- The backdrop image scrolls slower than the content (about 45 % of the scroll distance in the demo).
- The hero title or logo fades out as it leaves.
- Once the hero title is gone, the item's name appears in the navigation bar, and disappears again when scrolling back.

**Requirements.**
- Drive the parallax with a geometry-based visual effect on the backdrop, not with a `@State` updated on every scroll frame: the screen is about 2 500 lines and must not re-render at scroll rate. The bar title may be one Bool that flips when a threshold is crossed.
- Keep the hero's existing sizing (`containerRelativeFrame` clamp, `onGeometryChange` logo measurement) and the gradient exactly as they are. The backdrop must still cover its box at every scroll offset: no gap at the top, nothing showing through at the bottom.
- iPad two-column layout: same effect on the backdrop; check it in Split View and Stage Manager sizes.
- The card → fiche zoom must still land correctly.
- tvOS: unchanged. Focus drives scrolling there.
- With motion off: no parallax, no fade, and the bar title simply shows or hides without animation (or stays as today; choose the simpler and say which).

### 7. `rangee` — edge posters of a row recede (iPhone, iPad only)

**Today.** `ContentRow` (`Shared/DesignSystem/Components/ContentRow.swift`) is a horizontal `ScrollView` over a `LazyHStack`; all cards are the same size and opacity up to the screen edge.

**Wanted.** Cards entering or leaving at the leading and trailing edges shrink slightly and fade, as in the demo (down to about 0.88 scale and 0.5 opacity at the very edge there). The owner asked for it to stay discreet: start from the demo values and reduce them if it draws the eye on device.

**Requirements.**
- A scroll transition on each item, in the iOS branch only. tvOS rows are untouched.
- `ContentRow` serves more than posters. Make the effect a parameter of the row, **on for media-card rows** (posters and wide cards: Home rails, genre rows, similar titles, the person page) and **off for the rest** (cast circles, Seerr missing-title rows, « En direct »). *(My call, from the demo, which showed a poster row. List the rows you turned on.)*
- The first card of a row at rest must be at full size and opacity (the leading inset must not leave it permanently receded).
- Long-press context menus, the zoom transition source, and the progress/watched overlays on cards must be unaffected.
- **Measurement gate applies.** This is the most visible change and the riskiest for smoothness; if the gate fails, drop it and report.

### 8. `saisons` — changing season slides the episodes (iPhone, iPad, Apple TV)

**Today.** `MediaDetailViewModel.selectSeason` sets `selectedSeasonId` immediately, then replaces `episodes` when the request returns (a generation counter discards stale answers; on error the previous episodes stay). The list is rendered from `MediaDetailEpisodeSlot.interleave(owned:missing:)` around `MediaDetailScreen` line 2000 and swaps in one frame.

**Wanted.** The old episodes fade and slide out, the new ones slide in, as in the demo.

**Requirements.**
- The animation is tied to **the new episodes arriving**, not to the tap: between the tap and the answer the old list stays (as today).
- Keep it simple: animating the list as one block is enough. A per-row stagger is welcome only for the first few visible rows and only if it needs no extra state.
- Rapid season changes must not queue animations; the last one wins.
- A refresh of the same season (returning from the player, marking watched) must **not** play the slide.
- The Seerr missing-episode slots are part of the same list and move with it.
- tvOS: focus stays on the season chip during the swap; the incoming list must not take focus. iPad's horizontal episode layout gets the same treatment.

### 9. `lecteur` — player: play/pause (iPhone, iPad) and « Passer l'intro » (iPhone, iPad, Apple TV)

**Today** (`Shared/Screens/VideoPlayer/VLCStreamPresenter.swift`, UIKit, over 5 000 lines):
- `setPlayPauseIcon(playing:)` (line 5249) replaces the HUD button's configuration image in one frame, including in the iPhone Duo tabletop layout. The button is **iOS-only** (`playPauseButton` is declared under `#if os(iOS)`, line 395): Apple TV has no HUD play/pause glyph, only the centre flash.
- The centre glyph that flashes on toggle (`flashCenterGlyph`) is **already animated**. Leave it.
- `skipButton.isHidden` is set directly at several places, so the button appears and disappears instantly: setup, reset on item load, `skipSegmentTapped` (line 1689), and inside `updateSkipButton` the invalid-time guard, the auto-skip hide (line 1573), the hand-over to the next-episode card (line 1603) and the normal enter/leave of a segment.
- The native engine's `SkipSegmentController` and `NextUpCountdownView` already fade in and out.

**Wanted.**
- iPhone and iPad: the HUD play/pause glyph changes with a short symbol replace or crossfade instead of a cut. **Apple TV gets nothing new here** *(my call: adding a HUD glyph there would be a larger player change than this work allows)*.
- « Passer l'intro » / « Passer le générique » slides in from the trailing side while fading in, and leaves the same way.
- The next-episode countdown number rolls (item 4).

**Requirements.**
- Keep `UIButton.Configuration`; never `UIButton(type:)` setters.
- Route skip-button visibility through **one** small function (`visible`, `animated`). Animated: entering a segment, leaving it, and the hide after the user presses the button. Instant: setup, reset on item load, invalid time, auto-skip, and the hand-over to the next-episode card (that card has its own fade). *(My call for the last three.)* At the end of a hide the button is really hidden, so the tvOS focus engine never lands on an invisible control, and a hide that interrupts a show (or the reverse) ends in the right state.
- Gate with `MotionEffects.isEnabledNow`.
- Do not split the presenter, do not add controllers, do not touch seek, stall or recovery code.
- The native-engine skip button may get the same slide for consistency if it is a few lines; otherwise leave it.
- **Own pull request, last, with a device check** on iPhone and Apple TV (HUD auto-hide, focus on the skip button on tvOS, tabletop mode on the Duo simulator with the 27.1 SDK). No playback on the owner's personal account during checks: use the demo devices.

## Measurement gates

The owner's rule is to measure before keeping anything that touches every cell. For `affiches`, `progression` (« Reprendre » row) and `rangee`:

1. Record scroll smoothness before and after on the same device, same screen, same content, three runs each: a large library grid and the Home rows, on an iPhone and on an Apple TV (physical if available; say which).
2. Use Instruments' animation hitches, or the frame counters you can obtain, and report the numbers.
3. **Abandon threshold (my call, the owner may change it):** if hitch time or dropped frames get worse by more than 10 %, or any stutter is visible to the eye on Apple TV, scope the effect down (iOS only, fewer sites) or drop it. Report what was dropped and why rather than tuning indefinitely.

## Delivery

Four pull requests, in this order, each releasable on its own:

| PR | Content | Risk |
|---|---|---|
| 1 | `CinemaMotion` + `coeur` + `chiffres` (SwiftUI sites) + `progression` | Low |
| 2 | `affiches` + `squelette` | Medium (per-cell, loading states) |
| 3 | `parallaxe` + `rangee` + `saisons` | Medium (fiche and rows) |
| 4 | `lecteur` (+ the countdown number); Apple TV: skip button and countdown only | High (player) |

For each PR:
- iOS and tvOS build and the full test suites pass (never `-only-testing`; see the root `CLAUDE.md` build rules).
- Any pure decision gets a unit test in an existing test file: for example the parallax offset or bar-title threshold if written as a pure function, the "fill on appear or not" choice, the "is this a season change or a refresh" test. `MotionEffectsTests` shows the existing pattern for the motion flag.
- Each animation is checked with Motion Effects off and with the system's Reduce Motion on: the screen behaves as before the change.
- VoiceOver labels and traits are unchanged.
- Both themes and the Halloween theme are looked at once.
- The area rule files and `docs/design-system/motion.md` are updated in the same PR (the `gh pr create` hook asks for it).
- Merges are manual; no auto-merge.

## Left to the builder

- Exact curves, durations and amplitudes, within the feel of the demos.
- The SwiftUI and UIKit APIs used for each effect.
- Whether `CinemaMotion` lives in an existing design-system file or a new one.
- Which extra numeric labels and which `CinemaLazyImage` call sites opt in or out, with the list reported.

## Owner answers (2026-11-14)

- The design and the four calls marked *(my call)* are approved, the 10 % abandon threshold included.
- **No announcement**: no « Quoi de neuf » page for these animations.
- The version they ship in is decided later; none of these PRs bumps `MARKETING_VERSION`.

## Not verified when this was written

- The fiche was read by grep, not run: the absence of scroll-linked effects and of a navigation title is inferred from the source.
- No performance measurement exists yet for any of the three gated items.
- NukeUI's transition API and its behaviour on memory-cache hits were not checked.
- Line numbers are from `2cb95b15` and will drift.
