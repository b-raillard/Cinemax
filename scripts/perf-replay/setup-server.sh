#!/bin/bash
# Throwaway Jellyfin with a synthetic library, for the replay benchmarks.
# Usage: BENCH_DIR=/some/scratch ./setup-server.sh   (needs docker; ~600 MB of media)
set -euo pipefail
: "${BENCH_DIR:?set BENCH_DIR to a scratch directory}"
IMAGE="${JF_IMAGE:-jellyfin/jellyfin:10.11.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$BENCH_DIR"/{media,config,cache}
docker run --rm --entrypoint /bin/bash -v "$BENCH_DIR/media:/media" -v "$HERE:/scripts:ro" "$IMAGE" /scripts/gen-library.sh
docker run -d --name jf-bench -p 8096:8096 -v "$BENCH_DIR/config:/config" -v "$BENCH_DIR/cache:/cache" \
  -v "$BENCH_DIR/media:/media:ro" "$IMAGE" >/dev/null
J=localhost:8096; H='Content-Type: application/json'
until curl -sf "$J/Startup/User" >/dev/null; do sleep 3; done
curl -sf -X POST "$J/Startup/Configuration" -H "$H" -d '{"UICulture":"fr-FR","MetadataCountryCode":"FR","PreferredMetadataLanguage":"fr"}'
curl -sf -X POST "$J/Startup/User" -H "$H" -d '{"Name":"bench","Password":"bench"}'
curl -sf -X POST "$J/Startup/RemoteAccess" -H "$H" -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'
curl -sf -X POST "$J/Startup/Complete"
AUTH='MediaBrowser Client="bench", Device="bench", DeviceId="bench1", Version="1"'
curl -sf -X POST "$J/Users/AuthenticateByName" -H "$H" -H "Authorization: $AUTH" -d '{"Username":"bench","Pw":"bench"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessToken"])' > "$BENCH_DIR/token"
A="X-Emby-Token: $(cat "$BENCH_DIR/token")"
OPTS='{"LibraryOptions":{"EnableRealtimeMonitor":false,"EnableInternetProviders":false,"TypeOptions":[]}}'
curl -sf -X POST "$J/Library/VirtualFolders?name=Films&collectionType=movies&paths=/media/movies&refreshLibrary=false" -H "$A" -H "$H" -d "$OPTS"
curl -sf -X POST "$J/Library/VirtualFolders?name=Series&collectionType=tvshows&paths=/media/shows&refreshLibrary=true" -H "$A" -H "$H" -d "$OPTS"
until curl -s "$J/ScheduledTasks" -H "$A" | python3 -c 'import sys,json;sys.exit(0 if all(t["State"]=="Idle" for t in json.load(sys.stdin)) else 1)'; do sleep 5; done
python3 "$HERE/seed.py"
echo "ready: $(curl -s "$J/Items/Counts" -H "$A")"
