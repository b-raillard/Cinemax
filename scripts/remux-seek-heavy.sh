#!/usr/bin/env bash
#
# remux-seek-heavy.sh — inventory and losslessly remux seek-heavy containers to
# Matroska so Jellyfin can DirectPlay them instead of transcoding to HLS.
#
# WHY
#   Containers whose index lives at EOF (AVI &c.) can't be streamed raw over
#   HTTP: libVLC seeks constantly and the origin gets hammered. Cinemax works
#   around it by forcing a server-side HLS transcode (see the seek-heavy RULE in
#   CLAUDE.md), which costs CPU on every single playback and re-encodes the
#   video. Matroska carries the SAME streams — including MPEG-4 ASP / XviD — with
#   a compact Cues index reachable in one range request, so the file DirectPlays
#   and nothing is transcoded, ever again.
#
#   This is a REMUX, not a re-encode: video and audio bitstreams are copied
#   verbatim. Quality is bit-identical and a file takes seconds.
#
# SAFETY
#   - Dry run by default. Nothing is written without --apply.
#   - The source file is NEVER deleted or modified. You delete originals
#     yourself, once you're happy.
#   - Every output is validated (duration, stream count, full decode pass) and
#     deleted again if it fails, so a silently-broken remux can't survive.
#
# AFTER RUNNING
#   The new file has a different extension, so Jellyfin creates a NEW item on
#   the next scan: watched state and resume position of the old item are not
#   carried over. Decide that before doing a whole library.
#
# USAGE
#   ./remux-seek-heavy.sh /path/to/library            # inventory + dry run
#   ./remux-seek-heavy.sh --apply /path/to/library    # actually remux
#   ./remux-seek-heavy.sh --apply --limit 1 /path     # try exactly one file
#   ./remux-seek-heavy.sh --self-test                 # verify the pipeline
#
set -uo pipefail

# Same list as `isSeekHeavyContainer` in JellyfinAPIClient+Playback.swift.
# Keep the two in sync.
EXTENSIONS=(avi divx wmv asf flv vob mpg mpeg mpe m2v)

APPLY=0
KEEP_SUBS=0
SELF_TEST=0
LIMIT=0
ROOT=""

FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

usage() {
    sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)     APPLY=1 ;;
        --keep-subs) KEEP_SUBS=1 ;;
        --self-test) SELF_TEST=1 ;;
        --limit)     shift; LIMIT="${1:-0}" ;;
        -h|--help)   usage 0 ;;
        -*)          die "unknown option: $1 (try --help)" ;;
        *)           ROOT="$1" ;;
    esac
    shift
done

command -v "$FFMPEG"  >/dev/null 2>&1 || die "$FFMPEG not found. On the Jellyfin host try: FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg FFPROBE=/usr/lib/jellyfin-ffmpeg/ffprobe $0 ..."
command -v "$FFPROBE" >/dev/null 2>&1 || die "$FFPROBE not found (see --help)"

# `-cues_to_front` puts the Matroska index at the head of the file, which is
# what makes the first seek over HTTP cheap. Added in ffmpeg 5.0 — degrade
# quietly on older builds rather than failing every file.
CUES_ARGS=()
if "$FFMPEG" -hide_banner -h muxer=matroska 2>/dev/null | grep -q cues_to_front; then
    CUES_ARGS=(-cues_to_front 1)
fi

# probe_fmt FILE ENTRY            → a container-level value (e.g. duration)
# probe_stream FILE SELECTOR ENTRY → per-stream values, one per line
probe_fmt()    { "$FFPROBE" -v error -show_entries "format=$2" -of default=nw=1:nk=1 "$1" 2>/dev/null; }
probe_stream() { "$FFPROBE" -v error -select_streams "$2" -show_entries "stream=$3" -of default=nw=1:nk=1 "$1" 2>/dev/null; }

