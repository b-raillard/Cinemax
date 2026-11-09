# Seerr requests — ask for a missing title from inside JellyGlass (2026-11-06)

Decided with the product owner on 2026-11-06, in conversation and on the interactive mockup [« Seerr dans JellyGlass »](https://claude.ai/artifact/CdTACXqkDVUzG81M9S3eXH) (choices recorded in its database). Supersedes the proposal of GitHub #173. Memory `project_jellyseerr_pro_feature` (« ne pas la construire avant le Pro ») is lifted: the Pro is in production since 2.5.0, everyone is a founder until the paid launch.

"Seerr" = the merged successor of Jellyseerr + Overseerr (github.com/seerr-team/seerr, v3.5.1 on 2026-10-21).

## Intent

The household's server runs Seerr next to Jellyfin. Today, wanting a title that is not on the server means leaving for another app. The product owner's bar: **it must feel built in, never bolted on.** JellyGlass knows what is missing at the place you already are — a search, a series whose next seasons are absent, a saga with holes, an actor's filmography — and lets you ask for it there, in one gesture, with no typing (Apple TV included).

## Decisions (product owner)

| Question | Answer |
|---|---|
| Where requesting happens | Search results, series fiche (missing seasons), saga, actor page. Plus follow-up and admin approval. |
| Look of a missing title | **Dashed outline**, title inside (mockup option C) — over Seerr's poster, dimmed under a 62 % `surfaceContainerLowest` veil (owner, 2026-11-08, variant A); no poster ⇒ the outline alone. Season cards keep the bare outline. |
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
- JellyGlass sending the Jellyfin access token or password to Seerr. (Seerr does end up with its OWN Jellyfin session for the user — that is what Quick Connect login is, exactly as on Seerr's web page — see *Trust*.)
- The Seerr API key stored on the Jellyfin server, synced, or readable by a non-admin.
- A title shown as « Pas encore dans ta bibliothèque » while it is in the library row just above.

## What the user sees

### Search (iOS + tvOS)

Below the library results — also when there are none — a section **« Pas encore dans ta bibliothèque »** with the Seerr matches (movies and series only; people and collections dropped). Skeleton cards while it loads, after the library results are already on screen. Titles present in Jellyfin are removed (see *Who is "in the library"*). A card is a dashed-outline card; its badge says « Demander » or the request state. Tap ⇒ request sheet (iOS) / confirmation (tvOS): title, kind, year, a two-line overview, « Demander ce film » / « Demander la série », and one line saying what happens next (auto-approved: « le téléchargement démarre tout de suite »; otherwise « l'admin doit d'abord valider ta demande. On te prévient dès qu'elle arrive. »). After the request: a toast « Demande envoyée : <titre> », the card flips to its state.

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

On launch and on return to the foreground (feature visible, connected): if a request of mine became available since last time, a toast « <Titre> est disponible » + « Regarder » (opens the fiche); several ⇒ « 3 demandes sont disponibles » + « Voir » (opens Mes demandes). The first check on a device seeds the "already seen" set without toasting. No push: Seerr cannot notify a native app. **Apple TV**: the toast window takes no input (`Shared/DesignSystem/CLAUDE.md`), so the tvOS toast carries no « Regarder » / « Voir » — it informs, and the arrived title waits at the top of Mes demandes with its « Regarder ».

### Age-capped accounts

An account is capped when the app's ceiling `privacy.maxContentAge` is set on this device (> 0) OR its Jellyfin policy carries a `MaxParentalRating`. A capped account sees **nothing from Seerr anywhere** — no browse surface, no prompt, no Settings → Demandes — and makes no Seerr call, whatever its `seerr.enabled` flag. In the admin's « Qui peut demander » list, a capped user's line reads « Limite d'âge active : les demandes restent masquées » and its switch stays off. **Activation says so explicitly** (product owner, 2026-11-06): tapping that switch shows « Tom n'a pas pu être activé : son compte a une limite d'âge. Retire-la dans Jellyfin pour lui ouvrir les demandes. »; « Activer pour tous » ends with « Activé pour 3 utilisateurs. Tom n'a pas pu être activé : limite d'âge sur son compte. » (several ⇒ the names, counted with `loc.counted`). This covers the server-side cap, which the admin can see; the device-side `privacy.maxContentAge` only affects that device and is not visible from another one. Lifting the cap brings the feature back with no other step.

## Configuration and auth model

### Shared configuration — on the Jellyfin server, per user

Stock Jellyfin has no place that is admin-writable, readable by the target user and hidden from others (research 2026-11-06). The design lives with that:

- Stored in each user's **DisplayPreferences** under a dedicated id and client — `displayPreferencesId` `jellyglass-seerr`, `client` `jellyglass` (≤ 32 chars) — never jellyfin-web's ids (`usersettings` / `emby`). `CustomPrefs`: `seerr.enabled` = `"true"`, `seerr.url` = the address. Nothing secret.
- An admin may write another user's prefs (`?userId=`, enforced by `RequestHelpers.GetUserId`, same on 10.10 / 10.11 / master). **POST is a full replace** of that (user, id, client): always read-modify-write.
- « Activer pour tous » = `GET /Users` then one write per user. Changing the address rewrites every enabled user. No server-wide default. The admin's own prefs keep `seerr.url` whatever their flag, so « Tout désactiver » does not lose the address.
- A non-admin can write their own prefs, i.e. flip their own `seerr.enabled`. Accepted: that only shows the UI; nothing can be requested without a Seerr identity that Seerr itself authorizes.
- Read at login, account switch, session restore and return to the foreground (next to `AppState.refreshCurrentUser`). No socket event exists for it.

### Account mode (default, recommended) — Quick Connect, no typing

Seerr ≥ 3.4 offers Jellyfin Quick Connect login, and JellyGlass can already approve a Quick Connect code from a signed-in session (`authorizeQuickConnect(code:)`). So « Se connecter à Seerr » is one tap:

1. `POST {seerr}/api/v1/auth/jellyfin/quickconnect/initiate` → `{code, secret}`.
2. JellyGlass approves `code` on **Jellyfin** with the current user's token (the token goes to Jellyfin only).
3. Poll `GET /auth/jellyfin/quickconnect/check?secret=` until `authenticated`.
4. `POST /auth/jellyfin/quickconnect/authenticate {secret}` → Seerr session cookie `connect.sid` (30 days) + the Seerr `User`.

The cookies are stored as **one** non-synchronizable Keychain JSON item (`seerr_sessions`, the `trusted_certificates` pattern — `privateAccounts` is a static migration list, not a per-key registry), keyed by `ServerRegistry.accountKey(serverId:userId:)` — 2.5.0 ships several accounts per device. When a call answers 403 and `GET /auth/me` answers 403 too (a dead session — Seerr never sends 401 for one, see the spike), the flow re-runs once silently (the user is still signed in to Jellyfin), only against the configured `seerr.url`; if that fails, the « Se connecter à Seerr » state returns.

**Trust.** Approving a code mints a Jellyfin session for whoever holds the matching secret: Seerr keeps it (`user.jellyfinAuthToken`, `server/routes/auth.ts`). JellyGlass therefore trusts the configured Seerr address exactly as it trusts the Jellyfin server — the admin chose it. Jellyfin can refuse the approval (`SessionManager.AuthenticateNewSessionInternal`: the user's device restriction `CanAccessDevice`, or `MaxActiveSessions` reached); each refusal has its own message below. « Se déconnecter » = `POST /auth/logout` + delete the cookie.

**The admin's own Seerr identity.** In account mode, « Tester la connexion » ends by signing the admin in (the same one-tap flow), because the Configuration page needs an identity: the per-user lines (« Compte Seerr lié… ») come from `GET /user/jellyfin/{id}`, which any signed-in Seerr account may call (`isAuthenticated()` only; the filtered user keeps `id`, `permissions`, `jellyfinUserId`). Side effects, stated under the button: Seerr may create the admin's account, and Jellyfin shows a new « Seerr » device session. A Jellyfin admin auto-created in Seerr gets Seerr's `defaultPermissions`, usually without `MANAGE_REQUESTS`: the test result then says « Ton compte Seerr ne peut pas valider les demandes : donne-lui le droit « Gérer les demandes » dans Seerr. »

Preconditions, all checked by « Tester la connexion »: Jellyfin Quick Connect enabled (`GET /QuickConnect/Enabled`); Seerr `mediaServerType` = Jellyfin (`2`, `/settings/public`) — the Quick Connect routes check that and NOT `mediaServerLogin`, which gates only the password route; a user unknown to Seerr is auto-created only if Seerr's `newPlexLogin` is true (it governs Jellyfin too, despite the name) — otherwise 403, reported per user in the admin list.

### API-key mode — a per-DEVICE override

There is no server-wide "mode": the key is typed by a Jellyfin admin on a given device (iPhone, iPad or Apple TV) and stays in that device's Keychain, per server. When a key is present on the device, every enabled profile on that device uses it: `X-Api-Key` + `X-API-User: <seerrUserId>`. **Fail closed**: without `X-API-User` Seerr acts as user 1, its admin (`server/middleware/auth.ts`), so every call except `/status`, `/settings/public` and `/user/jellyfin/{id}` carries it, and the client cannot build a request or mutation without a resolved id (by type, not by convention). The Seerr user is resolved per active Jellyfin user through `GET /api/v1/user/jellyfin/{jellyfinUserId}` (Seerr ≥ 3.3). No Seerr user for that Jellyfin user ⇒ that profile is "not linked", with the message below. Requests then carry that user's permissions and quota (Seerr re-runs every check as `X-API-User`). The key never leaves the device.

## Seerr facts the build relies on (source-checked 2026-11-06)

- One call per screen: `GET /search?query=` (`mediaType` movie/tv/person/collection, `id` = TMDb, `mediaInfo?`), `GET /tv/{tmdbId}` (TMDb `seasons[]` + `mediaInfo.seasons[].status`), `GET /collection/{tmdbCollectionId}` (`parts[]` with `mediaInfo`), `GET /person/{tmdbPersonId}/combined_credits`. Lookup prefixes in search: `tmdb:`, `tvdb:`, `imdb:`. **Language goes in the `language=` query parameter** of those four routes (`req.query.language ?? req.locale`), not in `Accept-Language`.
- `POST /request {mediaType, mediaId, seasons?: [n] | "all"}` → 201; 403 permission/quota/blocklist; 409 duplicate; **202 = "no seasons available", a failure**. `partialRequestsEnabled` false ⇒ send every missing season.
- `GET /request?take&skip&filter&sort=modified&requestedBy=` (users without `MANAGE_REQUESTS`/`REQUEST_VIEW` are forced to their own); `POST /request/{id}/approve|decline` (`MANAGE_REQUESTS`, 409 if not pending); `GET /request/count`.
- `GET /auth/me` → `permissions` bitmask (`ADMIN` 2 passes everything; `MANAGE_REQUESTS` 16, `REQUEST` 32, `AUTO_APPROVE` 128, `REQUEST_MOVIE` 262144, `REQUEST_TV` 524288 …).
- Enums — **code, not the YAML spec** (they disagree): `MediaStatus` 1 unknown, 2 pending, 3 processing, 4 partially available, 5 available, 6 blocklisted (« blacklisted » ≤ 2.7), 7 deleted; `MediaRequestStatus` 1 pending, 2 approved, 3 declined, 4 failed, 5 completed.
- Unauthenticated probes: `GET /status` (`version`), `GET /settings/public` (`mediaServerType`, `mediaServerLogin`, `newPlexLogin`, `jellyfinServerName`, `partialRequestsEnabled`, `enableSpecialEpisodes`, …).
- Images: TMDb paths, `https://image.tmdb.org/t/p/w300{path}` — used by the request sheet, Mes demandes and, dimmed, the missing-title cards (`SeerrSession.posterURL`). When `cacheImages` is on, use Seerr's unauthenticated `/imageproxy/tmdb/t/p/{size}{path}` instead (no device → TMDb traffic).
- Traps: when Seerr's CSRF protection is on, every non-GET needs the `_csrf` cookie and the `XSRF-TOKEN` value echoed in `X-XSRF-TOKEN`, API key included (see the spike: handled by the client, not an error); `express-openapi-validator` 400s on query parameters not in the spec — send only listed ones; error bodies are `{message}` or `{error}`.

## Spike findings (2026-11-07, Seerr 3.5.1 against Jellyfin 10.11.0 AND 12.0.0, throwaway Docker bench)

**The gate passed**: a user signed in to JellyGlass gets a Seerr session with no typing — Seerr `initiate` → JellyGlass `POST /QuickConnect/Authorize?code=` with the user's own token → `check` = `authenticated` → `authenticate` → `connect.sid` (Max-Age 30 days) + the Seerr user, auto-created with `defaultPermissions` (32 = `REQUEST` on a fresh Seerr). Same result on both Jellyfin generations. What the build must do differently from the sections above:

1. **CSRF is not an error for a native client.** The `Secure` flag of Seerr's CSRF cookies only binds browsers. Any GET (`/status`) returns `_csrf` + `XSRF-TOKEN`; echoing `Cookie: _csrf=…` + `X-XSRF-TOKEN: …` by hand makes every mutation pass over plain HTTP, key and cookie modes, and the pair is reusable. The client keeps the pair in memory, attaches it to every non-GET (Quick Connect `initiate` / `authenticate` and `logout` included), and on `403 {"message":"invalid csrf token"}` refreshes it with `GET /status` and retries once. The CSRF row of the test table and call #4 are gone.
2. **A dead session and a refused key both answer `403 {"error":"You do not have permission to access this endpoint"}`** — the same body as a genuine permission refusal; only a MISSING cookie is a 401. So the re-sign-in trigger is: a 403 on any call ⇒ probe `GET /auth/me` (account mode) — 403 there ⇒ the session is dead ⇒ the silent re-sign-in (once); 200 ⇒ a real refusal. Key mode: probe `GET /user/jellyfin/{jellyfinUserId}` without `X-API-User` — 403 ⇒ « Seerr refuse cette clé d'API », 404 ⇒ not linked, 200 ⇒ a real refusal (and a fresh Seerr id).
3. **Jellyfin refuses at JellyGlass's own `Authorize` call, with an identical `403` for the device restriction and the session limit** (server log: « User is not allowed access from this device » / « User is at their maximum number of sessions »). JellyGlass picks the message from the user's own policy (`/Users/Me`, readable by the user): `EnableAllDevices == false` ⇒ the device message, else `MaxActiveSessions > 0` ⇒ the session-limit message, else « Jellyfin a refusé la connexion de Seerr à ton compte. » Seerr's Quick Connect session always carries device id `BOT_seerr` and name « Seerr ».
4. **« Other Jellyfin » is detected exactly, and blocks** (call #5 revised): a code issued by a Seerr linked to ANOTHER Jellyfin is unknown to ours, so `Authorize` answers **404**; in key mode `GET /settings/jellyfin` (the key is Seerr's admin) returns `serverId`, compared with this server's id. `/settings/public` carries **no** `jellyfinServerName` in 3.5.1. Never log the `/settings/jellyfin` body: it carries Seerr's own Jellyfin API key.
5. `GET /tv/{id}`: `seasons[]` includes season 0; `mediaInfo.seasons[]` stays **empty** while a season is only requested — a season's badge comes from `mediaInfo.requests[].seasons[].seasonNumber` + that request's `status`, availability from `mediaInfo.seasons[].status`.
6. `GET /request` items carry **no title** — only `media.tmdbId`, `media.status`, `media.jellyfinMediaId` (set once available) and the request fields. Mes demandes loads each row's title and poster with `/movie/{id}` or `/tv/{id}`; an available request opens the fiche from `jellyfinMediaId`. `GET /request/count` is **global** (every user's requests, even for a `REQUEST`-only user): never shown; « À valider (N) » = `GET /request?filter=pending&take=1` → `pageInfo.results`. Passing `requestedBy=<someone else>` as a non-manager is a 403, not a silent filter; passing one's OWN id works for every account (checked 2026-11-07) — and is required: without it a manager's list holds the whole household's requests, so Mes demandes and the arrival check always pass the own id, À valider never does.
7. A user unknown to Seerr while `newPlexLogin` is off gets `403 {"message":"Access denied."}` at `authenticate` — AFTER JellyGlass approved, so Jellyfin has already minted Seerr's session for them (a stray « Seerr » device, as with Seerr's own web page). `mediaServerLogin` off does not block Quick Connect (confirmed). Logging in again does not pile up Jellyfin sessions (one « Seerr » session per user). `POST /auth/logout` → `{"status":"ok"}`, and Seerr's Jellyfin session stays — JellyGlass does not revoke it.
8. DisplayPreferences: admin `POST …?userId=` → 204 on 10.11 and 12.0, the user reads it, a non-admin reading or writing someone else's → 403. Jellyfin injects six legacy keys into the `CustomPrefs` of EVERY entity (`chromecastVersion`, `skipForwardLength`, `skipBackLength`, `enableNextVideoInfoOverlay`, `tvhome`, `dashboardTheme`) and resets them when a POST omits them — scoped to our (user, `jellyglass-seerr`, `jellyglass`) entity, so harmless, but read-modify-write round-trips the whole dictionary.
9. Requests are created even when Seerr has no Radarr / Sonarr; `/person/{id}` carries `knownForDepartment` (« Acting ») — crew credits are listed only when it is not « Acting »; `/person/{id}/combined_credits` entries carry `mediaInfo` when Seerr knows the title; `language=` localizes, `Accept-Language` does not (confirmed).

## Who is "in the library"

**Jellyfin wins.** A Seerr result is dropped from the missing set when Jellyfin has it, matched by TMDb id (`ProviderIds["Tmdb"]`); Seerr's `mediaInfo.status` ∈ {4 partially available, 5 available, 6 blocklisted} drops it too (TVDB/IMDb-only items) — never 7 « deleted », which is precisely a missing title. Seasons: missing = TMDb season numbers − the season `IndexNumber`s the fiche already loaded. Seerr status then only decides the badge of what is missing (none ⇒ « Demander », pending ⇒ « En attente », approved/processing ⇒ « En préparation », declined ⇒ « Refusée »). This needs `ProviderIds` on three queries that lack it today — the search results, the BoxSet members, the person's items — requested **only when the feature is visible**. The fiche's `getItem` already returns them.

## Test connection — order and messages (FR, explicit: what + how to fix)

Run in this order, stop at the first error; success lists what was verified (« Seerr 3.5.1 », « Relié à ton serveur Jellyfin « Maison » », « Connexion Quick Connect disponible », « Ton compte Seerr : admin, demandes approuvées automatiquement »).

| Check | Message |
|---|---|
| No answer | « Seerr ne répond pas à cette adresse. » Vérifie l'adresse et le port (5055 par défaut), et que Seerr est bien démarré. Depuis l'extérieur de chez toi, il faut l'adresse publique de Seerr. |
| Answer, not Seerr | « Cette adresse ne mène pas à Seerr. » Un serveur répond, mais ce n'est pas Seerr. C'est souvent le port : celui de Jellyfin est 8096, celui de Seerr 5055. |
| Version < 3.4 | « Seerr <v> est trop ancien. » JellyGlass a besoin de Seerr 3.4 ou plus récent. Mets Seerr à jour. |
| Not Jellyfin-backed | « Ce Seerr n'est pas relié à Jellyfin. » |
| Other Jellyfin (account mode: `Authorize` → 404; key mode: `/settings/jellyfin` `serverId` ≠ this server's id) | « Ce Seerr est relié à un autre serveur Jellyfin. » Les demandes arriveraient sur cet autre serveur. Vérifie l'adresse de Seerr, ou son serveur dans Seerr → Réglages → Jellyfin. |
| Jellyfin Quick Connect off (account mode) | « La connexion Quick Connect est désactivée sur ton serveur Jellyfin. » Active Quick Connect dans Jellyfin → Tableau de bord → Général. |
| Jellyfin refuses the approval, policy `EnableAllDevices` off | « Ton compte Jellyfin n'est pas autorisé sur un nouvel appareil. » Dans Jellyfin → Utilisateurs → <toi> → Accès, autorise tous les appareils, ou ajoute « Seerr ». |
| Jellyfin refuses the approval, policy `MaxActiveSessions` > 0 | « Ton compte Jellyfin a atteint son nombre maximal de sessions. » Déconnecte un appareil dans Réglages → Confidentialité → Appareils connectés, ou augmente la limite dans Jellyfin. |
| Jellyfin refuses the approval, neither | « Jellyfin a refusé la connexion de Seerr à ton compte. » Réessaie ; si ça recommence, regarde le journal de Jellyfin. |
| Key refused (key mode) | « Seerr refuse cette clé d'API. » Elle a peut-être été régénérée. Copie-la de nouveau depuis Seerr → Réglages → Général → Clé d'API. |
| No Seerr user for this Jellyfin user | « Ton compte n'existe pas dans Seerr. » Ajoute-le dans Seerr → Utilisateurs, ou active la création automatique des comptes. |

The same messages are reused wherever a request fails for that reason. Elsewhere (browse surfaces) Seerr failures are **silent**: the Seerr parts simply don't appear.

## Constraints

- Pro gate: a new `ProFeatureID` case (`ProFeatureGate.allows` is an exhaustive switch) + its `ProFeatureCatalogue` entry (it appears on the Pro page). After the paid launch a free user sees **nothing on the browse surfaces and makes no Seerr call** (the « Reprendre ici » precedent: the gate sits before any fetch); Settings → Demandes stays visible with a lock → `ProUpsellSheet` (the 2026-10-22 gate-site pattern). Requesting never touches playback.
- Settings category lives under `Shared/Screens/Settings/`, **not** `Shared/Screens/Admin/` (all `#if os(iOS)`); it must not be `isAdminOnly` (that drops it on tvOS) — admin-only rows are gated inside the page. `SettingsCategory.visibleCases` gains the « enabled / admin » input it needs, and its comment saying tvOS never renders admin entries (`SettingsScreen.swift` ~L101, `SettingsScreen+tvOS.swift` passes `isAdmin: false`) is revised: this category's admin rows are a deliberate exception.
- New CinemaxKit client with its own ephemeral `URLSession` (`urlCache = nil`, no shared `HTTPCookieStorage` — the cookie is set by hand from the Keychain). Never route Seerr through the Jellyfin SDK client. App language sent as `language=` (see Seerr facts).
- **URLs**: every Seerr URL goes through `setEndpointPath(_:preservingBasePathOf:)` (root RULE — Seerr behind `https://host/seerr` must work); the typed address is normalized like `ServerURLNormalizer` (scheme, trailing slash, a pasted `/api/v1` stripped).
- **Secrets never logged**: the Seerr client logs no headers, cookies or Quick Connect secret; lot 1 adds `X-Api-Key:`, `connect.sid=` and `secret=` to `LogScrubber.tokenMarkers` so an exported diagnostic cannot carry them.
- **Stale answers**: every Seerr task is keyed by (server, Jellyfin user) and generation-guarded like the screens' existing loads (`MediaDetailViewModel.loadGeneration`, `SearchViewModel`'s cancel, `AppState.switchAccount`); age cap, Pro and `seerr.enabled` are re-read at render, not only before the fetch — a late answer must never paint on the next profile's screen (a child's, typically).
- **Offline / slow**: `NetworkMonitor.isOnline` false ⇒ no call and no skeleton; a skeleton has a deadline (builder: a few seconds) after which it silently disappears; tvOS skeletons are not focusable.
- **Siri / widgets / Top Shelf**: untouched — Seerr matching stays out of `LibrarySearchRanker` (shared with `MediaItemQuery`).
- ATS: plain HTTP only on the local network (`NSAllowsLocalNetworking`), like Jellyfin; a public Seerr must be HTTPS.
- Every new `ServerEntry` field optional (else the registry decodes as `[]`); Seerr data goes in its own Keychain accounts / DisplayPreferences, not `ServerEntry`, unless the builder needs a local cache.
- Localization FR / EN / DE; counts through `loc.counted`. tvOS: no text entry except the admin's address and key fields.
- Swift 6 strict concurrency, `@Observable @MainActor` VMs, pure policies unit-tested (swift-testing), nothing sleeps in tests. New files ⇒ `xcodegen generate`.
- Rules: a new area file (`CLAUDE.md` next to the new code, excluded from the bundle per the root rule) + a row in the root table.

## Delivery

0. **Spike (throwaway, before lot 1)** against a local Seerr 3.4+ in Docker linked to the bench Jellyfin (`jf-bench`), never the household's real accounts: Quick Connect self-approval end to end; CSRF on/off with an API key and with a cookie; `X-API-User` attribution; `/user/jellyfin/{id}` (confirm: any signed-in account); Quick Connect login with `mediaServerLogin` OFF; CSRF on over plain HTTP; Jellyfin's device-restriction and session-limit refusals; the `defaultPermissions` of an auto-created admin. Findings feed back into this document before lot 1. **The spike is a gate**: if account mode cannot sign a user in without typing, lots 1–3 are not planned and the product owner decides (key-only v1, a password form after all, or stop).
1. **Lot 1 — base**, possibly split by the plan: **1a** CinemaxKit Seerr client + models + pure policies + Settings → Demandes (configuration, test, per-user switches, device key, connect / disconnect) + DisplayPreferences read/write + the Pro feature id + LogScrubber markers; **1b** the search section.
2. **Lot 2 — fiches**: series seasons, saga (BoxSet fiche + movie collection row), actor page.
3. **Lot 3 — follow-up**: Mes demandes, À valider, the arrival message.

Each lot is its own PR, mergeable and shippable alone. Release timing: the product owner's call.

## Left to the builder

Type and file names; caching (in-memory per (server, user), short TTL, invalidated by a request); paging sizes; the exact skeleton counts; how the dashed outline is drawn per platform within the design system (accent stays for the « Demander » badge; dashed stroke on `onSurfaceMuted`); tvOS focus treatment of a dashed card (must keep the standard `CinemaTVCardButtonStyle` focus); crew vs cast on the actor page; the debounce of the Seerr search (reuse the search screen's).

## Calls made by Claude (not discussed — check these)

1. **The API key is a per-device override, not a server-wide mode.** The mockup's settings screen shows a « Compte de chacun / Clé d'API » toggle; the document replaces it with a « Sur cet appareil : clé d'API (facultatif) » section, because a server-wide key mode would have to distribute the key through Jellyfin, where any user can read it.
2. **Seerr 3.4 minimum** (Quick Connect). Older Seerr ⇒ the test fails with the version message, even in key mode — one floor, one message.
3. **No password form** when Quick Connect is off: the test explains how to turn it on.
4. ~~No degraded read-only mode under CSRF~~ — moot: the spike showed the client can satisfy Seerr's CSRF protection itself.
5. **"Other Jellyfin" is an error** (revised after the spike: detection is exact — a 404 on the approval, or a different `serverId` — no longer a name comparison).
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
18. **Silent re-sign-in after the 30-day Seerr session expires** (one retry, configured address only). The reviewer suggested making it a visible tap each time, since each approval mints a Jellyfin session for Seerr; I kept it silent because the first approval already trusts that address and a monthly prompt is friction. Your call if you prefer the visible tap.

19. **Apple TV arrival toast without a button** (the toast window takes no input on tvOS); « Regarder » lives in Mes demandes there.
20. **An address typed without a scheme gets `http://`** (Seerr listens on plain HTTP 5055; a public HTTPS address is pasted whole). Jellyfin's own setup defaults to `https://`.
21. **« Demandes » sits right after « Compte »** in the Settings landing.
22. **The dashed card is the one exception to the design system's « no borders » rule**, documented in `Shared/DesignSystem/CLAUDE.md` (the product owner's option C).

## References

- Mockup: https://claude.ai/artifact/CdTACXqkDVUzG81M9S3eXH (local source `.superpowers/brainstorm/seerr/index.html`, gitignored).
- GitHub #173 (original proposal).
- Jellyfin: `Jellyfin.Api/Helpers/RequestHelpers.cs` (`GetUserId`), `Controllers/DisplayPreferencesController.cs`, `Jellyfin.Server.Implementations/Users/DisplayPreferencesManager.cs` (replace semantics).
- Seerr (`seerr-team/seerr` `develop`): `server/routes/auth.ts` (Jellyfin + Quick Connect login), `server/middleware/auth.ts` (`X-Api-Key`, `X-API-User`), `server/lib/permissions.ts`, `server/constants/media.ts`, `server/routes/request.ts`, `server/routes/{search,collection,person}.ts`, `seerr-api.yml`.
- App: `AppState.refreshCurrentUser`, `JellyfinAPIClient.authorizeQuickConnect(code:)`, `MediaDetailViewModel.loadCollection` / BoxSet children, `SettingsScreen.visibleCases`, `ProFeatureGate.allows`, `ServerRegistry.accountKey(serverId:userId:)`, `KeychainService.privateAccounts`.
