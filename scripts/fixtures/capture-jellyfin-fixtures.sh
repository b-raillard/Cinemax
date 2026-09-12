#!/usr/bin/env bash
#
# capture-jellyfin-fixtures.sh — capture the raw server responses that
# `ServerDTODecodingFixtureTests` decodes, from a THROWAWAY Jellyfin container.
#
#   scripts/fixtures/capture-jellyfin-fixtures.sh <image-tag> [--port N] [--out DIR] [--force] [--keep]
#
#   scripts/fixtures/capture-jellyfin-fixtures.sh 10.10.7
#   scripts/fixtures/capture-jellyfin-fixtures.sh 10.11.11 --port 18097
#   scripts/fixtures/capture-jellyfin-fixtures.sh 12.1.0 --force
#
# What it does, end to end, with nothing left behind:
#   1. generates three 7-minute test clips with the ffmpeg shipped INSIDE the
#      image (a movie + a two-episode series, each with an audio and a
#      subtitle stream) plus NFO files carrying placeholder titles and dates;
#   2. starts `jellyfin/jellyfin:<tag>` bound to 127.0.0.1 only, with
#      config/cache/media in a temp dir under $TMPDIR and DNS pointed at
#      127.0.0.1 so no internet metadata provider is ever consulted;
#   3. drives the startup wizard, signs in, adds a Movies and a Shows library,
#      scans them and waits for the scan to finish;
#   4. reports playback progress (movie + episode 2 stopped at 2:00, episode 1
#      marked played) so Continue Watching and Next Up have content;
#   5. captures the four responses with the query shapes the app sends
#      (`JellyfinAPIClient+Library.swift` / `+Session.swift`):
#        UserDto            GET /Users/Me
#        BaseItemDto-movie  GET /Items/{id}?userId=…
#        Resume             GET /UserItems/Resume?userId=…&limit=10&enableUserData=true&enableImageTypes=Primary,Backdrop,Thumb
#        NextUp             GET /Shows/NextUp?userId=…&limit=20&enableUserData=true
#   6. replaces every identifier (32-hex or dashed GUID, as a value OR a key)
#      by a fixed placeholder of the same shape — movie 1111…, server 2222…,
#      user 3333…, the rest in order of appearance — consistently across the
#      four files, and writes them as Fixtures/jellyfin-<major.minor>-<Name>.json;
#   7. prints whether every strict-decode field of SDK 3.1.0 is on the wire;
#   8. removes the container and the temp dir (the image is kept).
#
# Existing fixture files are NEVER overwritten without --force: the 12.0 item
# and user fixtures come from the reference server and are richer (HDR, nine
# streams) than anything a synthetic clip produces, so a 12.0 run only fills in
# the files that are missing.
#
# Requires: docker, curl, python3. Touches no other server and uses no API key:
# the only credential is the throwaway admin the wizard creates.

set -euo pipefail

usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }

TAG=""
PORT=18096
FORCE=0
KEEP=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/Tests/CinemaxKitTests/Fixtures"

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) usage ;;
        -*) echo "unknown option $1" >&2; usage ;;
        *) TAG="$1"; shift ;;
    esac
done
[ -n "$TAG" ] || usage

IMAGE="jellyfin/jellyfin:$TAG"
NAME="cinemax-fixtures-$(printf '%s' "$TAG" | tr -c 'a-zA-Z0-9' '-')-$$"
BASE="http://127.0.0.1:$PORT"
FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg
# Jellyfin only keeps a resume position on items longer than
# `MinResumeDurationSeconds` (300 s by default), so the clips must be longer.
DURATION=420
POSITION_TICKS=1200000000   # 2:00
USER_NAME="fixture-user"
USER_PASSWORD="fixture-password"
CLIENT='MediaBrowser Client="Cinemax Fixtures", Device="capture-jellyfin-fixtures", DeviceId="cinemax-fixtures-capture", Version="1.0"'
TOKEN=""

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cinemax-fixtures.XXXXXX")"
mkdir -p "$WORK/config" "$WORK/cache" "$WORK/raw" \
    "$WORK/media/Movies/Fixture Movie (2020)" \
    "$WORK/media/Shows/Fixture Show/Season 01"

log() { printf '▸ %s\n' "$*" >&2; }

cleanup() {
    local status=$?
    if [ "$KEEP" -eq 1 ]; then
        log "--keep: container $NAME and $WORK left in place"
        exit "$status"
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # Files the container wrote may not be removable by the host user on
    # every Docker backend; fall back to deleting them from inside a container.
    rm -rf "$WORK" 2>/dev/null || {
        docker run --rm -v "$WORK:/w" --entrypoint /bin/sh "$IMAGE" -c 'rm -rf /w/*' >/dev/null 2>&1 || true
        rm -rf "$WORK"
    }
    exit "$status"
}
trap cleanup EXIT

