#!/bin/bash
# Shared setup of CI's three Xcode legs (iOS tests, tvOS tests, Release builds):
# select the pinned Xcode, install the pinned xcodegen, generate the project.
#
# The pins themselves stay in .github/workflows/ci.yml (workflow-level `env:`):
# scripts/git-hooks/pre-commit reads XCODEGEN_VERSION from that file, and the
# comments there say why each one is pinned. This script only consumes them.
set -euo pipefail

: "${XCODE_VERSION:?set by ci.yml}"
: "${XCODEGEN_VERSION:?set by ci.yml}"
: "${XCODEGEN_SHA256:?set by ci.yml}"

# A missing version FAILS the leg: building with whatever the image defaults to
# would silently check the PR with another compiler.
available=$(ls -d /Applications/Xcode*.app 2>/dev/null | tr '\n' ' ')
if [ -d "/Applications/Xcode_${XCODE_VERSION}.app" ]; then
  sudo xcode-select -s "/Applications/Xcode_${XCODE_VERSION}.app"
  echo "::notice::Xcode ${XCODE_VERSION} selected (available: ${available})"
else
  echo "::error::Xcode ${XCODE_VERSION} is not on this runner image. Available: ${available}"
  exit 1
fi
xcode-select -p
xcodebuild -version

# Official release zip, checksum verified before the binary runs.
curl -fsSL -o /tmp/xcodegen.zip "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
echo "${XCODEGEN_SHA256}  /tmp/xcodegen.zip" | shasum -a 256 -c -
unzip -q /tmp/xcodegen.zip -d /tmp/xcodegen-dist
# GITHUB_PATH only reaches the NEXT steps, so this one calls the binary by path.
echo "/tmp/xcodegen-dist/xcodegen/bin" >> "$GITHUB_PATH"
/tmp/xcodegen-dist/xcodegen/bin/xcodegen generate
