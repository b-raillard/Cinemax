# Per-server menu configuration — design

> Status: implemented on `integration/audit-2026-07`. Kept as the rationale record; the enforcing rules live in `CLAUDE.md` (*Custom menu / dynamic tabs*).

## Problem

Switching servers destroys the user's custom menu, and switching back does not restore it.

`AppNavigation`'s `onChange(of: appState.serverURL)` calls `menuConfig.invalidateViews()`, which sets `availableViews = []` **and** `libraryEntries = []` *and persists both*. The arrangement (order + enabled flags) is deleted, not shelved — server A's layout is gone the moment the user moves to server B, and coming back to A yields whatever `refreshAvailableViews()` rebuilds from scratch.

That rebuild is itself degenerate. `mergeLibraryEntries(existing: [], views:)` walks an empty list, so:

- every library is inserted first (there is no `settings` entry to insert before, so `insertIdx == endIndex`),
- `home` / `search` / `settings` are then *appended at the end*, unconditionally `enabled: true`, **without re-checking the 5-tab cap**.

A server with 5+ libraries therefore comes back as "all libraries, then Home/Search/Settings", with up to 8 enabled tabs. That is the scrambled menu the user reported.

`mode`, `customKind` and `contentTypeEntries` are global `UserDefaults` keys and survive a switch, so today's loss is confined to library mode — but the whole configuration is global, which is what this design changes.

`CLAUDE.md` currently documents per-server settings profiles as deliberately out of scope. This design reverses that decision **for the menu only**; accent / theme / rating cap stay global.

## Decisions taken

1. **Full per-server menu profile**: `mode`, `customKind`, `contentTypeEntries`, `libraryEntries`, `availableViews`. Each server owns an independent menu.
2. **A newly added server starts from factory defaults** (`.default` mode, canonical 5 tabs). No inheritance from the current server.
3. **Storage is one blob**, `menu.profiles` → `[serverId: MenuProfile]`.
4. **The profile key is the server id, not the user id.** Two accounts on the same server share a profile.

### Why one blob

| | one blob `menu.profiles` | suffixed keys `menu.mode.<id>`, … | one blob per server `menu.profile.<id>` |
|---|---|---|---|
| Writes | re-encodes all profiles (a few KB) | one key per field | one key per server |
| Prune a removed server | drop a dict entry | 5 `removeObject` per server, by exact key name | one `removeObject` |
| Find orphan namespaces | iterate the dict | prefix scan of `dictionaryRepresentation()` | prefix scan |
| Failure mode | none particular | a forgotten suffix leaks one server's menu onto another — the exact bug class being fixed | same, narrower |
| Persistence code | **one** `persistActiveProfile()` replaces 3 persist methods + 2 inline `persist` calls | unchanged shape (5 paths) | one path |

The blob wins on the two things that matter here: a single persistence path, and pruning that cannot be half-done. The write cost is a handful of short strings per registered server.

## Model

```swift
struct MenuProfile: Codable, Equatable {
    var mode: MenuConfigStore.Mode
    var customKind: MenuConfigStore.CustomKind
    var contentTypeEntries: [MenuEntry]
    var libraryEntries: [MenuEntry]
    var availableViews: [LibraryView]

    static let factoryDefault = MenuProfile(
        mode: .default,
        customKind: .contentType,
        contentTypeEntries: MenuConfigStore.defaultContentTypeEntries,
        libraryEntries: [],
        availableViews: []
    )
}
```

**Swift 6 note**: `MenuConfigStore` is `@MainActor`, so its `static let defaultContentTypeEntries` is main-actor-isolated and a nonisolated `MenuProfile.factoryDefault` cannot read it. Mark that constant `nonisolated static let` — it is `[MenuEntry]`, a Sendable value type, which is documented escape hatch #3 in `CLAUDE.md`. `MenuProfile` itself is implicitly `Sendable` (all members are). Nested `Mode` / `CustomKind` do **not** inherit the class's isolation, so they need nothing.

`MenuConfigStore` gains two private/derived members and **keeps all five observable properties unchanged**:

```swift
private var profiles: [String: MenuProfile]   // loaded once in init
private(set) var activeProfileId: String?     // nil until the first activate()
```

No UI call site changes: `MenuSettingsScreen`, `MenuSettingsScreen+iOS`, `MenuSettingsScreen+tvOS` and `MainTabView` keep reading `store.mode` / `store.contentTypeEntries` / `store.resolvedTabs` as they do today.

