#!/bin/bash
# Pre-upload check of an iOS archive (recette 2.4.0, P0): the 2.4.0 build sent
# on 2026-10-08 was archived with Xcode 27.0, so every `#if !NO_HINGE_API`
# block compiled to nothing — no iPhone Duo detection, no table mode — and
# nothing said so. Run it on the .xcarchive BEFORE `-exportArchive`:
#
#   scripts/check-archive-sdk.sh build/Cinemax-2.4.1-iOS.xcarchive
#
# Fails unless the app was built against the iOS 27.1 SDK or later AND its
# binary references UIHingeInteraction (an import from UIKit, read by `nm`).
# The archive-time guard in project.yml (« Require the iOS 27.1 SDK ») stops
# the archive earlier; this is the check on what will actually be uploaded.
set -euo pipefail

archive=${1:?usage: $0 <path/to/Cinemax.xcarchive>}
app=$(find "$archive/Products/Applications" -maxdepth 1 -name '*.app' | head -n 1)
[ -n "$app" ] || { echo "error: no .app in $archive/Products/Applications" >&2; exit 1; }

plist="$app/Info.plist"
binary="$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
sdk=$(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")

status=0
sdk_version=${sdk#iphoneos}
major=${sdk_version%%.*}
case $sdk_version in *.*) rest=${sdk_version#*.}; minor=${rest%%.*} ;; *) minor=0 ;; esac
if [ "${sdk%%[0-9]*}" != "iphoneos" ] || [ "$major" -lt 27 ] || { [ "$major" -eq 27 ] && [ "$minor" -lt 1 ]; }; then
  echo "error: DTSDKName = $sdk — expected iphoneos27.1 or later (archive with DEVELOPER_DIR=/Applications/Xcode-27.1-RC.app/Contents/Developer)" >&2
  status=1
fi

hinge_refs=$(nm -m "$binary" 2>/dev/null | grep -c 'UIHingeInteraction' || true)
if [ "$hinge_refs" -eq 0 ]; then
  echo "error: no UIHingeInteraction reference in $(basename "$binary") — the iPhone Duo code was compiled out (NO_HINGE_API)" >&2
  status=1
fi

echo "$(basename "$app") $version ($build): DTSDKName=$sdk, UIHingeInteraction references=$hinge_refs"
[ $status -eq 0 ] && echo "OK — ready for -exportArchive"
exit $status
