#!/bin/bash
# PreToolUse guard for simulator tools: only the simulators listed in
# .claude/simulators.local (one UDID per line, gitignored, per machine) may be
# driven. No list = no guard, so a fresh clone is never blocked.
# The list is read from this checkout, else from the main checkout (worktrees).
set -u
INPUT=$(cat)
list=""
for dir in "${CLAUDE_PROJECT_DIR:-.}" "$(dirname "$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")"; do
  [ -f "$dir/.claude/simulators.local" ] && { list="$dir/.claude/simulators.local"; break; }
done
[ -z "$list" ] && exit 0

deny() { echo "Simulator guard: $1 Allowed simulators are listed in $list." >&2; exit 2; }
allowed() { grep -v '^[[:space:]]*#' "$list" | grep -qiF -- "$1"; }

TOOL=$(jq -r '.tool_name' <<<"$INPUT")
case "$TOOL" in
  mcp__Claude_Code_iOS_Simulator__*)
    ACTION=$(jq -r '.tool_input.action // ""' <<<"$INPUT")
    [ "$ACTION" = "attach" ] && deny "'attach' is not allowed (it opens the live panel on the default device)."
    DEV=$(jq -r '.tool_input.device // .tool_input.udid // ""' <<<"$INPUT")
    [ -z "$DEV" ] && deny "name the simulator explicitly with 'device' (its UDID) — without it the tool targets whatever is attached."
    [[ "$DEV" =~ ^[0-9A-Fa-f-]{36}$ ]] || deny "'$DEV' is not a UDID — pass the simulator's UDID."
    allowed "$DEV" || deny "$DEV is not an allowed simulator."
    ;;
  mcp__xcodebuildmcp__*)
    NAME=$(jq -r '.tool_input.simulatorName // ""' <<<"$INPUT")
    [ -n "$NAME" ] && deny "name the simulator by its UDID (simulatorId), not by name ('$NAME')."
    ID=$(jq -r '.tool_input.simulatorId // .tool_input.simulatorUuid // ""' <<<"$INPUT")
    if [ -n "$ID" ]; then
      [[ "$ID" =~ ^[0-9A-Fa-f-]{36}$ ]] && allowed "$ID" || deny "$ID is not an allowed simulator UDID."
    fi
    ;;
esac
exit 0