# api METHOD PATH [JSON-BODY] — authenticated once TOKEN is set.
api() {
    local method="$1" path="$2" body="${3:-}"
    local auth="$CLIENT"
    [ -n "$TOKEN" ] && auth="$auth, Token=\"$TOKEN\""
    if [ -n "$body" ]; then
        curl -fsS -X "$method" -H "Authorization: $auth" -H 'Content-Type: application/json' --data "$body" "$BASE$path"
    else
        curl -fsS -X "$method" -H "Authorization: $auth" "$BASE$path"
    fi
}

# jget EXPR — evaluate a Python expression over the JSON document on stdin (`d`).
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# ---------------------------------------------------------------- media ------

log "pulling $IMAGE (no-op when already present)"
docker pull -q "$IMAGE" >/dev/null

cat > "$WORK/media/.fixture.srt" <<'SRT'
1
00:00:01,000 --> 00:00:04,000
Sous-titre de la fixture.
SRT

make_clip() {   # $1 = path under /data
    docker run --rm --dns 127.0.0.1 --entrypoint "$FFMPEG" -v "$WORK/media:/data" "$IMAGE" \
        -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc=size=160x90:rate=1:duration=$DURATION" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$DURATION" \
        -i /data/.fixture.srt \
        -map 0:v -map 1:a -map 2:s \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 32k -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:a:0 title="ENG Stereo" \
        -metadata:s:s:0 language=fra -metadata:s:s:0 title="FR Full" \
        "/data/$1"
}

log "generating clips with the image's own ffmpeg"
make_clip "Movies/Fixture Movie (2020)/Fixture Movie (2020).mkv"
make_clip "Shows/Fixture Show/Season 01/Fixture Show S01E01.mkv"
make_clip "Shows/Fixture Show/Season 01/Fixture Show S01E02.mkv"
rm -f "$WORK/media/.fixture.srt"

cat > "$WORK/media/Movies/Fixture Movie (2020)/Fixture Movie (2020).nfo" <<'NFO'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<movie>
  <title>Fixture Movie</title>
  <plot>Synopsis de la fixture.</plot>
  <year>2020</year>
  <premiered>2020-06-05</premiered>
  <mpaa>PG-13</mpaa>
  <rating>6.5</rating>
  <genre>Drama</genre>
</movie>
NFO
cat > "$WORK/media/Shows/Fixture Show/tvshow.nfo" <<'NFO'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<tvshow>
  <title>Fixture Show</title>
  <plot>Synopsis de la série fixture.</plot>
  <year>2019</year>
  <premiered>2019-01-07</premiered>
  <genre>Drama</genre>
</tvshow>
NFO
for n in 1 2; do
    cat > "$WORK/media/Shows/Fixture Show/Season 01/Fixture Show S01E0$n.nfo" <<NFO
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<episodedetails>
  <title>Fixture Episode $n</title>
  <season>1</season>
  <episode>$n</episode>
  <aired>2019-01-0$((6 + n))</aired>
  <plot>Synopsis de l'épisode fixture $n.</plot>
</episodedetails>
NFO
done

# --------------------------------------------------------------- server ------

log "starting $IMAGE on 127.0.0.1:$PORT ($NAME)"
docker run -d --name "$NAME" --hostname cinemax-fixtures --dns 127.0.0.1 \
    -p "127.0.0.1:$PORT:8096" \
    -v "$WORK/config:/config" -v "$WORK/cache:/cache" -v "$WORK/media:/data:ro" \
    "$IMAGE" >/dev/null

# 10.11+ answers /System/Info/Public with a 200 placeholder while its startup
# migrations run, so "ready" means "the answer carries a Version", not "200".
ready=0
for _ in $(seq 1 300); do
    if curl -fsS "$BASE/System/Info/Public" -o "$WORK/raw/info.json" 2>/dev/null \
        && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("Version") else 1)' "$WORK/raw/info.json" 2>/dev/null; then
        ready=1; break
    fi
    sleep 1
done
[ "$ready" -eq 1 ] || { log "server never reported its version on /System/Info/Public"; docker logs --tail 40 "$NAME" >&2; exit 1; }
VERSION="$(jget 'd["Version"]' < "$WORK/raw/info.json")"
SERVER_ID="$(jget 'd["Id"]' < "$WORK/raw/info.json")"
LABEL="$(printf '%s' "$VERSION" | cut -d. -f1-2)"
log "server answers: Jellyfin $VERSION (fixtures labelled $LABEL)"

