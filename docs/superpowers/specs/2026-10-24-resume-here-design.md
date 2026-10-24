# « Reprendre ici » — continuity between devices (2026-10-24)

Decided with the product owner on 2026-10-24 (four answers, then « Vas y »), from the study of 2026-10-02 (GitHub #166, memory `project_continuity_pro_feature`). Branch `claude/pro-purchase`.

## Decisions

| Question | Answer |
|---|---|
| Where | **Variant B**: a pill « SUR APPLE TV » on the Continue Watching card; when that title is also the hero, the hero gets the pill, a state line and the CTA « Reprendre ici · 42:13 ». No new surface. |
| The other device | **Stops**: it receives a message « Lecture reprise sur iPhone » and a Playstate `Stop`. |
| Tier | **Pro.** Resuming through the ordinary Continue Watching row stays free. |
| « Continuer sur… » in the iPhone player (push) | **Later**, not in this delivery. |

## What a Pro user sees

On Home (iPhone, iPad, Apple TV), for every Continue Watching item that is open right now on ANOTHER of their devices (same Jellyfin user, other device id):

- the card carries a pill « SUR <DEVICE> » (« SUR APPLE TV », « SUR IPHONE », « SUR IPAD »; another client prints its own device name; no name ⇒ « SUR UN AUTRE APPAREIL »). Decorative: no new focusable on tvOS.
- the hero, when it shows that item: the same pill, a line « En cours sur Apple TV » / « En pause sur Apple TV », and its Play button becomes « Reprendre ici · 42:13 » (the position the other device reported).
- a tap on that card or that button plays HERE from the other device's position, and — as the player opens — sends the source a message « Lecture reprise sur <this device> » then `Stop`. Fire-and-forget: a failure is logged, never shown; the local playback is never held back by it.

When the other device stops, the pill goes away at the next refresh (Home's existing 20 s poll while Accueil is visible, and every Home load).

## What a free user sees (after the Pro launch)

Nothing changes: no pill, the hero says « Lecture », the card resumes from the server's resume position (which the other device updates every ~10 s). **Playback is never gated**: the gate decides whether the elsewhere information is SHOWN and whether the source is stopped, never whether something plays. Before the launch everybody is a founder, so everybody has it.

## Jellyfin facts

- Query: `GET /Sessions?controllableByUserId=<me>&activeWithinSeconds=300` (the « Lire sur… » probe, 30 s cache). The server keeps only sessions that support remote control, so the source must be a client that declared capabilities (JellyGlass with « Contrôle à distance » on — the default). Re-filtered client-side on `userID == me`.
- A session counts when: non-empty id, own user, `deviceID` ≠ ours, `nowPlayingItem.id` present, and `lastPlaybackCheckIn` not older than 10 min (a missing or pre-2001 date is « unknown » and kept — `activeWithinSeconds` already bounds it).
- Matched to a Continue Watching item by EXACT item id (an episode playing elsewhere matches its own episode card, never its series).
- Position: `playState.positionTicks`; state: `playState.isPaused`.
- Stop: `POST /Sessions/{id}/Playing/Stop`; message: `POST /Sessions/{id}/Message` (the receiver shows it under the app's own title, see `docs/rules/remote-control.md`).

## Not built

`NSUserActivity` / Handoff (does not exist on tvOS), persistent controls on the sender, a « me » card in « En direct », continuous polling beyond the existing one, the fiche line, the player's « Continuer sur… » (later).

## Pro page

A seventh sold feature « Reprendre ici » (`ProFeatureID.resumeHere`) in the Gratuit / Pro table, checked to still fit one screen on Apple TV.