## Lifecycle

```swift
func activate(serverId: String?, knownServerIds: Set<String>)
```

- `serverId == nil` → **no-op**. Keeps the loaded profile. A logout must not blank the menu; Settings is unreachable while signed out, and re-logging into the same server finds its profile intact.
- `serverId == activeProfileId` → **no-op**. Load-bearing: the explicit call in `.task` and the `onChange` observer overlap on a cold launch.
- otherwise → prune, load, recompute:
  1. **Prune**: drop every profile whose id is absent from `knownServerIds`, never the id being activated. **Skipped entirely when `knownServerIds` is empty** (registry not hydrated yet — pruning there would wipe everything).
  2. **Load**: `profiles[serverId]`, else the migration seed (below), else `MenuProfile.factoryDefault`.
  3. Assign the five observable properties, running `applyCap` on both entry arrays exactly as `init` does today for persisted state.
  4. `activeProfileId = serverId`, persist if the prune or the seed changed anything, `recomputeResolvedTabs()`.

Nothing needs saving before switching: the active profile is already written on every mutation.

### Persistence

`persistContentTypeEntries()`, `persistLibraryEntries()` and `persistAvailableViews()` collapse into a single:

```swift
private func persistActiveProfile()   // falls back to the legacy keys when activeProfileId == nil
```

which snapshots the five properties into `profiles[activeProfileId]` and writes the whole dict under `SettingsKey.menuProfiles`. `setMode` / `setCustomKind` call it instead of their inline `Self.persist(...)`. `toggleInternal`'s `persist: () -> Void` parameter disappears — there is one persist path now, so the closure only carried duplication.

`init` decodes `menu.profiles` (empty dict on failure or absence) and seeds the observable properties from the legacy global menu when one exists, else `MenuProfile.factoryDefault` — see *No active profile* below for why the legacy keys are still read. Nothing renders the menu before activation (`MainTabView` is behind `hasCheckedSession && isAuthenticated`), so there is no wrong-menu flash and no need to mirror a "last active id" for `init`.

### Migration

One-shot, idempotent, non-destructive — the same pattern as `KeychainService.migrateToMultiServerIfNeeded()`, keyed on state rather than a flag:

> On the first `activate(serverId:)` where `profiles` is **empty** and at least one legacy `menu.*` key exists, the activated server's profile is seeded from those legacy values (`menu.mode`, `menu.customKind`, `menu.contentTypeEntries`, `menu.libraryEntries`, `menu.cachedViews`), then persisted.

Missing legacy keys fall back exactly as today's `init` does: `mode` → `.default`, `customKind` → `.contentType`, `contentTypeEntries` → `defaultContentTypeEntries`, `libraryEntries` → `[]`, `availableViews` → `[]`. So a partially-written legacy state migrates without a special case.

Keying on "the dict is empty" means a `UserDefaults` read that comes back empty simply retries on the next launch. The legacy keys are **not deleted**. Every server activated after the dict is non-empty starts from factory defaults, per decision 2.

## Wiring in `AppNavigation`

Declaration order is load-bearing and replaces the current invalidate-before-refresh rule with an activate-before-refresh rule. `applyActiveServer` mutates `activeServerId`, `serverURL` and `currentUserId` in one transaction, and SwiftUI delivers same-transaction `onChange` handlers in declaration order:

```
.onChange(of: appState.activeServerId)   // NEW — first: swap the profile
.onChange(of: appState.serverURL)        // keeps StreamTransportPolicy only
.onChange(of: appState.currentUserId)    // attach + refreshAvailableViews (unchanged owner)
```

Concretely:

- **New observer** (declared before the other two):
  `menuConfig.activate(serverId: newId, knownServerIds: Set(appState.servers.map(\.id)))`.
- **`serverURL` observer**: `menuConfig.invalidateViews()` is removed; only the `StreamTransportPolicy.shared.configure(serverURL:)` call remains.
- **`.task`**: `menuConfig.activate(...)` immediately after `await appState.restoreSession()`, next to the existing `menuConfig.attach(...)`. `restoreSession` calls `loadServersFromKeychain()` first, so both `activeServerId` and `servers` are populated by then. It sits *after* `hasCheckedSession = true` but in the **same main-actor slice** — no `await` separates them, so SwiftUI coalesces the whole block into one render and the bar is never shown before its profile is loaded. Inserting an `await` between them breaks that.
- **`invalidateViews()` is deleted.** Each profile carries its own `availableViews`, so there is nothing left to invalidate on a switch. The `currentUserId` observer stays the single owner of `refreshAvailableViews()`.