# Remux one file. Echoes a status word; never touches the source.
remux_one() {
    local src="$1" dst="${1%.*}.mkv"

    if [ -e "$dst" ]; then note "  skip   (target exists): $dst"; return 2; fi

    local vcodec acodec src_dur
    vcodec=$(probe_stream "$src" v:0 codec_name)
    acodec=$(probe_stream "$src" a:0 codec_name)
    src_dur=$(probe_fmt "$src" duration)
    [ -n "$src_dur" ] || { note "  FAIL   (unreadable source): $src"; return 1; }

    note "  video=$vcodec audio=${acodec:-none} duration=${src_dur%.*}s"

    local args=(-v error -y -i "$src" -map 0:v -map 0:a? -c copy)
    # DivX/XviD "packed B-frames" are a Video-for-Windows hack that is NOT valid
    # MPEG-4 outside AVI; copied as-is they produce artefacts. Unpack them.
    [ "$vcodec" = "mpeg4" ] && args+=(-bsf:v mpeg4_unpack_bframes)
    # AVI XSUB / DVD bitmap subs frequently refuse to map into Matroska and fail
    # the whole remux; dropping them is the safe default.
    if [ "$KEEP_SUBS" -eq 1 ]; then args+=(-map "0:s?" -c:s copy); else args+=(-sn); fi
    args+=("${CUES_ARGS[@]}" "$dst")

    if [ "$APPLY" -eq 0 ]; then
        note "  would run: $FFMPEG ${args[*]}"
        return 0
    fi

    if ! "$FFMPEG" "${args[@]}"; then
        note "  FAIL   (ffmpeg refused): $src"
        rm -f -- "$dst"
        return 1
    fi

    # Validation. A -c copy remux can succeed loudly and still be unusable, so
    # nothing is declared good until the output proves itself.
    local dst_dur delta
    dst_dur=$(probe_fmt "$dst" duration)
    if [ -z "$dst_dur" ]; then
        note "  FAIL   (output unreadable): $dst"; rm -f -- "$dst"; return 1
    fi
    delta=$(awk -v a="$src_dur" -v b="$dst_dur" 'BEGIN{d=a-b; if(d<0)d=-d; print (d>2)?"bad":"ok"}')
    if [ "$delta" = "bad" ]; then
        note "  FAIL   (duration drift ${src_dur%.*}s → ${dst_dur%.*}s): $dst"; rm -f -- "$dst"; return 1
    fi
    local src_streams dst_streams
    src_streams=$(probe_stream "$src" v index | wc -l)
    dst_streams=$(probe_stream "$dst" v index | wc -l)
    if [ "$src_streams" != "$dst_streams" ]; then
        note "  FAIL   (video stream count $src_streams → $dst_streams): $dst"; rm -f -- "$dst"; return 1
    fi
    # Full decode pass: catches truncated/corrupt sources that copied "fine".
    if ! "$FFMPEG" -v error -i "$dst" -f null - 2>/tmp/remux_decode_err.$$; then
        note "  FAIL   (decode errors): $dst"
        sed 's/^/         /' /tmp/remux_decode_err.$$ | head -3
        rm -f -- "$dst" /tmp/remux_decode_err.$$
        return 1
    fi
    if [ -s /tmp/remux_decode_err.$$ ]; then
        note "  WARN   (decode warnings, output KEPT — check it plays):"
        sed 's/^/         /' /tmp/remux_decode_err.$$ | head -3
    fi
    rm -f /tmp/remux_decode_err.$$
    note "  OK     → $dst"
    return 0
}

self_test() {
    local dir; dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    note "Self-test in $dir"
    note "Synthesising a 5s XviD + MP3 AVI (the exact shape this script targets)…"
    local acodec=libmp3lame
    "$FFMPEG" -hide_banner -h encoder=libmp3lame >/dev/null 2>&1 || acodec=mp2
    if ! "$FFMPEG" -v error -y \
            -f lavfi -i "testsrc=size=320x240:rate=25:duration=5" \
            -f lavfi -i "sine=frequency=440:duration=5" \
            -c:v mpeg4 -vtag XVID -c:a "$acodec" -shortest "$dir/sample.avi"; then
        die "could not synthesise a sample (this ffmpeg lacks mpeg4/$acodec encoders)"
    fi
    APPLY=1
    note "Remuxing it…"
    if remux_one "$dir/sample.avi" && [ -s "$dir/sample.mkv" ]; then
        local c; c=$(probe_stream "$dir/sample.mkv" v:0 codec_name)
        [ "$c" = "mpeg4" ] || die "self-test: video codec changed to '$c' — that is NOT a lossless remux"
        note "PASS — pipeline works, video copied as mpeg4, output validated."
        return 0
    fi
    die "self-test FAILED — do not run this script on your library"
}

if [ "$SELF_TEST" -eq 1 ]; then self_test; exit $?; fi
[ -n "$ROOT" ] || usage 1
[ -d "$ROOT" ] || die "not a directory: $ROOT"

find_args=()
for ext in "${EXTENSIONS[@]}"; do find_args+=(-iname "*.${ext}" -o); done
unset 'find_args[${#find_args[@]}-1]'

total=0; ok=0; failed=0; skipped=0
declare -A by_ext

while IFS= read -r -d '' f; do
    ext="${f##*.}"; by_ext[$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')]=$(( ${by_ext[$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')]:-0} + 1 ))
    total=$((total + 1))
    [ "$LIMIT" -gt 0 ] && [ "$total" -gt "$LIMIT" ] && { total=$((total - 1)); break; }
    note "[$total] $f"
    remux_one "$f"
    case $? in 0) ok=$((ok + 1)) ;; 2) skipped=$((skipped + 1)) ;; *) failed=$((failed + 1)) ;; esac
done < <(find "$ROOT" -type f \( "${find_args[@]}" \) -print0)

note ""
note "──────── inventory ────────"
for ext in "${!by_ext[@]}"; do note "  ${ext}: ${by_ext[$ext]}"; done
[ "$total" -eq 0 ] && note "  (no seek-heavy containers found)"
note "───────── result ─────────"
if [ "$APPLY" -eq 0 ]; then
    note "  DRY RUN — nothing was written. Re-run with --apply (start with --limit 1)."
else
    note "  remuxed: $ok   failed: $failed   skipped: $skipped"
    note "  Originals were NOT deleted. Verify playback, then remove them yourself."
fi
[ "$failed" -gt 0 ] && exit 1
exit 0
