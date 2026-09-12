# Server response fixtures

Raw Jellyfin responses decoded by `ServerDTODecodingFixtureTests` with the
SDK's own decoder configuration. They exist for one reason: jellyfin-sdk-swift
3.1.0 is generated from the 12.0 spec and decodes three fields **strictly**
(`decode`, not `decodeIfPresent`) — `UserItemDataDto.Key`,
`UserPolicy.AuthenticationProviderId` and `UserPolicy.PasswordResetProviderId`.
A server that omits one fails the **whole** DTO: every rail and grid for the
first, login and `validateSession` for the other two. An in-memory DTO never
runs `init(from:)`, so only real bytes can prove the contract.

## Files

`jellyfin-<major.minor>-<Name>.json`, one set per server generation:

| Name | Request (same shape the app sends) | SDK type |
|---|---|---|
| `UserDto` | `GET /Users/Me` | `UserDto` |
| `BaseItemDto-movie` | `GET /Items/{id}?userId=…` | `BaseItemDto` |
| `Resume` | `GET /UserItems/Resume?userId=…&limit=10&enableUserData=true&enableImageTypes=Primary,Backdrop,Thumb` | `BaseItemDtoQueryResult` |
| `NextUp` | `GET /Shows/NextUp?userId=…&limit=20&enableUserData=true` | `BaseItemDtoQueryResult` |

The folder rides `project.yml` as a **folder reference** in the test target's
resources phase, so a new file here is bundled without touching the project.

## What is measured

| Set | Captured from | Strict fields on the wire |
|---|---|---|
| `10.10` | `jellyfin/jellyfin:10.10.7`, Docker, 2026-09-11 | all present — `UserData.Key` on 4/4 objects (item 1, Resume 2, Next Up 1), both `Policy` ids |
| `10.11` | `jellyfin/jellyfin:10.11.11`, Docker, 2026-09-11 | all present — same counts |
| `12.0` | `UserDto` + `BaseItemDto-movie`: the reference server (12.0), 2026-09-10 · `Resume` + `NextUp`: `jellyfin/jellyfin:12.0` = 12.0.0, Docker, 2026-09-11 | all present — `UserData.Key` on 6/6 objects (Resume 4) |

So SDK 3.1.0's strict decode holds on 10.10, 10.11 and 12.0. **The 10.9 floor
is still unmeasured** — one script run away (`… 10.9.11`).

Differences between generations, all measured, none of them on a strict field
(the tests assert presence, never a spelling):

- **10.10.7 sends `Guid.Empty` as `UserData.ItemId` on every item**; 10.11 and
  12.0 send the item's own id. The app never reads `userData.itemID`.
- `UserData.Key` has three spellings: the item's dashed id (10.x movie, 10.11 /
  12.0 episode), the undashed id (reference-server 12.0 movie), and on 10.10 an
  episode's `<dashed series id>001002`.
- 12.0.0's `/UserItems/Resume`, asked with the app's shape (no
  `includeItemTypes` / `mediaTypes`), also returns the partly-watched series'
  **Season and Series** (position 0, `UnplayedItemCount` 1); 10.10 and 10.11
  return only the movie and the episode. Not a decode concern — noted because
  the app renders that list as Continue Watching.

## Capturing a new server version

```sh
scripts/fixtures/capture-jellyfin-fixtures.sh 12.1.0            # writes jellyfin-12.1-*.json
scripts/fixtures/capture-jellyfin-fixtures.sh 12.0 --force      # replace an existing set
```

then add the version to `FixtureServer` in `ServerDTODecodingFixtureTests.swift`.

What one run does, and leaves behind nothing but the JSON (and the image):

1. generates three 7-minute clips with the ffmpeg shipped **inside** the image
   (a movie and a two-episode series, each with an audio and a subtitle stream)
   and NFO files carrying placeholder titles and dates. Seven minutes because
   Jellyfin keeps no resume position on items shorter than
   `MinResumeDurationSeconds` (300 s);
2. starts `jellyfin/jellyfin:<tag>` bound to `127.0.0.1` only, config / cache /
   media in a temp dir under `$TMPDIR`, DNS pointed at `127.0.0.1` so no
   internet metadata provider is ever consulted;
3. drives the startup wizard, signs in as the throwaway admin it created, adds a
   Movies and a Shows library, scans and waits for the scan to settle;
4. reports playback — the movie and S01E02 stopped at 2:00, S01E01 marked
   played — so Resume and Next Up have content;
5. captures the four responses, anonymises them, writes them here;
6. prints, for the RAW capture of that run, whether each strict field is on the
   wire;
7. removes the container and the temp dir.

It touches no other server and uses no API key. `--port N` picks the local
port (default 18096), `--keep` leaves the container and temp dir for debugging.

**Existing files are never overwritten without `--force`.** The 12.0
`UserDto` / `BaseItemDto-movie` pair comes from the reference server and is
richer than anything a synthetic clip produces (HDR10, nine streams, provider
metadata); a plain 12.0 run therefore only fills in `Resume` and `NextUp`.

## Anonymisation

Every identifier — a 32-hex or dashed GUID, as a value, as an object key, or
embedded in a longer string (10.x spells an episode's `UserData.Key` as
`<dashed series id>001002`) — is replaced by a placeholder of the SAME shape,
one mapping shared by the four files of a version so cross-references survive:
the movie is `1111…`, the server `2222…`, the user `3333…`, everything else
`4444…`, `5555…` … in order of first appearance. `Guid.Empty` is kept verbatim:
it is a sentinel, and the server sending it is itself a fact about the version.
Titles, paths and the user name are placeholders from the start (`Fixture
Movie`, `/data/...`, `fixture-user`), so nothing else is rewritten: every key
the server sent is preserved with its original type.