### `MainTabView` (tvOS)

The frozen `displayedTabs` snapshot gains one bypass, alongside the existing `mode` / `customKind` ones:

```swift
.onChange(of: menuConfig.activeProfileId) { _, _ in
    displayedTabs = menuConfig.resolvedTabs
}
```

A server switch is a structural mutation, not a fine-grained edit. In practice the freeze is gated on `settingsNav.selectedInterfaceSub == .menu` and a switch happens from the Server page, so the guard would rarely bite — the bypass makes it impossible rather than unlikely. iOS renders live and is unaffected.

### Pruning cadence

Profiles of removed servers are collected on the next `activate(...)`. `AppState.removeServer` gets no hook: a stale profile is a few hundred bytes, and adding a second pruning owner is how the registry and the profile dict drift apart.

## Failure modes

| Situation | Behaviour |
|---|---|
| `menu.profiles` missing or undecodable | empty dict → factory defaults; migration seed still applies |
| No profile for the activated server | factory defaults |
| `knownServerIds` empty | prune skipped, profile still loaded |
| `activeProfileId == nil` (never activated / registry unavailable) | the store reads **and** writes the legacy global keys — exactly the pre-profiles behaviour; the first `activate` then adopts them (see *No active profile*) |
| Resolution comes up empty | unchanged: `computeResolvedTabs()` falls back to the canonical 5 — a black tab bar stays impossible |
| Two accounts on one server | share the profile; `mergeLibraryEntries` drops libraries the new account cannot see |

`reset()` restores factory defaults **for the active profile only**.

## Tests (`Tests/CinemaxKitTests/MenuConfigStoreTests.swift`)

New:

1. A→B→A round trip preserves each server's order and enabled flags (library mode and content-type mode).
2. Activating an unknown server id yields factory defaults and leaves the other profile untouched.
3. Migration seeds the first activated server from the legacy keys, exactly once — a second server activated afterwards gets factory defaults.
4. Prune drops profiles absent from `knownServerIds`; an empty `knownServerIds` prunes nothing.
5. `activate(nil)` and `activate(sameId)` are no-ops (no persist, no observable churn).

Updated:

- `clearMenuDefaults()` must also remove `SettingsKey.menuProfiles`.
- The two "`resolvedTabs` never empty" tests currently reach the pathological state through `invalidateViews()`. They are re-seeded by writing a `menu.profiles` blob holding `custom` + `library` + empty arrays, then constructing a store and activating — which additionally exercises the restore path.

Run the full suite (`-only-testing` silently runs zero swift-testing tests) and grep for `Suite "MenuConfigStore"` / `✔`.

## Documentation to update

- `CLAUDE.md` → Multi-server "Out of scope, deliberately": the menu is no longer global; only accent/theme/rating cap remain.
- `CLAUDE.md` → *Custom menu / dynamic tabs*: the invalidate-before-refresh RULE becomes activate-before-refresh; `invalidateViews()` no longer exists; note that profiles are keyed by server id, shared across accounts of that server.
- `CLAUDE.md` → `@AppStorage` table: add `menu.profiles`; mark the five `menu.*` keys as migration-only.

## No active profile

`activate` only ever sets `activeProfileId` from a non-nil server id, and `activate(nil)` returns early without clearing it — so `activeProfileId` is nil only *before* the first successful activation. That state is reachable **while signed in**: `migrateToMultiServerIfNeeded` returns early when its `saveServers` write throws, so `getActiveServerId()` stays nil while the legacy mirror still restores a session. The menu editor is reachable there, and per-server profiles have nothing to key on.

Rather than add a second storage namespace, the store degrades to **exactly its pre-profiles behaviour** in that state: `init` seeds from `legacyProfileSeed()`, and `persistActiveProfile()` writes the same legacy global keys. Both halves are needed — writing without reading would still show the factory-default menu, and reading without writing would still lose the edit. Because the fallback destination is the very key `legacyProfileSeed()` reads, an edit made in this state round-trips through `init` and is adopted by the first server that activates, through the existing one-shot migration. Nothing changes on the healthy path: once a profile is active it stays active for the process, so the fallback is unreachable there.


## Out of scope

Per-user profiles within a server; per-server accent/theme/rating cap; exporting or copying a menu from one server to another; any UI surface listing profiles.