log "startup wizard"
api POST /Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
api GET /Startup/User >/dev/null
api POST /Startup/User "{\"Name\":\"$USER_NAME\",\"Password\":\"$USER_PASSWORD\"}" >/dev/null
api POST /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null || true
api POST /Startup/Complete >/dev/null

log "signing in as $USER_NAME"
api POST /Users/AuthenticateByName "{\"Username\":\"$USER_NAME\",\"Pw\":\"$USER_PASSWORD\"}" > "$WORK/raw/auth.json"
TOKEN="$(jget 'd["AccessToken"]' < "$WORK/raw/auth.json")"
USER_ID="$(jget 'd["User"]["Id"]' < "$WORK/raw/auth.json")"

log "adding libraries and scanning"
LIB_OPTS='{"LibraryOptions":{"EnableRealtimeMonitor":false,"EnableChapterImageExtraction":false,"ExtractChapterImagesDuringLibraryScan":false}}'
api POST "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=%2Fdata%2FMovies&refreshLibrary=false" "$LIB_OPTS" >/dev/null
api POST "/Library/VirtualFolders?name=Shows&collectionType=tvshows&paths=%2Fdata%2FShows&refreshLibrary=false" "$LIB_OPTS" >/dev/null
api POST /Library/Refresh >/dev/null

ITEMS_QUERY="/Items?userId=$USER_ID&recursive=true&includeItemTypes=Movie,Episode&fields=MediaStreams"
scan_done=0
for _ in $(seq 1 300); do
    sleep 1
    api GET "$ITEMS_QUERY" > "$WORK/raw/items.json" 2>/dev/null || continue
    ready="$(jget 'sum(1 for i in d.get("Items",[]) if i.get("RunTimeTicks") and i.get("MediaStreams"))' < "$WORK/raw/items.json")"
    [ "$ready" -ge 3 ] || continue
    api GET "/ScheduledTasks?isHidden=false" > "$WORK/raw/tasks.json" 2>/dev/null || continue
    state="$(jget 'next((t["State"] for t in d if t.get("Key")=="RefreshLibrary"), "Idle")' < "$WORK/raw/tasks.json")"
    if [ "$state" = "Idle" ]; then scan_done=1; break; fi
done
[ "$scan_done" -eq 1 ] || { log "library scan did not settle"; docker logs --tail 40 "$NAME" >&2; exit 1; }
sleep 3   # let the post-scan image extraction write its tags

MOVIE_ID="$(jget 'next(i["Id"] for i in d["Items"] if i["Type"]=="Movie")' < "$WORK/raw/items.json")"
EP1_ID="$(jget 'next(i["Id"] for i in d["Items"] if i["Type"]=="Episode" and i.get("IndexNumber")==1)' < "$WORK/raw/items.json")"
EP2_ID="$(jget 'next(i["Id"] for i in d["Items"] if i["Type"]=="Episode" and i.get("IndexNumber")==2)' < "$WORK/raw/items.json")"

log "reporting playback (movie + S01E02 stopped at 2:00, S01E01 played)"
report_stop_at() {   # $1 = item id, $2 = position ticks
    local session="fixture-$1"
    api POST /Sessions/Playing "{\"ItemId\":\"$1\",\"PositionTicks\":0,\"PlaySessionId\":\"$session\",\"PlayMethod\":\"DirectPlay\",\"CanSeek\":true,\"IsPaused\":false,\"IsMuted\":false}" >/dev/null
    api POST /Sessions/Playing/Progress "{\"ItemId\":\"$1\",\"PositionTicks\":$2,\"PlaySessionId\":\"$session\",\"PlayMethod\":\"DirectPlay\",\"CanSeek\":true,\"IsPaused\":false,\"IsMuted\":false,\"EventName\":\"TimeUpdate\"}" >/dev/null
    api POST /Sessions/Playing/Stopped "{\"ItemId\":\"$1\",\"PositionTicks\":$2,\"PlaySessionId\":\"$session\"}" >/dev/null
}
report_stop_at "$MOVIE_ID" "$POSITION_TICKS"
report_stop_at "$EP2_ID" "$POSITION_TICKS"
api POST "/UserPlayedItems/$EP1_ID?userId=$USER_ID" >/dev/null
sleep 1

