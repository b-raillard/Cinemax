# Accessibility (Apple model — not web)

Translate the WCAG intent into the Apple frameworks this app actually uses: **VoiceOver** (iOS) / **VoiceOver on tvOS**, the **tvOS focus engine**, **Dynamic Type**, **Reduce Motion**, and touch-target/contrast rules. There is no DOM, no ARIA, no keyboard tab-order — do not report those. Delegate the **tvOS focus engine** correctness to the `tvos-focus-reviewer` subagent; do the VoiceOver / Dynamic Type / contrast / motion passes yourself.

Test target: **WCAG 2.2 AA intent**, expressed through Apple APIs.

## 1. VoiceOver — accessible names, values, hints, grouping

~93 `.accessibility*` modifiers exist today — coverage is partial, so this is a real audit, not a rubber stamp.

- **Icon-only buttons** must have an `accessibilityLabel` (a bare SF Symbol reads as nothing or the symbol name). Prime suspects: player transport (play/pause/skip/audio/subtitle/PiP), the `AdminItemMenu` ellipsis, close/dismiss chevrons, the mic button, download/heart/rating badges, `CinemaToggleIndicator`.
  ```bash
  # icon-only Buttons/Labels with a systemImage and no nearby accessibilityLabel — candidates to read
  grep -rn --include='*.swift' 'Image(systemName:' Shared/Screens | head -60
  grep -rln --include='*.swift' 'accessibilityLabel\|accessibilityElement' Shared/Screens
  ```
- **State conveyed only visually needs an `accessibilityValue`/`.accessibilityAddTraits`**: `CinemaToggleIndicator` (on/off — is the state announced?), selected tab, download progress %, playback play/pause state, rating.
- **Composite cards** (`PosterCard`, `WideCard`, `MediaDetailEpisodeCard`) should be a **single** accessibility element with a combined label (title + year + progress), not N separate mumbled sub-elements. Check for `.accessibilityElement(children: .combine)` / `.ignore`.
- **Decorative images** (backdrops, gradients, `BackdropFallbackView`) should be `.accessibilityHidden(true)` so VoiceOver skips them.
- **Progress / remaining-time** (`ProgressBarView`, "Xm remaining") — is the value exposed to VoiceOver or just drawn?

## 2. Dynamic Type (iOS)

- Root applies `.dynamicTypeSize(.xSmall ... .accessibility2)` (caps above `.accessibility2` to protect hero/tab-bar — documented, intentional). Verify reading-heavy surfaces use `CinemaFont.dynamicBody/dynamicBodyLarge/dynamicLabel` (scale with type), while hero/display titles keep fixed fonts (layout protection — intentional).
- **`CinemaScale.pt(...)` / `CinemaFont.*` only — no bare `.font(.system(size: N))`** (RULE — a numeric literal ignores `uiScale`/tvOS 1.4×). This is also a `design-system-review` check; run it, then verify from the *a11y* angle that overflow/truncation at the largest allowed type size doesn't hide content (see `ui-consistency.md §responsive`).
  ```bash
  grep -rn --include='*.swift' '\.font(\.system(size:' Shared | grep -v 'DesignSystem'
  ```

## 3. tvOS focus engine (delegate, then verify the a11y consequences)

Focus IS keyboard-equivalent navigation on tvOS. The `tvos-focus-reviewer` subagent owns correctness; from the accessibility angle confirm:

- Every interactive element is reachable by focus (no focus traps, no orphaned controls). The documented player traps — Menu-peel infinite loop, hidden-HUD wake whitelist, `.focusSection()` on heroes — are the known-hard spots.
- **Focus visibility**: 2px accent `strokeBorder` (no scale/white-bg per design system). A focused element with no visible focus ring is a Critical a11y bug on tvOS.
- Focus **restoration** after a modal/player dismiss lands somewhere sensible (not dumped to the first tab — the documented `UITabBarController` position-remount bug and the `scrollTo("...top")` yank are exactly this).

## 4. Reduce Motion

- `motionEffectsEnabled` env (from `@AppStorage("motionEffects")`) must gate **all** `.animation()` → nil when off (RULE). Flag any `.animation(...)`, `withAnimation`, `symbolEffect`, or transition that ignores the flag — a user with vestibular sensitivity gets motion anyway.
  ```bash
  grep -rn --include='*.swift' 'withAnimation\|\.animation(\|symbolEffect\|\.transition(' Shared/Screens | grep -viE 'motionEffects|nil|// ' | head -40
  ```

## 5. Contrast, touch targets, color-alone

- **Contrast**: "Cinema Glass" is dark glassmorphism over translucent panels — the highest-risk pattern for AA text contrast (4.5:1 body / 3:1 large). Spot-check `onSurfaceVariant` and any text over a `.glassPanel()` / backdrop-with-gradient. Text over a bright poster/backdrop with only a gradient scrim is the classic failure — verify the scrim guarantees contrast, not just "usually".
- **Touch targets ≥ 44×44 pt** (iOS): small icon buttons, chapter chips, the toggle pill, jump-bar letters, per-episode download button. Flag `.frame(width:/height:)` under 44 on a tappable element without an expanded `.contentShape`/hit area.
  ```bash
  grep -rn --include='*.swift' '.frame(width: 2\|.frame(width: 3\|.frame(height: 2\|.frame(height: 3' Shared/Screens | head
  ```
- **Color-alone meaning**: quality/HDR badges, watched/unwatched, download status, error vs success toasts, active-tab tint — is there a shape/label/icon in addition to color? A red-only error and a green-only success fail for color-blind users; `ToastCenter` `.success/.error` must differ by icon, not just color.

## 6. Dynamic-content announcements

- **Toasts** (`ToastOverlay`) — a visual-only pill is invisible to VoiceOver. Verify an `AccessibilityNotification.Announcement` (or `.accessibilityAddTraits(.isSummaryElement)` + focus move) fires so the message is spoken. This is the most likely systemic gap.
- **Loading → loaded** transitions and **validation errors** (login failures, form errors) should move focus or announce, not silently repaint.
- **Modals / sheets / menus** (`QuickConnectSheet`, `LibrarySortFilterSheet`, `UserSwitchSheet`, `AdminItemMenu`) — VoiceOver focus should move into the presented content on open and restore on close.

## Severity guidance

- **High**: an interactive control with no accessible name in a core flow (playback, login); a tvOS control with no visible focus ring; toasts/errors never announced.
- **Medium**: composite cards read as fragmented; Reduce Motion ignored on a prominent animation; text contrast under a scrim that can't be guaranteed.
- **Low/Info**: decorative image not hidden; touch target slightly under 44pt with adequate spacing.
