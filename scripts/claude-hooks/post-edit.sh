#!/bin/bash
# PostToolUse after Edit/Write: regenerate the Xcode project when project.yml
# changes or a NEW Swift file appears (one the project does not list yet), then
# lint a Swift file exactly as CI does (--strict against the baseline).
set -u
FILE=$(jq -r '.tool_input.file_path // ""')
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
PBX=Cinemax.xcodeproj/project.pbxproj
regen() { command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null 2>&1 && echo "xcodegen: project regenerated ($1)" >&2; }

case "$FILE" in
  */project.yml) regen "project.yml changed" ;;
  *.swift)
    if [[ "$FILE" =~ /(Shared|iOS|tvOS|Tests|Widgets|TopShelf)/ ]] && [ -f "$PBX" ] \
       && ! grep -qF "/* $(basename "$FILE") */" "$PBX"; then
      regen "new file $(basename "$FILE")"
    fi
    if command -v swiftlint >/dev/null 2>&1; then
      REL=${FILE#"$PWD"/}
      swiftlint lint --strict --quiet --baseline .swiftlint-baseline.json "$REL" 2>&1 | head -40 >&2
    fi
    ;;
esac
exit 0
