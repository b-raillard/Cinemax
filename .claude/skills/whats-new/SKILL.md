---
name: whats-new
description: Add the « Quoi de neuf » pages of a release — catalogue entry, FR/EN/DE strings, illustration, tests — and check everything a release page needs. Use as /whats-new <version> <page ids or a short description of each feature>.
disable-model-invocation: true
---

# whats-new

Adds one release to « Quoi de neuf » (`Shared/Update/`). The content is DATA: one `WhatsNewRelease` entry in `WhatsNewCatalogue.releases` + two strings per page in each language. **Read `Shared/Update/CLAUDE.md` first** — every RULE below comes from it and it wins on any conflict.

Arguments: the version (`2.7.0`) and the features. If a feature has no page id yet, propose one (camelCase, unique across ALL releases — a feature is announced once in the app's life) and ask before writing.

## Steps

1. **Read the state**: `MARKETING_VERSION` in `project.yml`, the newest entry of `WhatsNewCatalogue.releases`, the existing `whatsNew.*` keys. A version already in the catalogue is edited, never duplicated.
2. **Catalogue entry** — newest release FIRST in the array, the owner's page order:
   ```swift
   WhatsNewRelease(version: ServerVersion(2, 7, 0), pages: [
       WhatsNewPage(id: "<id>", illustration: .<motif>),
   ]),
   ```
   Options, only when the feature needs them:
   - `platforms: [.iOS]` / `[.tvOS]` — a feature that exists on one app is announced on that app only; the other app gets its OWN page id, never a shared page with platform branches in its text.
   - `footnoteKey: "whatsNew.footnote.seerr"` — something outside Jellyfin is required: the title ends in « * », the footnote says what.
   - `offer:` — a one-tap opt-in (`.seasonalTheme(id:)` must name a catalogue season).
   - `hasDuoVariant: true` — also writes `whatsNew.<id>.other.title` / `.body`.
3. **Strings** — `whatsNew.<id>.title` and `whatsNew.<id>.body` in `Resources/{fr,en,de}.lproj/Localizable.strings`, next to the previous release's keys. French first and natural; « vous » in FR, « du » in DE (the app's register — check a neighbouring key). Short title (it must fit the iPhone and the TV), one or two sentences of body that say what the user can now DO and where.
4. **Illustration** — reuse a `WhatsNewIllustration` case when one fits. A NEW motif is drawn (never a screenshot), on the 100 × 100 grid in `MotifInk`, and is a PORT of an approved mockup: if there is no approved mockup for it, stop and ask for one instead of inventing the art.
5. **Version** — if the release is the next one, `MARKETING_VERSION` in `project.yml` moves to it (pages newer than the installed build are hidden, by design — `WhatsNewCatalogue.pages` excludes them).
6. **Tests** — the shipped-catalogue tests already cover unique ids and every key in every language; add a release test like `WhatsNew260Tests` when the release has platform slices, offers or animated motifs.
7. **Check**:
   ```bash
   python3 scripts/check-localization-parity.py
   ```
   then the iOS test suite (`xcodebuild test -scheme Cinemax …`, grep `✔ Test run with`), and the tvOS build when a page is tvOS-visible. A new Swift file needs `xcodegen generate` (the PostToolUse hook does it).
8. **Report** the pages per platform (iOS / tvOS), with each title in French, so the owner can read the reel without running it. Remind them that tvOS shows « Noter JellyGlass » on the last page only if the release has at least one tvOS page.

Never touch `whatsNew.lastSeenVersion` handling or `WhatsNewPolicy` for a content release.
