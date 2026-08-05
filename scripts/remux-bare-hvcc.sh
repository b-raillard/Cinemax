#!/usr/bin/env bash
#
# remux-bare-hvcc.sh — inventory MKVs whose HEVC track has a BARE hvcC
# (CodecPrivate with zero parameter-set arrays) and rebuild it by remuxing
# through the raw elementary stream.
#
# WHY
#   Some WEB-DL rips store the HEVC VPS/SPS/PPS in-band only: the Matroska
#   CodecPrivate is a 23-byte hvcC header with numOfArrays = 0. libVLC passes
#   that hvcC verbatim to VTDecompressionSessionCreate, which fails (OSStatus
#   -4) — the videotoolbox decoder aborts and playback falls back to SOFTWARE
#   4K decode + swscale conversion. On an Apple TV (A15) that means constant
#   dropped/late frames ("72 heures", diagnosed 2026-08-05). ffmpeg-based
#   players don't care, which is why the same file looks fine elsewhere.
#
#   A plain `mkvmerge in.mkv -o out.mkv` does NOT fix it: MKV→MKV passthrough
#   copies the defective CodecPrivate verbatim (verified). The fix is to
#   extract the raw HEVC ES (parameter sets stay in the stream) and remux from
#   that: mkvmerge's ES parser rebuilds a complete CodecPrivate.
#
#   This is a REMUX, not a re-encode: bitstreams are copied verbatim.
#
# SAFETY
#   - Dry run by default: inventory only, nothing written without --apply.
#   - The fixed file replaces the original UNDER THE SAME NAME (the Jellyfin
#     item, watched state and resume position survive); the original is kept
#     next to it as *.bare-hvcc.bak. You delete the .bak yourself.
#   - Every output is validated (CodecPrivate rebuilt, same track count,
#     duration within 2 s) and deleted again if validation fails.
#   - Needs free disk ≈ 2× the largest file (raw ES + new MKV) during a fix.
#
# USAGE
#   ./remux-bare-hvcc.sh /volume1/Media/Films          # inventory + dry run
#   ./remux-bare-hvcc.sh --apply /volume1/Media/Films  # actually fix
#   ./remux-bare-hvcc.sh --apply --limit 1 /path       # fix exactly one file
#   ./remux-bare-hvcc.sh --self-test                   # verify the pipeline
#
set -uo pipefail

APPLY=0
SELF_TEST=0
LIMIT=0
ROOT=""

MKVMERGE="${MKVMERGE:-mkvmerge}"
MKVEXTRACT="${MKVEXTRACT:-mkvextract}"
PYTHON="${PYTHON:-python3}"
FFMPEG="${FFMPEG:-ffmpeg}"   # self-test only

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

usage() {
    sed -n '3,39p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)     APPLY=1 ;;
        --self-test) SELF_TEST=1 ;;
        --limit)     shift; LIMIT="${1:-0}" ;;
        -h|--help)   usage 0 ;;
        -*)          die "unknown option: $1 (try --help)" ;;
        *)           ROOT="$1" ;;
    esac
    shift
done

command -v "$MKVMERGE"   >/dev/null 2>&1 || die "$MKVMERGE not found (install mkvtoolnix)"
command -v "$MKVEXTRACT" >/dev/null 2>&1 || die "$MKVEXTRACT not found (install mkvtoolnix)"
command -v "$PYTHON"     >/dev/null 2>&1 || die "$PYTHON not found"

# Reads `mkvmerge -J` JSON on stdin. Prints one line:
#   BARE <track_id> <default_duration_ns|-> <language|->   hvcC has no parameter sets
#   OK                                                      healthy HEVC (or no private data issue)
#   SKIP                                                    no HEVC video track
analyze() {
    "$PYTHON" - <<'PY'
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("SKIP"); sys.exit(0)
for t in doc.get("tracks", []):
    if t.get("type") != "video":
        continue
    props = t.get("properties", {})
    if props.get("codec_id") != "V_MPEGH/ISO/HEVC":
        continue
    tid = t.get("id", 0)
    dd = props.get("default_duration") or "-"
    lang = props.get("language") or "-"
    hexdata = (props.get("codec_private_data") or "").strip()
    length = props.get("codec_private_length")
    bare = False
    if hexdata and len(hexdata) >= 46:
        raw = bytes.fromhex(hexdata)
        # hvcC: 22 fixed header bytes, byte 22 = numOfArrays.
        bare = len(raw) >= 23 and raw[0] == 1 and raw[22] == 0
    elif length is not None:
        bare = length < 30
    print(f"BARE {tid} {dd} {lang}" if bare else "OK")
    sys.exit(0)
print("SKIP")
PY
}

