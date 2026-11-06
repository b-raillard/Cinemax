# Seerr requests — ask for a missing title from inside JellyGlass (2026-11-06)

Decided with the product owner on 2026-11-06, in conversation and on the interactive mockup [« Seerr dans JellyGlass »](https://claude.ai/artifact/CdTACXqkDVUzG81M9S3eXH) (choices recorded in its database). Supersedes the proposal of GitHub #173. Memory `project_jellyseerr_pro_feature` (« ne pas la construire avant le Pro ») is lifted: the Pro is in production since 2.5.0, everyone is a founder until the paid launch.

"Seerr" = the merged successor of Jellyseerr + Overseerr (github.com/seerr-team/seerr, v3.5.1 on 2026-10-21).

## Intent

The household's server runs Seerr next to Jellyfin. Today, wanting a title that is not on the server means leaving for another app. The product owner's bar: **it must feel built in, never bolted on.** JellyGlass knows what is missing at the place you already are — a search, a series whose next seasons are absent, a saga with holes, an actor's filmography — and lets you ask for it there, in one gesture, with no typing (Apple TV included).

## Decisions (product owner)

| Question | Answer |
|---|---|
| Where requesting happens | Search results, series fiche (missing seasons), saga, actor page. Plus follow-up and admin approval. |
| Look of a missing title | **Dashed outline**, no artwork, title inside (mockup option C). |
| Order | **Missing titles always AFTER the owned ones**, everywhere — so nothing already on screen moves when Seerr answers. |
| While Seerr loads | **Skeletons** in the place the Seerr items will take — only when Seerr is configured for this user. Not configured ⇒ nothing at all, the screen is today's. |
| Naming Seerr | **Only where the tool matters**: Settings, and the prompts that invite a user to connect. **Never** on search, fiches, lists. |
| Auth | **The user's choice, per their setup**: a personal Seerr account per user, or an API key. |
| Who gets the feature | **The admin enables it in JellyGlass Settings**, per user or « Activer pour tous », like a user permission. Seerr's own permissions remain the real gate on what may be requested. |
| Test + errors | A **« Tester la connexion »** button and **explicit error messages** (what went wrong, how to fix it). |
| Where « Mes demandes » lives | A **new Settings category « Demandes »** — not under Compte, not a tab. |
| Apple TV | The feature AND its configuration work on Apple TV. |
| Tier | Pro (decided 2026-10-01). Open to everyone while everyone is a founder. |
| Age-capped accounts | **Never see anything from Seerr** (Seerr results carry no reliable certification). Accepted cost: a child cannot request on their own. |
| Missing seasons on iPhone / iPad | The season **Menu keeps the owned seasons only**; the missing seasons are a row « Pas encore dans ta bibliothèque » of dashed season cards **after the episode list**. (Apple TV: dashed pills appended after the owned pills.) |

## Goals

1. From any of the four surfaces, a request lands in Seerr with the right TMDb id (and season numbers), attributed to the right person.
2. The state of an already-requested title is shown in place of « Demander »: « En attente », « En préparation », « Refusée ».
3. The user learns when a requested title has arrived, and can open it.
4. A Seerr manager can approve or decline pending requests from JellyGlass.
5. Configuration by the admin, pickup by every other device of every enabled user with no typing.

## Non-goals (v1)

- A « Découvrir » tab (trending, upcoming) — it would turn JellyGlass into a Seerr clone.
- 4K requests, advanced request options (Radarr/Sonarr server, profile, root folder, tags).
- Seerr issues (problem reports), watchlists, votes.
- Self-signed HTTPS certificates for Seerr (system trust only; plain HTTP works on the local network, see Constraints).
- A password form for Seerr login (no Quick Connect ⇒ the test fails with its message; see Auth).
- Admin-on-Apple-TV in general (the `Shared/Screens/Admin/` area). The product owner wants to think about it — **separate project**. This design only puts the Seerr configuration on tvOS.

## Anti-goals (would be a failure even if it works)

- A screen that waits for Seerr before showing Jellyfin content.
- An owned item that moves or reflows when Seerr's answer arrives — which is why **every** Seerr-only element (cards, counts, action buttons, prompts) sits after the owned content it relates to, never above it.
- Seerr content reaching an age-capped account.
- Seerr branding on browse surfaces; an error banner or empty « Pas encore dans ta bibliothèque » row when Seerr is down.
- The Jellyfin access token or password ever sent to Seerr.
- The Seerr API key stored on the Jellyfin server, synced, or readable by a non-admin.
- A title shown as « Pas encore dans ta bibliothèque » while it is in the library row just above.

## What the user sees

### Search (iOS + tvOS)

Below the library results — also when there are none — a section **« Pas encore dans ta bibliothèque »** with the Seerr matches (movies and series only; people and collections dropped). Skeleton cards while it loads, after the library results are already on screen. Titles present in Jellyfin are removed (see *Who is "in the library"*). A card is a dashed-outline card; its badge says « Demander » or the request state. Tap ⇒ request sheet (iOS) / confirmation (tvOS): title, kind, year, a two-line overview, « Demander ce film » / « Demander la série », and one line saying what happens next (auto-approved: « le téléchargement démarre tout de suite »; otherwise « l'admin doit valider ta demande, tu seras prévenu à son arrivée »). After the request: a toast « Demande envoyée : <titre> », the card flips to its state.

A user who is enabled but not yet connected to Seerr (account mode) sees, in place of the section, one card: « Il te manque un titre ? — Ton serveur utilise Seerr pour les demandes. Connecte-toi une fois avec ton compte Jellyfin : rien à taper. » + « Se connecter à Seerr ». Shown at most in search and in Settings → Demandes; dismissible (« Plus tard » hides it from search for that user on that device).

### Series fiche

Missing seasons = seasons Seerr knows (TMDb) that Jellyfin does not have. A series with none looks exactly like today. Season 0 (specials) is never offered unless Seerr's `enableSpecialEpisodes` is on.

- **iPhone / iPad**: the season `Menu` (`MediaDetailScreen.seasonsSection`) is unchanged and lists the owned seasons only. **After the episode list**, a row « Pas encore dans ta bibliothèque » of dashed season cards (« Saison 4 », « + » or the request state); its header carries « Demander les N ». Skeleton cards in that row while loading. A card opens the season picker with that season checked; the header action opens it with every requestable season checked; « Demander N saisons ». A one-season series (no Menu today) gets the same row.
- **Apple TV**: when the pill row exists (≥ 2 owned seasons), the missing seasons are dashed pills **appended after** the owned pills (skeleton pills while loading); with one owned season (no pill row today), they take the iPhone's row after the episodes instead, so nothing appears above the episodes. Selecting a missing pill or card opens a confirmation: « Demander la saison 4 », « Demander les saisons 4 à 6 » (when several), « Annuler » — no checkbox list, no typing.

### Saga

The TMDb collection id comes from the BoxSet's or the movie's `ProviderIds["TmdbCollection"]`.

- **BoxSet fiche** (`collectionChildren`): the owned grid is unchanged; after it, a section « Pour compléter la saga » with the missing films; its header says « 3 films manquants » and carries « Demander les 3 » (multi-select sheet, all pre-checked; tvOS: a confirmation « Demander les 3 films » / per film from its card).
- **Movie fiche, collection row exists today** (`collectionItems`, a Jellyfin BoxSet with another owned member): the missing films are appended at the row's end.
- **Movie fiche, no row today** (no BoxSet, or this film is the only one owned) but the movie has a `TmdbCollection` id: a new row « Pour compléter la saga <nom> » with the missing films only, placed **at the end of the fiche** (after « Similaires »), so nothing above it moves.

### Actor page

The filmography lists the owned titles first, then a section « Pas encore dans ta bibliothèque » with the rest of the person's TMDb credits (movies + series, cast; crew only if the person is primarily crew — builder's call). No filter control: it would appear above the grid once Seerr answers, and the two sections already separate owned from missing.

### Settings → « Demandes » (new category, iOS + tvOS)

Visible to a Jellyfin admin always, and to any other user once the admin has enabled them. Contents:

- **Mes demandes** — every request of mine, most recently changed first: poster, title (series: « · saisons 4, 5 »), a status line (« En attente de validation », « Approuvée · en cours de téléchargement », « Refusée », « Arrivée dans ta bibliothèque » + « Regarder » opening the fiche). Paged.
- **À valider (N)** — for a user whose Seerr permissions include `MANAGE_REQUESTS` (Seerr's permission, not Jellyfin admin): pending requests with who asked and when, « Approuver » / « Refuser ».
- **Connexion** — « Connecté à Seerr en tant que Léa » / « Se connecter à Seerr », « Se déconnecter ».
- **Configuration** (Jellyfin admin only): Seerr address, « Tester la connexion » + its result, « Qui peut demander · 3 sur 5 » with a switch per Jellyfin user, « Activer pour tous » / « Tout désactiver », and for each user what Seerr knows (« Compte Seerr lié · demandes approuvées automatiquement », « Pas encore de compte Seerr : il sera créé à sa première connexion », « Aucun compte Seerr, et Seerr n'en crée pas tout seul : ajoute-le dans Seerr → Utilisateurs »). Footnote: « Un utilisateur créé plus tard dans Jellyfin devra être activé ici. Ce que chacun a le droit de demander se règle dans Seerr. »
- **Sur cet appareil** (Jellyfin admin only): « Clé d'API (facultatif) ». Explanation: « La clé reste dans le trousseau de cet appareil et n'est jamais envoyée aux autres. Elle donne tous les droits sur Seerr : réserve-la aux appareils de confiance, comme l'Apple TV du salon. Les demandes sont attribuées au profil actif. »

### Arrival message

On launch and on return to the foreground (feature visible, connected): if a request of mine became available since last time, a toast « <Titre> est disponible » + « Regarder » (opens the fiche); several ⇒ « 3 demandes sont disponibles » + « Voir » (opens Mes demandes). The first check on a device seeds the "already seen" set without toasting. No push: Seerr cannot notify a native app.

### Age-capped accounts

An account is capped when the app's ceiling `privacy.maxContentAge` is set on this device (> 0) OR its Jellyfin policy carries a `MaxParentalRating`. A capped account sees **nothing from Seerr anywhere** — no browse surface, no prompt, no Settings → Demandes — and makes no Seerr call, whatever its `seerr.enabled` flag. In the admin's « Qui peut demander » list, a capped user's line reads « Limite d'âge active : les demandes restent masquées » and its switch stays off. **Activation says so explicitly** (product owner, 2026-11-06): tapping that switch shows « Tom n'a pas pu être activé : son compte a une limite d'âge. Retire-la dans Jellyfin pour lui ouvrir les demandes. »; « Activer pour tous » ends with « Activé pour 3 utilisateurs. Tom n'a pas pu être activé : limite d'âge sur son compte. » (several ⇒ the names, counted with `loc.counted`). This covers the server-side cap, which the admin can see; the device-side `privacy.maxContentAge` only affects that device and is not visible from another one. Lifting the cap brings the feature back with no other step.

## Configuration and auth model

### Shared configuration — on the Jellyfin server, per user

Stock Jellyfin has no place that is admin-writable, readable by the target user and hidden from others (research 2026-11-06). The design lives with that:

- Stored in each user's **DisplayPreferences** under a dedicated id and client — `displayPreferencesId` `jellyglass-seerr`, `client` `jellyglass` (≤ 32 chars) — never jellyfin-web's ids (`usersettings` / `emby`). `CustomPrefs`: `seerr.enabled` = `"true"`, `seerr.url` = the address. Nothing secret.
- An admin may write another user's prefs (`?userId=`, enforced by `RequestHelpers.GetUserId`, same on 10.10 / 10.11 / master). **POST is a full replace** of that (user, id, client): always read-modify-write.
- « Activer pour tous » = `GET /Users` then one write per user. Changing the address rewrites every enabled user. No server-wide default.
- A non-admin can write their own prefs, i.e. flip their own `seerr.enabled`. Accepted: that only shows the UI; nothing can be requested without a Seerr identity that Seerr itself authorizes.
- Read at login, account switch, session restore and return to the foreground (next to `AppState.refreshCurrentUser`). No socket event exists for it.

### Account mode (default, recommended) — Quick Connect, no typing

Seerr ≥ 3.4 offers Jellyfin Quick Connect login, and JellyGlass can already approve a Quick Connect code from a signed-in session (`authorizeQuickConnect(code:)`). So « Se connecter à Seerr » is one tap:

1. `POST {seerr}/api/v1/auth/jellyfin/quickconnect/initiate` → `{code, secret}`.
2. JellyGlass approves `code` on **Jellyfin** with the current user's token (the token goes to Jellyfin only).
3. Poll `GET /auth/jellyfin/quickconnect/check?secret=` until `authenticated`.
4. `POST /auth/jellyfin/quickconnect/authenticate {secret}` → Seerr session cookie `connect.sid` (30 days) + the Seerr `User`.

The cookie is stored in the Keychain per **(server, Jellyfin user)** (`ServerRegistry.accountKey(serverId:userId:)`, a new account added to `privateAccounts`) — 2.5.0 ships several accounts per device. On 401 the flow re-runs once silently (the user is still signed in to Jellyfin); if that fails, the « Se connecter à Seerr » state returns. « Se déconnecter » = `POST /auth/logout` + delete the cookie.

**The admin's own Seerr identity.** In account mode, « Tester la connexion » ends by signing the admin in (the same one-tap flow), because the Configuration page needs an identity: the per-user lines (« Compte Seerr lié… ») come from `GET /user/jellyfin/{id}` under the admin's Seerr session. Side effects, stated under the button: Seerr may create the admin's account, and Jellyfin shows a new « Seerr » device session. If the admin's Seerr account cannot list users (the spike measures which permission that route needs), the lines read « Statut Seerr indisponible : ton compte Seerr n'a pas le droit de voir les utilisateurs » and the switches still work.

Preconditions, all checked by « Tester la connexion »: Jellyfin Quick Connect enabled (`GET /QuickConnect/Enabled`); Seerr `mediaServerLogin` true and `mediaServerType` Jellyfin (`/settings/public`); a user unknown to Seerr is auto-created only if Seerr's `newPlexLogin` is true (it governs Jellyfin too, despite the name) — otherwise 403, reported per user in the admin list.

### API-key mode — a per-DEVICE override

There is no server-wide "mode": the key is typed by a Jellyfin admin on a given device (iPhone, iPad or Apple TV) and stays in that device's Keychain, per server. When a key is present on the device, every enabled profile on that device uses it: `X-Api-Key` + `X-API-User: <seerrUserId>`, the Seerr user resolved per active Jellyfin user through `GET /api/v1/user/jellyfin/{jellyfinUserId}` (Seerr ≥ 3.3). No Seerr user for that Jellyfin user ⇒ that profile is "not linked", with the message below. Requests then carry that user's permissions and quota (Seerr re-runs every check as `X-API-User`). The key never leaves the device.

## Seerr facts the build relies on (source-checked 2026-11-06)

- One call per screen: `GET /search?query=` (`mediaType` movie/tv/person/collection, `id` = TMDb, `mediaInfo?`), `GET /tv/{tmdbId}` (`mediaInfo.seasons[].status` — only the detail route carries seasons, list routes don't), `GET /collection/{tmdbCollectionId}` (`parts[]` with `mediaInfo`), `GET /person/{tmdbPersonId}/combined_credits`. Lookup prefixes in search: `tmdb:`, `tvdb:`, `imdb:`.
- `POST /request {mediaType, mediaId, seasons?: [n] | "all"}` → 201; 403 permission/quota/blocklist; 409 duplicate; **202 = "no seasons available", a failure**. `partialRequestsEnabled` false ⇒ send every missing season.
- `GET /request?take&skip&filter&sort=modified&requestedBy=` (users without `MANAGE_REQUESTS`/`REQUEST_VIEW` are forced to their own); `POST /request/{id}/approve|decline` (`MANAGE_REQUESTS`, 409 if not pending); `GET /request/count`.
- `GET /auth/me` → `permissions` bitmask (`ADMIN` 2 passes everything; `MANAGE_REQUESTS` 16, `REQUEST` 32, `AUTO_APPROVE` 128, `REQUEST_MOVIE` 262144, `REQUEST_TV` 524288 …).
- Enums — **code, not the YAML spec** (they disagree): `MediaStatus` 1 unknown, 2 pending, 3 processing, 4 partially available, 5 available, 6 blocklisted (« blacklisted » ≤ 2.7), 7 deleted; `MediaRequestStatus` 1 pending, 2 approved, 3 declined, 4 failed, 5 completed.
- Unauthenticated probes: `GET /status` (`version`), `GET /settings/public` (`mediaServerType`, `mediaServerLogin`, `newPlexLogin`, `jellyfinServerName`, `partialRequestsEnabled`, `enableSpecialEpisodes`, …).
- Images: TMDb paths, `https://image.tmdb.org/t/p/w300{path}` — irrelevant to the dashed look, used only in the request sheet and Mes demandes. `/imageproxy/tmdb/t/p/{size}{path}` exists when `cacheImages` is on.
- Traps: when Seerr's CSRF protection is on, every non-GET needs the `XSRF-TOKEN` cookie echoed in `X-XSRF-TOKEN`, API key included, HTTPS only; `express-openapi-validator` may 400 on query parameters not in the spec — send only listed ones; error bodies are `{message}` or `{error}`.

## Who is "in the library"

**Jellyfin wins.** A Seerr result is dropped from the missing set when Jellyfin has it, matched by TMDb id (`ProviderIds["Tmdb"]`); Seerr's `mediaInfo.status` ≥ 4 drops it too (TVDB/IMDb-only items). Seasons: missing = TMDb season numbers − the season `IndexNumber`s the fiche already loaded. Seerr status then only decides the badge of what is missing (none ⇒ « Demander », pending ⇒ « En attente », approved/processing ⇒ « En préparation », declined ⇒ « Refusée »). This needs `ProviderIds` on three queries that lack it today — the search results, the BoxSet members, the person's items — requested **only when the feature is visible**. The fiche's `getItem` already returns them.

## Test connection — order and messages (FR, explicit: what + how to fix)

Run in this order, stop at the first error; success lists what was verified (« Seerr 3.5.1 », « Relié à ton serveur Jellyfin « Maison » », « Connexion en un geste disponible », « Ton compte Seerr : admin, demandes approuvées automatiquement »).

| Check | Message |
|---|---|
| No answer | « Seerr ne répond pas à cette adresse. » Vérifie l'adresse et le port (5055 par défaut), et que Seerr est bien démarré. Depuis l'extérieur de chez toi, il faut l'adresse publique de Seerr. |
| Answer, not Seerr | « Cette adresse ne mène pas à Seerr. » Un serveur répond, mais ce n'est pas Seerr. C'est souvent le port : celui de Jellyfin est 8096, celui de Seerr 5055. |
| Version < 3.4 | « Seerr <v> est trop ancien. » JellyGlass a besoin de Seerr 3.4 ou plus récent. Mets Seerr à jour. |
| Not Jellyfin-backed | « Ce Seerr n'est pas relié à Jellyfin. » |
| Other Jellyfin (`jellyfinServerName` ≠ this server's name) | **Warning, not blocking**: « Ce Seerr semble relié à un autre serveur Jellyfin (« X »). Les demandes arriveraient sur ce serveur-là. » |
| `mediaServerLogin` off (account mode) | « Seerr refuse les comptes Jellyfin. » Active-la dans Seerr → Réglages → Utilisateurs → « Connexion Jellyfin ». |
| Jellyfin Quick Connect off (account mode) | « La connexion en un geste est désactivée sur ton serveur Jellyfin. » Active Quick Connect dans Jellyfin → Tableau de bord → Général. |
| Key refused (key mode) | « Seerr refuse cette clé d'API. » Elle a peut-être été régénérée. Copie-la de nouveau depuis Seerr → Réglages → Général → Clé d'API. |
| No Seerr user for this Jellyfin user | « Ton compte n'existe pas dans Seerr. » Ajoute-le dans Seerr → Utilisateurs, ou active la création automatique des comptes. |
| CSRF blocks the request | « Seerr bloque les demandes venant d'une app. » La protection CSRF est activée dans Seerr → Réglages → Réseau : désactive-la. (No degraded read-only mode — see calls.) |

The same messages are reused wherever a request fails for that reason. Elsewhere (browse surfaces) Seerr failures are **silent**: the Seerr parts simply don't appear.

## Constraints

- Pro gate: a new `ProFeatureID` case (`ProFeatureGate.allows` is an exhaustive switch) + its `ProFeatureCatalogue` entry (it appears on the Pro page). After the paid launch a free user sees **nothing on the browse surfaces and makes no Seerr call** (the « Reprendre ici » precedent: the gate sits before any fetch); Settings → Demandes stays visible with a lock → `ProUpsellSheet` (the 2026-10-22 gate-site pattern). Requesting never touches playback.
- Settings category lives under `Shared/Screens/Settings/`, **not** `Shared/Screens/Admin/` (all `#if os(iOS)`); it must not be `isAdminOnly` (that drops it on tvOS) — admin-only rows are gated inside the page.
- New CinemaxKit client with its own ephemeral `URLSession` (`urlCache = nil`, no shared `HTTPCookieStorage` — the cookie is set by hand from the Keychain). Never route Seerr through the Jellyfin SDK client. `Accept-Language` from the app language (Seerr localizes titles/overviews).
- ATS: plain HTTP only on the local network (`NSAllowsLocalNetworking`), like Jellyfin; a public Seerr must be HTTPS.
- Every new `ServerEntry` field optional (else the registry decodes as `[]`); Seerr data goes in its own Keychain accounts / DisplayPreferences, not `ServerEntry`, unless the builder needs a local cache.
- Localization FR / EN / DE; counts through `loc.counted`. tvOS: no text entry except the admin's address and key fields.
- Swift 6 strict concurrency, `@Observable @MainActor` VMs, pure policies unit-tested (swift-testing), nothing sleeps in tests. New files ⇒ `xcodegen generate`.
- Rules: a new area file (`CLAUDE.md` next to the new code, excluded from the bundle per the root rule) + a row in the root table.

## Delivery

0. **Spike (throwaway, before lot 1)** against a local Seerr 3.4+ in Docker linked to the bench Jellyfin (`jf-bench`), never the household's real accounts: Quick Connect self-approval end to end; CSRF on/off with an API key and with a cookie; `X-API-User` attribution; `/user/jellyfin/{id}` and the permission it needs. Findings feed back into this document before lot 1. **The spike is a gate**: if account mode cannot sign a user in without typing, lots 1–3 are not planned and the product owner decides (key-only v1, a password form after all, or stop).
1. **Lot 1 — base**: CinemaxKit Seerr client + models + pure policies; Settings → Demandes (configuration, test, per-user switches, device key, connect / disconnect); DisplayPreferences read/write; the search section; the Pro feature id.
2. **Lot 2 — fiches**: series seasons, saga (BoxSet fiche + movie collection row), actor page.
3. **Lot 3 — follow-up**: Mes demandes, À valider, the arrival message.

Each lot is its own PR, mergeable and shippable alone. Release timing: the product owner's call.

## Left to the builder

Type and file names; caching (in-memory per (server, user), short TTL, invalidated by a request); paging sizes; the exact skeleton counts; how the dashed outline is drawn per platform within the design system (accent stays for the « Demander » badge; dashed stroke on `onSurfaceMuted`); tvOS focus treatment of a dashed card (must keep the standard `CinemaTVCardButtonStyle` focus); crew vs cast on the actor page; the debounce of the Seerr search (reuse the search screen's).

## Calls made by Claude (not discussed — check these)

1. **The API key is a per-device override, not a server-wide mode.** The mockup's settings screen shows a « Compte de chacun / Clé d'API » toggle; the document replaces it with a « Sur cet appareil : clé d'API (facultatif) » section, because a server-wide key mode would have to distribute the key through Jellyfin, where any user can read it.
2. **Seerr 3.4 minimum** (Quick Connect). Older Seerr ⇒ the test fails with the version message, even in key mode — one floor, one message.
3. **No password form** when Quick Connect is off: the test explains how to turn it on.
4. **No degraded read-only mode** when Seerr's CSRF protection blocks requests: treated as an error with its fix.
5. **"Other Jellyfin" is a warning, not an error** (server names can differ legitimately).
6. **Jellyfin wins on "in the library"**, at the cost of asking `ProviderIds` on three queries when the feature is visible.
7. **Partially available seasons count as present** (Jellyfin has them); requesting the missing episodes of a season is out of v1.
8. **Missing films also appear on a movie fiche**: appended to its collection row when it exists, else as a new row at the end of the fiche (from the movie's `TmdbCollection` id).
9. The not-connected prompt in search is **dismissible** (« Plus tard »).
10. Settings → Demandes is visible to a non-admin **only once enabled**; to a Jellyfin admin always.
11. « À valider » follows **Seerr's `MANAGE_REQUESTS`**, not the Jellyfin admin flag.
12. The spike runs against a **local Docker Seerr + `jf-bench`**, never the household's accounts — and it is a **gate** (failure ⇒ back to the product owner).
13. **Every Seerr-only control sits after the owned content** (from the owner's « sinon ça peut décaler des items »): the mockup's « Il te manque N saisons » card above the episodes, the saga's « 5 films sur 8 » header and the actor-page filter are gone; their counts and « Demander les N » moved into the header of the missing section.
14. **Apple TV, one owned season**: missing seasons go in the row after the episodes (no pill row exists to append to).
15. « Tester la connexion » in account mode **signs the admin in**, with its side effects stated.
16. **Free user after the paid launch**: nothing on browse surfaces, no Seerr call; locked Settings category.
17. **Age cap** = the app's `privacy.maxContentAge` on the device OR the Jellyfin `MaxParentalRating` policy.

## References

- Mockup: https://claude.ai/artifact/CdTACXqkDVUzG81M9S3eXH (local source `.superpowers/brainstorm/seerr/index.html`, gitignored).
- GitHub #173 (original proposal).
- Jellyfin: `Jellyfin.Api/Helpers/RequestHelpers.cs` (`GetUserId`), `Controllers/DisplayPreferencesController.cs`, `Jellyfin.Server.Implementations/Users/DisplayPreferencesManager.cs` (replace semantics).
- Seerr (`seerr-team/seerr` `develop`): `server/routes/auth.ts` (Jellyfin + Quick Connect login), `server/middleware/auth.ts` (`X-Api-Key`, `X-API-User`), `server/lib/permissions.ts`, `server/constants/media.ts`, `server/routes/request.ts`, `server/routes/{search,collection,person}.ts`, `seerr-api.yml`.
- App: `AppState.refreshCurrentUser`, `JellyfinAPIClient.authorizeQuickConnect(code:)`, `MediaDetailViewModel.loadCollection` / BoxSet children, `SettingsScreen.visibleCases`, `ProFeatureGate.allows`, `ServerRegistry.accountKey(serverId:userId:)`, `KeychainService.privateAccounts`.
