# Entitlements (Free / Pro)

> Loaded when you work under `Shared/Entitlements/`. The strategy (what will be Pro, price, sequencing, App Review risks) is in `docs/superpowers/specs/2026-09-30-entitlements-foundation-design.md`. The root file's cross-cutting rules (Swift 6, `@Observable` without `didSet`, xcodegen, tests) still apply. Lines tagged **RULE** override default behavior.

## What is here (2026-09-30: a FOUNDATION, nothing is locked)

- `EntitlementState` (`.free` / `.pro(EntitlementSource)`), `EntitlementPolicy.resolve` (pure: local purchase → `.pro(.purchase)`, else iCloud record → `.pro(.cloudMirror)`, else — DEBUG only — « Simuler Pro » → `.pro(.debugOverride)`, else `.free`).
- `CloudEntitlementRecord` — the purchase proof, `version` 1, JSON; `decode(_:)` returns `nil` for an unknown version or a malformed blob, never traps. Carries the StoreKit JWS (`signedTransaction`) for a future verifying reader.
- `CloudKeyValueStore` (injectable protocol) + `UbiquitousCloudKeyValueStore` (`NSUbiquitousKeyValueStore.default`, listens to `didChangeExternallyNotification`); `CloudEntitlementMirror` keeps ONE record under the KVS key **`entitlement.pro.v1`**.
- `EntitlementStore` — `@MainActor @Observable`, process singleton `AppNavigation.sharedEntitlements`, injected via `.environment`. Mutators `refresh()` (launch + every `scenePhase == .active`), `recordPurchase(_:)` (local `SettingsKey.entitlementLocalRecord` + mirror), `clearLocal()`, `setDebugOverride(_:)` (`#if DEBUG`, `SettingsKey.debugSimulatePro`). The only reader today is Settings → Lecture → Débogage (`EntitlementDebugRows` on iOS, inline on tvOS).
- No `import StoreKit` anywhere yet, no purchase UI, no gating.

## RULEs

- **RULE — playback is never paid.** No playback path (the player, `PlayLink`, `CardActionPresenter`, resume, next-up, subtitles/audio pickers, SyncPlay JOIN) may ever read `EntitlementStore`. Joining a Watch Together session stays free; only creating one is a Pro candidate. A gate on playback is a product regression, not a feature.
- **RULE — the KVS identifier `$(TeamIdentifierPrefix)com.cinemax.shared` is the SAME in `iOS/Cinemax.entitlements` and `tvOS/CinemaxTV.entitlements` (both generated from `project.yml`) and must never diverge nor be renamed.** Identical identifiers are what make the two apps (different bundle ids, so no universal purchase) read one store; renaming it silently strands every mirrored purchase in the old container. It is NOT in the widget or the Top Shelf. Signing needs the iCloud capability on both App IDs — automatic signing adds it with `-allowProvisioningUpdates`; CI builds unsigned and cannot see a missing one.
- **RULE — no `AppTransaction` outside a path the USER explicitly triggered** (a « Restaurer » / « Acheter » tap). In a Debug build it raises a sandbox Apple-account prompt; at launch that is a prompt nobody asked for. The future « Fondateurs » check (`AppTransaction.originalPurchaseDate`) runs from such a tap, or from a later StoreKit refresh that is already authenticated.
- **RULE — the iCloud mirror is a cross-platform CONVENIENCE, never the truth on the platform the purchase was made on.** There, the truth will be StoreKit (`Transaction.currentEntitlements`); the mirror only lets the OTHER app unlock. `clearLocal()` leaves the mirror alone (it may be the other platform's record). The KVS is user-writable in principle (1 MB, no server check) — `signedTransaction` exists so a later reader can verify the JWS rather than trust the blob.
- **RULE — the record's wire format is a contract between two binaries of possibly different versions**: add a field only as an optional; anything else bumps `version` (and, if old readers must keep working, moves to a new KVS key `entitlement.pro.v2`). Dates use the coder's default strategy in both apps.
- **RULE — Release ignores « Simuler Pro »**: the override is read by `EntitlementStore` and honoured by `EntitlementPolicy` only under `#if DEBUG`; `setDebugOverride` does not exist in Release.

## Tests

`Tests/CinemaxKitTests/EntitlementTests.swift` (suites « Entitlement policy », « Entitlement record + iCloud mirror », « Entitlement store ») on `InMemoryCloudKeyValueStore` (`Tests/CinemaxKitTests/InMemoryCloudKeyValueStore.swift` — `simulateExternalChange` plays the other device) and `UserDefaults.isolatedForTesting()`; an external change is awaited with `eventually { }`, never a sleep. The policy's Debug-only branch is asserted under `#if DEBUG` / `#else` in the same test.