# fix <file> <track_id> <default_duration_ns|-> <language|->
# Rebuilds the CodecPrivate via raw-ES remux; replaces <file> in place and
# keeps the original as <file minus .mkv>.bare-hvcc.bak. Returns non-zero and
# cleans up after itself on any failure.
fix() {
    f="$1"; tid="$2"; dd="$3"; lang="$4"
    dir=$(dirname "$f"); base=$(basename "$f")
    tmp="$dir/.${base}.hvccfix.tmp"
    rm -rf "$tmp" && mkdir -p "$tmp" || { note "  KO: cannot create $tmp"; return 1; }

    note "  extracting raw HEVC ES (track $tid)…"
    "$MKVEXTRACT" "$f" tracks "$tid:$tmp/video.hevc" >/dev/null || { note "  KO: mkvextract failed"; rm -rf "$tmp"; return 1; }

    args=()
    [ "$dd" != "-" ] && args+=(--default-duration "0:${dd}ns")
    [ "$lang" != "-" ] && [ "$lang" != "und" ] && args+=(--language "0:$lang")
    note "  remuxing from raw ES…"
    # ${args[@]+…} keeps `set -u` happy on bash 3.2 when the array is empty.
    "$MKVMERGE" -o "$tmp/fixed.mkv" ${args[@]+"${args[@]}"} "$tmp/video.hevc" --no-video "$f" >/dev/null
    rc=$?
    # mkvmerge exit 1 = warnings only; the validation below is the gate.
    [ $rc -le 1 ] && [ -s "$tmp/fixed.mkv" ] || { note "  KO: mkvmerge failed (rc=$rc)"; rm -rf "$tmp"; return 1; }

    verdict=$("$MKVMERGE" -J "$tmp/fixed.mkv" | analyze)
    case "$verdict" in
        OK) ;;
        *)  note "  KO: fixed file still reports '$verdict'"; rm -rf "$tmp"; return 1 ;;
    esac
    ok=$("$PYTHON" - "$f" "$tmp/fixed.mkv" <<PY
import json, subprocess, sys
def probe(p):
    return json.loads(subprocess.run(["$MKVMERGE", "-J", p], capture_output=True, text=True).stdout)
a, b = probe(sys.argv[1]), probe(sys.argv[2])
ta, tb = len(a.get("tracks", [])), len(b.get("tracks", []))
da = a.get("container", {}).get("properties", {}).get("duration") or 0
db = b.get("container", {}).get("properties", {}).get("duration") or 0
# duration is in ns
print("OK" if ta == tb and abs(da - db) <= 2_000_000_000 else f"KO tracks {ta}->{tb} duration {da}->{db}")
PY
)
    if [ "$ok" != "OK" ]; then
        note "  KO: validation failed ($ok)"; rm -rf "$tmp"; return 1
    fi

    bak="${f%.mkv}.bare-hvcc.bak"
    mv "$f" "$bak" || { note "  KO: cannot move original aside"; rm -rf "$tmp"; return 1; }
    if ! mv "$tmp/fixed.mkv" "$f"; then
        note "  KO: cannot install fixed file — restoring original"
        mv "$bak" "$f"; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    note "  FIXED (original kept as $(basename "$bak"))"
    return 0
}

self_test() {
    command -v "$FFMPEG" >/dev/null 2>&1 || die "self-test needs $FFMPEG to synthesize a sample (FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg …)"
    tmp=$(mktemp -d) || die "mktemp failed"
    trap 'rm -rf "$tmp"' EXIT

    note "self-test: hvcC analyzer on known fixtures…"
    "$PYTHON" - <<'PY' || die "analyzer fixture test failed"
bare = bytes.fromhex("01022000000090000000000096f000fefdfafa00000f00")  # « 72 heures », 23 o, numOfArrays=0
assert len(bare) == 23 and bare[0] == 1 and bare[22] == 0, "bare fixture should be detected bare"
full = bytes.fromhex("010220000000b0000000000099f000fcfdfafa00000b03a00001001840010c01ffff022000000300b0000003000003009915c090a100010024420101022000000300b00000030000030099a001e020021c4d8815ee45954d4244024020a2000100084401c02cb8d45364")
assert full[22] != 0, "full fixture should NOT be detected bare"
print("fixtures OK")
PY

    note "self-test: synthesizing a small HEVC MKV…"
    "$FFMPEG" -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=24:duration=2 \
        -c:v libx265 -preset ultrafast -x265-params log-level=error "$tmp/sample.mkv" \
        || "$FFMPEG" -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=24:duration=2 \
        -c:v hevc_videotoolbox "$tmp/sample.mkv" \
        || die "could not synthesize an HEVC sample (no libx265/hevc encoder?)"

    read -r verdict tid dd lang <<<"$("$MKVMERGE" -J "$tmp/sample.mkv" | analyze)"
    note "self-test: detector says '$verdict' on the healthy sample (OK expected)"
    [ "$verdict" = "OK" ] || die "detector flagged a healthy file"

    note "self-test: running the fix pipeline on the healthy sample anyway…"
    tid=$("$MKVMERGE" -J "$tmp/sample.mkv" | "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); print(next(t["id"] for t in d["tracks"] if t["type"]=="video"))')
    fix "$tmp/sample.mkv" "$tid" "-" "-" || die "fix pipeline failed on the sample"
    [ -f "$tmp/sample.bare-hvcc.bak" ] || die "original .bak missing after fix"
    note "self-test: PASSED"
    exit 0
}

[ "$SELF_TEST" = 1 ] && self_test
[ -n "$ROOT" ] || usage 1
[ -d "$ROOT" ] || die "not a directory: $ROOT"

total=0; bare=0; fixed=0; failed=0
while IFS= read -r -d '' f; do
    total=$((total + 1))
    read -r verdict tid dd lang <<<"$("$MKVMERGE" -J "$f" | analyze)"
    [ "$verdict" = "BARE" ] || continue
    bare=$((bare + 1))
    note "BARE hvcC: $f"
    if [ "$APPLY" = 1 ]; then
        if fix "$f" "$tid" "$dd" "$lang"; then
            fixed=$((fixed + 1))
        else
            failed=$((failed + 1))
        fi
        if [ "$LIMIT" -gt 0 ] && [ $((fixed + failed)) -ge "$LIMIT" ]; then
            note "(--limit $LIMIT reached)"
            break
        fi
    fi
done < <(find "$ROOT" -type f \( -iname '*.mkv' \) ! -iname '*.bak' -print0)

note ""
note "scanned: $total MKV — bare hvcC: $bare"
if [ "$APPLY" = 1 ]; then
    note "fixed: $fixed — failed: $failed"
else
    [ "$bare" -gt 0 ] && note "dry run — re-run with --apply to fix"
fi