log "capturing"
api GET /Users/Me > "$WORK/raw/UserDto.json"
api GET "/Items/$MOVIE_ID?userId=$USER_ID" > "$WORK/raw/BaseItemDto-movie.json"
api GET "/UserItems/Resume?userId=$USER_ID&limit=10&enableUserData=true&enableImageTypes=Primary,Backdrop,Thumb" > "$WORK/raw/Resume.json"
api GET "/Shows/NextUp?userId=$USER_ID&limit=20&enableUserData=true" > "$WORK/raw/NextUp.json"

# ------------------------------------------------------ anonymise + write ----

mkdir -p "$OUT_DIR"
python3 - "$WORK/raw" "$OUT_DIR" "$LABEL" "$VERSION" "$FORCE" "$MOVIE_ID" "$SERVER_ID" "$USER_ID" <<'PY'
import json, os, re, sys

raw, out, label, version, force, movie_id, server_id, user_id = sys.argv[1:9]
force = force == "1"
names = ["UserDto", "BaseItemDto-movie", "Resume", "NextUp"]

hex32 = re.compile(r"^[0-9a-fA-F]{32}$")
dashed = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
# A dashed GUID can also sit INSIDE a longer string — 10.x builds an episode's
# `UserData.Key` as "<dashed series id><season:000><episode:000>".
embedded = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

def norm(s):
    return s.replace("-", "").lower()

def is_empty_guid(s):
    # Guid.Empty is a sentinel, not an identifier: it is kept verbatim, since
    # "the server sent the empty GUID here" is itself a fact about the version.
    return set(norm(s)) == {"0"}

# Fixed roles first, so the tests can name them; everything else in order of
# first appearance. One map for all four files keeps cross-references intact
# (an episode's SeriesId still equals the series' Id). "0" is not in the pool,
# so no placeholder can be mistaken for Guid.Empty.
mapping = {norm(movie_id): "1" * 32, norm(server_id): "2" * 32, norm(user_id): "3" * 32}
pool = list("456789abcdef")
counter = [0]

def placeholder(value):
    if is_empty_guid(value):
        return value
    key = norm(value)
    if key not in mapping:
        if pool:
            mapping[key] = pool.pop(0) * 32
        else:
            counter[0] += 1
            mapping[key] = "e" + format(counter[0], "031x")
    p = mapping[key]
    if dashed.match(value):
        return f"{p[0:8]}-{p[8:12]}-{p[12:16]}-{p[16:20]}-{p[20:32]}"
    return p

def scrub_string(s):
    if hex32.match(s) or dashed.match(s):
        return placeholder(s)
    return embedded.sub(lambda m: placeholder(m.group(0)), s)

def scrub(node):
    if isinstance(node, dict):
        return {scrub_string(k): scrub(v) for k, v in node.items()}
    if isinstance(node, list):
        return [scrub(v) for v in node]
    if isinstance(node, str):
        return scrub_string(node)
    return node

docs = {}
for name in names:
    with open(os.path.join(raw, name + ".json"), encoding="utf-8") as f:
        docs[name] = scrub(json.load(f))

for name in names:
    dest = os.path.join(out, f"jellyfin-{label}-{name}.json")
    if os.path.exists(dest) and not force:
        print(f"  kept existing {os.path.basename(dest)} (pass --force to replace it)")
        continue
    with open(dest, "w", encoding="utf-8") as f:
        json.dump(docs[name], f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"  wrote {os.path.basename(dest)}")

# Strict-decode fields of jellyfin-sdk-swift 3.1.0, checked on the RAW capture
# of THIS run (not on whatever file was kept), so the report speaks for $version.
def walk(node, path, found):
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{path}.{k}"
            if k == "UserData" and isinstance(v, dict):
                found.append(("UserData.Key", p, "Key" in v and isinstance(v["Key"], str)))
            if k == "Policy" and isinstance(v, dict):
                for field in ("AuthenticationProviderId", "PasswordResetProviderId"):
                    found.append((f"Policy.{field}", p, isinstance(v.get(field), str)))
            walk(v, p, found)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{path}[{i}]", found)

print(f"strict-decode fields on the wire, Jellyfin {version}:")
missing = 0
for name in names:
    found = []
    walk(docs[name], name, found)
    by_field = {}
    for field, path, ok in found:
        by_field.setdefault(field, [0, []])
        by_field[field][0] += 1
        if not ok:
            by_field[field][1].append(path)
    for field, (count, absent) in sorted(by_field.items()):
        state = "present" if not absent else "MISSING at " + ", ".join(absent)
        missing += len(absent)
        print(f"  {name:18} {field:34} {count} object(s): {state}")
if missing:
    print(f"!! {missing} strict field(s) absent — SDK 3.1.0 fails the whole DTO on this server")
PY

log "done — Jellyfin $VERSION"
