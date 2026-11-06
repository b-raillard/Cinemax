#!/bin/bash
# Prints the UDID of an Apple TV simulator for CI's tvOS test step.
#
# The runner image's simulator set changes under us: on 2026-11-06 the
# xcode-27 image no longer had an « Apple TV 4K (3rd generation) » device and
# `-destination name=…` failed before building anything. So: take any
# Apple TV 4K xcodebuild can test on, newest tvOS first, else create one on the
# newest installed tvOS runtime, else download the tvOS platform first.
set -euo pipefail

# Asks xcodebuild itself which simulators it can test the scheme on, so a
# runtime newer than the selected Xcode's SDK is never picked.
newest_device() {
  xcodebuild -project Cinemax.xcodeproj -scheme CinemaxTV -showdestinations \
    -skipPackagePluginValidation 2>/dev/null | python3 -c '
import re, sys
found = []
for line in sys.stdin:
    m = re.search(r"platform:tvOS Simulator, arch:\S+, id:([0-9A-F-]{36}), OS:([0-9.]+), name:(Apple TV 4K[^}]*?) \}", line)
    if m:
        found.append(([int(p) for p in m.group(2).split(".")], m.group(1)))
if found:
    print(max(found)[1])
'
}

newest_runtime() {
  xcrun simctl list runtimes available -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "tvOS"]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")
'
}

udid=$(newest_device)
if [ -z "$udid" ]; then
  echo "No Apple TV simulator on this runner; runtimes:" >&2
  xcrun simctl list runtimes >&2
  runtime=$(newest_runtime)
  if [ -z "$runtime" ]; then
    echo "No tvOS runtime: downloading the tvOS platform" >&2
    xcodebuild -downloadPlatform tvOS >&2
    runtime=$(newest_runtime)
  fi
  udid=$(xcrun simctl create "CI Apple TV" com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K "$runtime")
fi
echo "$udid"
