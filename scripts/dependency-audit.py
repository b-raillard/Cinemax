#!/usr/bin/env python3
"""Dependency audit for Cinemax — Python stdlib only, no toolchain install.

    scripts/dependency-audit.py check [--offline]
    scripts/dependency-audit.py sbom  [--output FILE]

`check` exits 1 when any of these drift, each of which must be acknowledged in
the SAME pull request that moves a dependency:

  pins       A pin in the app's Package.resolved (added, removed, or moved to
             another revision) disagrees with the reviewed list recorded in
             docs/dependencies/checksums.md.
  sync       Packages/CinemaxKit/Package.resolved pins a package at another
             revision than the app's Package.resolved. Dependabot can only edit
             the former (it has no Xcode-project support), while CI builds from
             the latter, so a Dependabot PR must fail here until the app's copy
             is re-resolved too.
  licenses   A version hard-coded in LicensesView.swift disagrees with its pin.
  artifacts  (skipped with --offline) A `.binaryTarget(url:checksum:)` declared
             by a pinned dependency's manifest, fetched at the pinned revision,
             differs from the recorded SHA-256 — or appears without having been
             recorded at all.

`sbom` prints a CycloneDX 1.5 JSON document built from the app's
Package.resolved plus the recorded binary artifacts.

See docs/dependencies/checksums.md for what SwiftPM already verifies on its own
and why this recorded list exists on top of it.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_RESOLVED = ROOT / "Cinemax.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
KIT_RESOLVED = ROOT / "Packages/CinemaxKit/Package.resolved"
RECORD = ROOT / "docs/dependencies/checksums.md"
LICENSES_VIEW = ROOT / "Shared/Screens/LicensesView.swift"
PROJECT_YML = ROOT / "project.yml"

# LicensesView display name -> Package.resolved identity. An entry here must
# match its pin exactly.
LICENSE_PINS = {
    "Jellyfin SDK Swift": "jellyfin-sdk-swift",
    "SwiftVLC": "swiftvlc",
    "Nuke": "nuke",
    "Get": "get",
}
# LicensesView entries that legitimately have no SwiftPM pin of their own.
LICENSE_UNPINNED = {
    "libVLC": "embedded in SwiftVLC's libvlc.xcframework (see the binary artifacts table)",
}

ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|(?:\s*<?([^|>]*)>?\s*\|)?\s*$")
BINARY_TARGET = re.compile(
    r"\.binaryTarget\(\s*name:\s*\"([^\"]+)\"\s*,\s*url:\s*\"([^\"]+)\"\s*,\s*checksum:\s*\"([0-9a-fA-F]{64})\"",
    re.S,
)
LICENSE_ENTRY = re.compile(r"OSSLicense\(\s*name:\s*\"([^\"]+)\"\s*,\s*version:\s*\"([^\"]+)\"", re.S)


def load_pins(path: Path) -> dict[str, dict]:
    data = json.loads(path.read_text())
    pins = {}
    for pin in data["pins"]:
        state = pin["state"]
        pins[pin["identity"]] = {
            "location": pin["location"],
            "version": state.get("version") or state.get("branch") or "",
            "revision": state["revision"],
        }
    return pins


def load_record() -> tuple[dict[str, tuple[str, str]], dict[tuple[str, str], tuple[str, str]]]:
    """Returns ({identity: (version, revision)}, {(identity, target): (sha256, url)})."""
    pins: dict[str, tuple[str, str]] = {}
    artifacts: dict[tuple[str, str], tuple[str, str]] = {}
    section = None
    for line in RECORD.read_text().splitlines():
        if line.startswith("## "):
            title = line[3:].strip().lower()
            section = "pins" if title.startswith("pinned") else "artifacts" if title.startswith("binary") else None
            continue
        match = ROW.match(line)
        if not match or section is None:
            continue
        first, second, third, fourth = match.groups()
        if section == "pins":
            pins[first] = (second, third)
        else:
            artifacts[(first, second)] = (third.lower(), (fourth or "").strip())
    if not pins:
        sys.exit(f"error: no pinned revisions parsed from {RECORD.relative_to(ROOT)}")
    return pins, artifacts


def github_raw_manifest(location: str, revision: str) -> str | None:
    match = re.match(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", location)
    if not match:
        return None
    owner, repo = match.groups()
    url = f"https://raw.githubusercontent.com/{owner}/{repo}/{revision}/Package.swift"
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode()


def check(offline: bool) -> int:
    errors: list[str] = []
    warnings: list[str] = []
    app = load_pins(APP_RESOLVED)
    kit = load_pins(KIT_RESOLVED)
    recorded_pins, recorded_artifacts = load_record()
    record_name = RECORD.relative_to(ROOT)

    # pins
    for identity in sorted(set(app) | set(recorded_pins)):
        if identity not in recorded_pins:
            errors.append(f"pins: `{identity}` {app[identity]['version']} is resolved but not recorded in {record_name}")
        elif identity not in app:
            errors.append(f"pins: `{identity}` is recorded in {record_name} but no longer resolved")
        else:
            version, revision = recorded_pins[identity]
            if (version, revision) != (app[identity]["version"], app[identity]["revision"]):
                errors.append(
                    f"pins: `{identity}` moved from {version} ({revision[:12]}) to "
                    f"{app[identity]['version']} ({app[identity]['revision'][:12]}) — review it and update {record_name}"
                )

    # sync
    for identity in sorted(set(app) & set(kit)):
        if app[identity]["revision"] != kit[identity]["revision"]:
            errors.append(
                f"sync: `{identity}` is {kit[identity]['version']} ({kit[identity]['revision'][:12]}) in "
                f"Packages/CinemaxKit/Package.resolved but {app[identity]['version']} "
                f"({app[identity]['revision'][:12]}) in the app's Package.resolved — resolve packages in Xcode "
                f"and commit both"
            )
    for identity in sorted(set(kit) - set(app)):
        errors.append(f"sync: `{identity}` is pinned by CinemaxKit but missing from the app's Package.resolved")

    # licenses
    listed = LICENSE_ENTRY.findall(LICENSES_VIEW.read_text())
    if not listed:
        errors.append("licenses: no OSSLicense(name:version:) entries parsed from LicensesView.swift")
    credited = set()
    for name, version in listed:
        if name in LICENSE_PINS:
            identity = LICENSE_PINS[name]
            credited.add(identity)
            pinned = app.get(identity, {}).get("version")
            if pinned != version:
                errors.append(f"licenses: LicensesView lists {name} {version}, Package.resolved pins {pinned}")
        elif name not in LICENSE_UNPINNED:
            warnings.append(f"licenses: LicensesView lists {name} {version}, which no longer appears in Package.resolved")
    for identity in sorted(set(app) - credited):
        warnings.append(f"licenses: `{identity}` {app[identity]['version']} is resolved but not credited in LicensesView")

    # artifacts
    if offline:
        warnings.append("artifacts: skipped (--offline)")
    else:
        declared: dict[tuple[str, str], tuple[str, str]] = {}
        for identity, pin in sorted(app.items()):
            try:
                manifest = github_raw_manifest(pin["location"], pin["revision"])
            except (urllib.error.URLError, TimeoutError) as error:
                errors.append(f"artifacts: could not fetch `{identity}`'s manifest at {pin['revision'][:12]}: {error}")
                continue
            if manifest is None:
                warnings.append(f"artifacts: `{identity}` is not hosted on github.com — manifest not inspected")
                continue
            for target, url, checksum in BINARY_TARGET.findall(manifest):
                declared[(identity, target)] = (checksum.lower(), url)
        for key in sorted(set(declared) | set(recorded_artifacts)):
            identity, target = key
            if key not in recorded_artifacts:
                errors.append(f"artifacts: `{identity}` declares binary target `{target}` ({declared[key][0]}) — not recorded in {record_name}")
            elif key not in declared:
                errors.append(f"artifacts: `{identity}` no longer declares binary target `{target}` — remove it from {record_name}")
            elif declared[key][0] != recorded_artifacts[key][0]:
                errors.append(
                    f"artifacts: `{identity}`/`{target}` checksum is {declared[key][0]}, "
                    f"recorded {recorded_artifacts[key][0]} — update {record_name}"
                )

    for message in warnings:
        print(f"::warning::{message}")
    for message in errors:
        print(f"::error::{message}")
    if errors:
        print(f"dependency audit: {len(errors)} error(s)")
        return 1
    print(f"dependency audit: OK — {len(app)} pins, {len(recorded_artifacts)} binary artifacts"
          + (" (checksums not fetched)" if offline else ""))
    return 0


def purl_for(location: str, version: str) -> str | None:
    match = re.match(r"https://([^/]+)/([^/]+)/([^/]+?)(?:\.git)?/?$", location)
    if not match:
        return None
    host, owner, repo = match.groups()
    return f"pkg:swift/{host}/{owner}/{repo}@{version}"


def sbom(output: str | None) -> int:
    app = load_pins(APP_RESOLVED)
    _, recorded_artifacts = load_record()
    app_version_match = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', PROJECT_YML.read_text())
    app_version = app_version_match.group(1) if app_version_match else "0"
    origin_hash = json.loads(APP_RESOLVED.read_text()).get("originHash", "")

    components = []
    for identity, pin in sorted(app.items()):
        purl = purl_for(pin["location"], pin["version"])
        name = pin["location"].rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]
        components.append({
            "type": "library",
            "bom-ref": purl or f"swiftpm:{identity}",
            "name": name,
            "version": pin["version"],
            **({"purl": purl} if purl else {}),
            "externalReferences": [{"type": "vcs", "url": pin["location"]}],
            "properties": [
                {"name": "swiftpm:identity", "value": identity},
                {"name": "swiftpm:revision", "value": pin["revision"]},
            ],
        })
    for (identity, target), (checksum, url) in sorted(recorded_artifacts.items()):
        parent = next((c["bom-ref"] for c in components if c["properties"][0]["value"] == identity), None)
        components.append({
            "type": "library",
            "bom-ref": f"swiftpm-binary:{identity}/{target}",
            "name": target,
            # SwiftPM's checksum is the SHA-256 of the downloaded archive.
            "hashes": [{"alg": "SHA-256", "content": checksum}],
            **({"externalReferences": [{"type": "distribution", "url": url}]} if url else {}),
            "properties": [{"name": "swiftpm:binaryTargetOf", "value": parent or identity}],
        })

    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tools": {"components": [{"type": "application", "name": "scripts/dependency-audit.py"}]},
            "component": {"type": "application", "bom-ref": "cinemax", "name": "Cinemax", "version": app_version},
            "properties": [{"name": "swiftpm:originHash", "value": origin_hash}],
        },
        "components": components,
        "dependencies": [{"ref": "cinemax", "dependsOn": [c["bom-ref"] for c in components]}],
    }
    text = json.dumps(document, indent=2) + "\n"
    if output:
        Path(output).write_text(text)
    else:
        sys.stdout.write(text)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    check_parser = sub.add_parser("check", help="fail on unreviewed dependency drift")
    check_parser.add_argument("--offline", action="store_true", help="skip fetching pinned manifests")
    sbom_parser = sub.add_parser("sbom", help="print a CycloneDX 1.5 JSON SBOM")
    sbom_parser.add_argument("--output", help="write to this file instead of stdout")
    args = parser.parse_args()
    return check(args.offline) if args.command == "check" else sbom(args.output)


if __name__ == "__main__":
    sys.exit(main())
