# Interface Animations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nine state changes stop being instant on iPhone, iPad and Apple TV, each gated by the motion flag, delivered as four stacked PRs.

**Architecture:** Local modifiers at each site. Timings come from one new `CinemaMotion` enum, and the scroll, reveal and skip decisions sit in small pure functions that are unit-tested. No new view-model state except one swap counter on `MediaDetailViewModel`.

**Tech Stack:** SwiftUI (iOS 26 / tvOS 26), UIKit (player), NukeUI 13 (`LazyImage(transaction:)`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-11-14-interface-animations-design.md`

## Global Constraints

- Every SwiftUI animation reads `@Environment(\.motionEffectsEnabled)` and passes `nil` when it is false. UIKit uses `MotionEffects.isEnabledNow`. Never the raw `@AppStorage` key.
- No new modifier on `AppNavigation.body`.
- No `didSet`/`willSet` on `@Observable` properties. No `ForEach` over index snapshots. The outer stack is never a `LazyVStack` holding a large grid.
- A new file under `Shared/` or `Tests/` → `xcodegen generate` before building. Prefer existing files.
- tvOS focus is untouched: no third focus level, no extra scale on focused buttons.
- `UIButton.Configuration` only.
- No `MARKETING_VERSION` bump, no « Quoi de neuf » page.
- Each PR: iOS and tvOS build, full iOS and tvOS test suites (never `-only-testing`), SwiftLint clean, `docs/design-system/motion.md` and the area `CLAUDE.md` updated in the same PR.
- Merges are manual. PR n+1 is based on PR n's branch.

## Review Focus

1. **Motion off.** With Motion Effects off or Reduce Motion on, every changed screen behaves exactly as before. Covered by the `gated` test (Task 1) and a manual pass per PR.
2. **Memory-cache images.** A poster already in memory must appear with no fade when scrolling back. NukeUI's synchronous memory-cache path bypasses the transaction (`FetchImage.load`, checked in the 12.9 source; re-check in 13.2.3). Manual check in Task 4.
3. **Lazy rows re-created by scrolling.** These must not replay the Home reveal. `ContentReveal.shouldAnimate` test (Task 5).
4. **Season refresh vs. season change.** Returning from the player on the same season must not slide the list. `MediaDetailViewModelTests` test (Task 8).
5. **Skip-button state after an interrupted animation.** A hide that interrupts a show ends hidden, and the tvOS focus engine never reaches an invisible button. `SkipButtonPresentation` test plus the `isHidden` in the completion (Task 9).

---

## PR 1 — `claude/interface-animations`

### Task 1: `CinemaMotion` tokens, heart and watched pop, rolling numbers

**Files:**
- Modify: `Shared/DesignSystem/FocusScaleModifier.swift` (add `CinemaMotion` next to `MotionEffects`)
- Modify: `Shared/Screens/MediaDetailScreen.swift` (`secondaryActionCell`, remaining-time `Text` at ~1401)
- Modify: `Shared/Screens/MediaDetailButtonStyles.swift` (`TVAccessoryActionButton`)
- Modify: `Shared/Screens/MovieLibraryScreen.swift` (~578, ~848), `Shared/Screens/MediaDetailEpisodeMetadataLine.swift`, `Shared/Screens/HomeScreen.swift` (~1540)
- Test: `Tests/CinemaxKitTests/MotionEffectsTests.swift`

**Interfaces:**
- Produces: `enum CinemaMotion` with `static let symbolPop`, `imageFade`, `contentReveal`, `revealStagger: Double = 0.08`, `numeric`, `progressFill`, `listSwap`, `overlaySlide: TimeInterval = 0.3`, `overlaySlideOut: TimeInterval = 0.2`; and `nonisolated static func gated(_ animation: Animation, enabled: Bool) -> Animation?`.

- [ ] **Step 1: Write the failing test** in `MotionEffectsTests.swift`: `@Test func gatedReturnsNilWhenMotionIsOff()` asserts `CinemaMotion.gated(.default, enabled: false) == nil` and `CinemaMotion.gated(.default, enabled: true) == .default`.
- [ ] **Step 2: Build the tests.** Expected: compile error, `CinemaMotion` not found.
- [ ] **Step 3: Implement `CinemaMotion`.** Values: `symbolPop` = `.bouncy(duration: 0.45)`, `imageFade` = `.easeOut(duration: 0.3)`, `contentReveal` = `.easeOut(duration: 0.45)`, `numeric` = `.snappy(duration: 0.35)`, `progressFill` = `.easeOut(duration: 0.7)`, `listSwap` = `.easeOut(duration: 0.34)`.
- [ ] **Step 4: Heart and watched.**
  - iOS `secondaryActionCell`: on the `Image`, add `.contentTransition(.symbolEffect(.replace))` and `.symbolEffect(.bounce, value: trigger)`, both only when motion is on. Add `.animation(CinemaMotion.gated(CinemaMotion.symbolPop, enabled: motion), value: trigger)`.
  - The cell is used by more than the favourite and watched buttons. Apply the bounce only when a new `pops: Bool = false` parameter is true, and pass `true` from those two buttons.
  - tvOS `TVAccessoryActionButton`: the same on its `Image`, keyed on `isActive`, behind a new `pops: Bool = false` parameter, passed `true` by the favourite and watched buttons.
- [ ] **Step 5: Rolling numbers.**
  - Add `.contentTransition(.numericText())` and `.animation(CinemaMotion.gated(CinemaMotion.numeric, enabled: motion), value: <the number>)` to the library title count `Text`s and to the remaining-time `Text`s (fiche, episode metadata line, Home resume card).
  - Key each animation on the number itself, not the string, so a language change does not roll.
  - List the sites you touched in the PR body.
- [ ] **Step 6: Run the full iOS test suite.** Expected: `MotionEffectsTests` passes and `✔ Test run with N tests` has N > 0.
- [ ] **Step 7: Commit** `feat(motion): CinemaMotion tokens, favourite/watched pop, rolling numbers`.

### Task 2: Progress bar fill

**Files:**
- Modify: `Shared/DesignSystem/Components/ProgressBarView.swift`
- Modify: `Shared/DesignSystem/Components/WideCard.swift:40`, `Shared/Screens/MediaDetailScreen.swift:2408,2411` (pass `fillsOnAppear: true`)
- Test: `Tests/CinemaxKitTests/MediaCardStatusTests.swift`

**Interfaces:**
- Consumes: `CinemaMotion.progressFill`, `CinemaMotion.gated`.
- Produces: `ProgressBarView(progress:height:trackColor:fillsOnAppear: Bool = false)`, and the pure `nonisolated static func displayedFraction(progress: Double, fillsOnAppear: Bool, hasAppeared: Bool) -> Double`.

- [ ] **Step 1: Write the failing test** `@Test func progressBarFillsFromZeroOnlyWhenAsked()`:
  - `displayedFraction(progress: 0.7, fillsOnAppear: true, hasAppeared: false) == 0`
  - `displayedFraction(progress: 0.7, fillsOnAppear: true, hasAppeared: true) == 0.7`
  - `displayedFraction(progress: 0.7, fillsOnAppear: false, hasAppeared: false) == 0.7`
  - `displayedFraction(progress: 1.4, fillsOnAppear: false, hasAppeared: true) == 1`
- [ ] **Step 2: Build the tests.** Expected: compile error.
- [ ] **Step 3: Implement.**
  - Add a `@State hasAppeared` that flips to true in `.onAppear`, only when `fillsOnAppear` is set.
  - Animate width with `.animation(CinemaMotion.gated(.progressFill, enabled: motion), value: displayedFraction(...))`.
  - When `fillsOnAppear` is false, there is no `@State` write, so grid cells (`mediaCardStatusOverlay`) pay nothing until the value changes.
- [ ] **Step 4: Run the full iOS test suite.** Expected: passes.
- [ ] **Step 5: Measure.**
  - Measure the « Reprendre » row and a library grid with posters showing progress bars, on the iPhone simulator, before and after. Use the Animation Hitches instrument with `xctrace`, or note that it was unavailable.
  - Spec threshold: more than 10 % worse → keep value-change only and drop `fillsOnAppear`.
- [ ] **Step 6: Commit** `feat(motion): progress bar fills and glides to new positions`.

### Task 3: Docs, build both platforms, open PR 1

- [ ] **Step 1: Update the docs.**
  - `docs/design-system/motion.md`: replace the `CinemaMotion.standard` line with the real token table, and list the new components that honour the flag.
  - `Shared/DesignSystem/CLAUDE.md`: one RULE line, "new animations take their timing from `CinemaMotion` and gate through `CinemaMotion.gated`".
- [ ] **Step 2: Build and test both platforms.**
  - `xcodebuild test` on the iOS scheme, then the tvOS scheme, serially, with `set -o pipefail`.
  - Expected: `** TEST SUCCEEDED **` and a `✔ Test run with N tests` line on both.
- [ ] **Step 3: Lint.** Run SwiftLint `--strict` against the baseline. Expected: no new violation.
- [ ] **Step 4: Commit, push, `gh pr create` against `main`.**

## PR 2 — `claude/interface-animations-2` (base: PR 1)

### Task 4: Image fade-in

**Files:**
- Modify: `Shared/DesignSystem/Components/CinemaLazyImage.swift`
- Modify: the Home hero (`HomeScreen.heroSection`), the tvOS hero (`HeroBackdropImage`), if it uses `CinemaLazyImage`, and the fiche backdrop. Pass `fadesIn: false` where a fade would fight another animation; grep the call sites and list the ones opted out.

**Interfaces:**
- Produces: `CinemaLazyImage(... fadesIn: Bool = true)`.

- [ ] **Step 1: Implement.**
  - `LazyImage(url: url, transaction: Transaction(animation: fadesIn ? CinemaMotion.gated(CinemaMotion.imageFade, enabled: motion) : nil))`.
  - Give the image branch `.transition(.opacity)`.
  - Confirm in the 13.2.3 checkout that the memory-cache path still bypasses `transaction` (Review Focus 2).
- [ ] **Step 2: Manual check on the simulator.**
  - Scroll a library grid down and back up: no fade on return.
  - The Home hero crossfade is unchanged.
- [ ] **Step 3: Measure.** Library grid scroll on the iPhone and Apple TV simulators, before and after. If over threshold on tvOS, set `fadesIn` default by platform (`true` on iOS only) and report.
- [ ] **Step 4: Commit** `feat(motion): artwork fades in when it arrives`.

### Task 5: Content replaces the skeleton

**Files:**
- Modify: `Shared/DesignSystem/Components/SkeletonViews.swift` (add `ContentReveal` + `.contentReveal(step:)` modifier)
- Modify: `Shared/Screens/HomeScreen.swift:101-115` and the first rows of `content`; `Shared/Screens/MovieLibraryScreen.swift` around `loadingView`
- Test: `Tests/CinemaxKitTests/HomeViewModelTests.swift`

**Interfaces:**
- Produces:
  - `enum ContentReveal { nonisolated static func shouldAnimate(now: Date, revealStartedAt: Date?, window: TimeInterval = 1.0) -> Bool }`
  - `extension EnvironmentValues { @Entry var contentRevealStartedAt: Date? = nil }`
  - `View.contentReveal(step: Int) -> some View`: opacity 0 and y-offset 10 → 1/0, delay `Double(min(step, 3)) * CinemaMotion.revealStagger`, animates only when `shouldAnimate` is true at `.onAppear`.

- [ ] **Step 1: Write the failing test** `@Test func contentRevealOnlyWithinWindow()`:
  - `shouldAnimate(now: t, revealStartedAt: nil) == false`
  - `shouldAnimate(now: t + 0.2, revealStartedAt: t) == true`
  - `shouldAnimate(now: t + 1.5, revealStartedAt: t) == false`
- [ ] **Step 2: Build the tests.** Expected: compile error.
- [ ] **Step 3: Implement the type and modifier.**
- [ ] **Step 4: Home.**
  - The skeleton branch gets `.transition(.opacity)`. The `ZStack` gets `.animation(CinemaMotion.gated(.easeOut(duration: 0.25), enabled: motion), value: showsSkeleton)`, where `showsSkeleton` is the existing `if` condition extracted into a computed property.
  - Add `@State revealStartedAt: Date?`, set to `.now` in an `.onChange(of: showsSkeleton)` when it goes true → false (only when motion is on), and injected into `content` through the environment.
  - Apply `.contentReveal(step:)` to the hero (0) and the next two rows (1, 2) only.
  - tvOS: if default focus lands late on device, drop the offset on tvOS and keep the opacity.
- [ ] **Step 5: Library.** The same pattern around `loadingView` and the first browse rows of `MovieLibraryScreen`.
- [ ] **Step 6: Run the full iOS test suite**, then check by hand:
  - The reveal plays on first load and after a pull-to-refresh.
  - It does not play when a genre row arrives late, or when coming back to the tab.
- [ ] **Step 7: Commit** `feat(motion): Home and library content rise in after the skeleton`.

### Task 6: Docs, both platforms, open PR 2 (as Task 3)

## PR 3 — `claude/interface-animations-3` (base: PR 2)

### Task 7: Fiche parallax and edge recede in rows

**Files:**
- Modify: `Shared/Screens/MediaDetailScreen.swift` (`backdropSection`, hero title/logo overlay, toolbar title), `Shared/DesignSystem/Components/ContentRow.swift` (iOS item branch), the `ContentRow` call sites that should opt in
- Create: none. The pure math goes in `Shared/DesignSystem/AdaptiveLayout.swift` as `enum ScrollMotion`.
- Test: `Tests/CinemaxKitTests/DetailHeroLogoTests.swift`

**Interfaces:**
- Produces:
  - `enum ScrollMotion { nonisolated static func parallaxOffset(minY: CGFloat, factor: CGFloat = 0.45) -> CGFloat; nonisolated static func heroTitleOpacity(scrolled: CGFloat, fadeDistance: CGFloat = 90) -> Double; nonisolated static func showsBarTitle(scrolled: CGFloat, heroHeight: CGFloat) -> Bool; nonisolated static func edgeRecede(phase: Double) -> (scale: CGFloat, opacity: Double) }`
  - `ContentRow(..., recedesAtEdges: Bool = false)`

- [ ] **Step 1: Write the failing tests** `@Test func scrollMotionMath()`:
  - `parallaxOffset(minY: -100) == 45` (pushes the image down by 45 % of the upward scroll)
  - `parallaxOffset(minY: 30) == 0` (no movement while overscrolling at the top)
  - `heroTitleOpacity(scrolled: 0) == 1`, `heroTitleOpacity(scrolled: 45) == 0.5`, `heroTitleOpacity(scrolled: 200) == 0`
  - `showsBarTitle(scrolled: 300, heroHeight: 400) == false`, `showsBarTitle(scrolled: 420, heroHeight: 400) == true`
  - `edgeRecede(phase: 0)` is `(1, 1)` and `edgeRecede(phase: 1)` is `(0.9, 0.55)`
- [ ] **Step 2: Build the tests.** Expected: compile error.
- [ ] **Step 3: Implement `ScrollMotion`.**
- [ ] **Step 4: Fiche (iOS only).**
  - Backdrop image: `.visualEffect { content, proxy in content.offset(y: motion ? ScrollMotion.parallaxOffset(minY: proxy.frame(in: .scrollView).minY) : 0) }`. The overlay already clips.
  - Title/logo: opacity from the same geometry, through `.visualEffect`.
  - Bar title: one `@State showsBarTitle: Bool` flipped by `.onScrollGeometryChange(for: Bool.self)` on the detail `ScrollView`, shown with `.toolbar { ToolbarItem(placement: .principal) { Text(item.name) } }` and an opacity animated by `CinemaMotion.gated`.
  - With motion off: no offset, no fade, bar title shown or hidden without animation.
- [ ] **Step 5: Rows (iOS only).**
  - `ContentRow` items get `.scrollTransition(.interactive, axis: .horizontal) { c, phase in let r = ScrollMotion.edgeRecede(phase: abs(phase.value)); return c.scaleEffect(r.scale).opacity(r.opacity) }`, only when `recedesAtEdges && motion`.
  - Opt in the media-card rows: Home rails, genre rows, similar titles, person page. Cast, Seerr missing titles and « En direct » stay off.
  - The first card at rest must be at full scale. Use `.topLeading` content margins already in the row; check visually.
- [ ] **Step 6: Run the full iOS test suite, then measure the Home rows** before and after. Above the threshold, drop the row effect and report.
- [ ] **Step 7: Commit** `feat(motion): fiche backdrop parallax and receding row edges`.

### Task 8: Season swap

**Files:**
- Modify: `Shared/ViewModels/MediaDetailViewModel.swift:1142` (`selectSeason`), `Shared/Screens/MediaDetailScreen.swift` around the episode list (~2000, and the iPad horizontal layout)
- Test: `Tests/CinemaxKitTests/MediaDetailViewModelTests.swift`

**Interfaces:**
- Produces: `MediaDetailViewModel.seasonSwapCount: Int` (plain stored `var`, no observers), incremented only inside `selectSeason` when the new episodes are assigned.

- [ ] **Step 1: Write the failing tests.**
  - `@Test func selectingASeasonBumpsTheSwapCount()`: `selectSeason` with a mock returning episodes leaves `seasonSwapCount == 1`.
  - `@Test func refreshingTheSameSeasonDoesNotBumpTheSwapCount()`: the refresh path that reassigns `episodes` (the `episodesTask` reload near line 642) leaves it unchanged.
- [ ] **Step 2: Run them.** Expected: compile error.
- [ ] **Step 3: Implement the counter.**
- [ ] **Step 4: Animate the list.**
  - Give the episode list container `.id(viewModel.seasonSwapCount)`, a `.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))`, and `.animation(CinemaMotion.gated(CinemaMotion.listSwap, enabled: motion), value: viewModel.seasonSwapCount)` on its parent.
  - tvOS: check that focus stays on the season chip.
- [ ] **Step 5: Run the full iOS test suite.** Expected: passes.
- [ ] **Step 6: Commit** `feat(motion): episodes slide in when the season changes`.

### Task 9-bis: Docs, both platforms, open PR 3 (as Task 3)

## PR 4 — `claude/interface-animations-4` (base: PR 3)

### Task 9: Player skip button, play/pause glyph, countdown

**Files:**
- Modify: `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift` (skip-button sites at ~1508, ~1528, ~1540, ~1573, ~1603, ~1689 and the enter/leave branch of `updateSkipButton`; `setPlayPauseIcon` at ~5249, iOS only), `Shared/Screens/VideoPlayer/NextUpCountdownView.swift`
- Modify: `Shared/Screens/VideoPlayer/AutoSkipPolicy.swift` (add `SkipButtonPresentation`)
- Test: `Tests/CinemaxKitTests/AutoSkipPolicyTests.swift`

**Interfaces:**
- Produces:
  - `enum SkipButtonChange { case setup, itemReset, invalidTime, autoSkipped, handedToNextUpCard, segmentEntered, segmentLeft, userSkipped }`
  - `enum SkipButtonPresentation { nonisolated static func animates(_ change: SkipButtonChange, motionEnabled: Bool) -> Bool }`
  - `private func setSkipButtonVisible(_ visible: Bool, change: SkipButtonChange)` in the presenter

- [ ] **Step 1: Write the failing test** `@Test func skipButtonAnimatesOnlyInsideASegment()`:
  - `animates` is true for `.segmentEntered`, `.segmentLeft` and `.userSkipped`.
  - It is false for the other five.
  - It is false for all eight when `motionEnabled == false`.
- [ ] **Step 2: Build the tests.** Expected: compile error.
- [ ] **Step 3: Implement the policy and `setSkipButtonVisible`.**
  - Animated show: `isHidden = false`, alpha 0 and `transform` x +26 → identity and alpha 1, over `CinemaMotion.overlaySlide`.
  - Animated hide: the reverse over `overlaySlideOut`, then `isHidden = true` in the completion, only if no show started meanwhile. Track this with a generation counter.
  - Instant: set `isHidden`, alpha 1, identity.
  - Route every site through it. No other change in the presenter.
- [ ] **Step 4: Play/pause (iOS only).**
  - In `setPlayPauseIcon`, when `MotionEffects.isEnabledNow`, wrap the configuration change in `UIView.transition(with: playPauseButton, duration: 0.2, options: .transitionCrossDissolve)`.
  - Skip the transition when the glyph does not actually change.
- [ ] **Step 5: Countdown.** In `NextUpCountdownView`, when the number changes and motion is on, add a `CATransition` (`.push`, `.fromTop`, 0.25 s) to `countdownLabel.layer` before setting the text.
- [ ] **Step 6: Run the full iOS and tvOS test suites.** Expected: pass.
- [ ] **Step 7: Check in the simulator.**
  - iPhone: the skip button slides in at the intro, and the HUD auto-hide is unchanged.
  - Apple TV: focus can reach the skip button while it is shown, never once it is hidden.
  - Duo tabletop: the 27.1 SDK simulator.
  - Use the demo devices only, never the personal account.
- [ ] **Step 8: Commit** `feat(motion): player skip button slides, play/pause and countdown transitions`.

### Task 10: Docs, both platforms, open PR 4 (as Task 3), with the device-check list in the PR body as still to do on hardware
