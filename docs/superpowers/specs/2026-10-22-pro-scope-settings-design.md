# Pro scope, Settings reorganisation, Halloween all year — design (2026-10-22)

Decided with the user on 2026-10-22 (conversation, answers « oui pour les trois »). Branch: `claude/pro-purchase`. Three deliveries, in this order, each with its own tests and simulator check (test simulators only).

## The Pro list (replaces the pending review of 2026-10-14)

| Feature | Tier |
|---|---|
| Remembered accounts, one-tap switch (done, spec 2026-10-20) | Pro |
| Administration | Pro |
| « Lire sur… » (send playback to another device) | Pro |
| Alternate app icons (the default icon stays free) | Pro |
| Seasonal themes all year (Halloween only for now) | Pro |
| Shortcuts / App Intents / Control Center « Reprendre » | Pro |
| Create a « Regarder ensemble » session | **Free** (differentiating) |
| Custom menu | **Free** |
| Accent colours | **Free** |
| Multi-server catalogue merge | Pro, later, separate project |

Reading the playback stays free forever (public commitment, see the monetisation memory).

## Lot A — Settings: one Administration page, a Debug menu

1. **Administration**: `SettingsCategory.administration` and `.advancedAdmin` merge into ONE category / landing (iOS/iPadOS only, admins only, as today). Sections and rows:
   - **Serveur**: Tableau de bord, Activité, Tâches, Journaux
   - **Utilisateurs**: Utilisateurs, Appareils, Clés d'API
   - **Bibliothèque**: Métadonnées, Catalogue, Extensions
   - **Configuration**: Lecture, Réseau
   `advancedAdmin` disappears; a persisted / restored raw value `advancedAdmin` (settings navigation state) must fall back safely, never crash a decode.
2. **Debug**: the « Débogage » section leaves the Lecture page (both platforms) and becomes a top-level Settings category « Debug » (last in the list), holding everything it holds today (debug toggles, entitlement rows incl. « Palier simulé », diagnostics export / tvOS note).
   - **Visible in Xcode and TestFlight builds, hidden in the App Store build.** Decided through the existing environment detection (`EarlyAdopterPolicy` environment: production / sandbox / xcode), never a compile flag — TestFlight testers and the recette must keep reaching « Palier simulé ». Simulators must read as non-production. The `Settings/CLAUDE.md` rule « Debug always visible, no `#if DEBUG` » is rewritten accordingly.
   - tvOS: the new category goes through the Settings landing focus rules (TV-06: initial focus on the right-hand menu; the tier chip reached by Left).

## Lot B — Pro gating (effective only after the Pro launch)

`ProFeatureGate` already keeps everything open before the launch pivot; nothing changes for users until then.
- `ProFeatureCatalogue`: remove `watchTogetherHost`, `customMenu`, `accentsAndIcons`; add `appIcons`; keep `memorizedAccounts`, `administration`, `playOn`, `seasonalAllYear`, `shortcuts`. Strings fr/en/de, parity. Read `ProFeatureCatalogueTests` first (it may assert a gate site per catalogued feature).
- One gate site per feature, all through `ProFeatureGate`:
  - **Administration** (iOS): the row stays visible to a free admin, with a lock; tapping opens `ProUpsellSheet(feature: .administration)`.
  - **« Lire sur… »** (both platforms): the button on the fiche stays visible; free → upsell.
  - **App icons**: the default icon free; choosing another → upsell when free.
  - **Shortcuts / App Intents / Control Center**: in free, the intent answers a localized « fonction Pro » and opens the app on the Pro page (check `Shared/Intents/CLAUDE.md` for what an intent may present; the headless `IntentSessionProvider` must be able to read the entitlement).

## Lot C — Halloween all year

- A user choice in Apparence (both platforms): **Automatique** (today's behaviour: Halloween in season) / **Désactivé** / **Halloween** (forced, any date).
- **Halloween forced = Pro** after the launch; free keeps Automatique / Désactivé.
- The decision only: `SeasonalThemePolicy` (pure, tested) resolves choice × date × tier. Rendering (`SeasonalAmbiance`, `CAEmitterLayer`) is not touched.
- Other seasons (Christmas…) are a separate content project.

## Out of scope

Multi-server catalogue merge; offline mode (3.1); Seerr; continuity; CarPlay video.
