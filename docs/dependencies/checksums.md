# Dependency pins and binary artifacts

The reviewed state of every Swift package the app resolves. CI
(`scripts/dependency-audit.py check`, job **Dependency audit** in `ci.yml`)
compares it against `Package.resolved` and fails on any difference, so a
dependency can only move in a pull request that also edits this file.

## What SwiftPM already verifies, and what it does not

- **Binary artifacts are checksum-verified by SwiftPM itself.** A remote
  `.binaryTarget(url:checksum:)` is downloaded and rejected unless the SHA-256
  of the archive equals the `checksum:` written in the *dependency's own*
  `Package.swift`. We do not re-hash the bytes: SwiftPM does it on every
  resolution, locally and in CI.
- **That manifest is fixed by the pinned revision.** `Package.resolved` pins
  each package to a git commit, and the manifest at that commit is what
  declares the checksum. So the chain is: pinned revision → manifest →
  declared checksum → verified archive.
- **What is not verified by anything:** that a revision is one somebody
  reviewed. Any change to `Package.resolved` — a careless "Update to Latest
  Package Versions" in Xcode, a Dependabot PR — silently moves the whole chain,
  binary artifacts included. That is the gap this file closes: the pins below
  are the reviewed list, and CI also re-reads each pinned manifest to check
  that the binary artifacts it declares are exactly the ones recorded here.

Advisories are covered separately by Dependabot (`.github/dependabot.yml`),
which watches `Packages/CinemaxKit` — it cannot read the Xcode project, which
is why the app's `Package.resolved` has to be re-resolved by hand.

## Updating a dependency

1. Bump it (Xcode → *Update Package*, or merge the Dependabot change to
   `Packages/CinemaxKit` and resolve the app project so both
   `Package.resolved` files agree).
2. Update `LicensesView.swift` (hard-coded versions — CI compares them).
3. Update the tables below. For a binary artifact, copy the new `checksum:`
   from the dependency's `Package.swift` at the new revision; read its release
   notes before accepting a changed artifact.
4. `python3 scripts/dependency-audit.py check` locally, then commit all of it
   in one PR.

SwiftVLC is pinned `exactVersion: 1.0.0` on purpose (see CLAUDE.md →
Dependencies) and is excluded from Dependabot.

## Pinned revisions

Source: `Cinemax.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

| Package | Version | Revision |
|---|---|---|
| `get` | `2.2.1` | `31249885da1052872e0ac91a2943f62567c0d96d` |
| `jellyfin-sdk-swift` | `3.1.0` | `50be9e583438be414a15d4bba933ff64b6769a91` |
| `nuke` | `12.9.0` | `83e19143355b02e9261edb2323b3e1e93287ebb9` |
| `swift-atomics` | `1.3.1` | `0442cb5a3f98ab802acb777929fdb446bda11a34` |
| `swift-collections` | `1.6.0` | `a0cb0954ecb21e4e31b0070e6ed5674e8556685a` |
| `swift-nio` | `2.102.0` | `a931f2c1de8dd49381ce3bf2e279d033f68d8865` |
| `swift-nio-transport-services` | `1.28.0` | `67787bb645a5e67d2edcdfbe48a216cc549222d5` |
| `swift-system` | `1.8.1` | `869129b7bf4ecc57b97d0193ad29690ca2134750` |
| `swiftvlc` | `1.0.0` | `192393a45cdcd7ebb6befac26586360b8b1676b3` |

## Binary artifacts

SHA-256 of the archive, as declared by the dependency's manifest at the pinned
revision (SwiftPM verifies the download against it).

| Package | Binary target | SHA-256 | URL |
|---|---|---|---|
| `jellyfin-sdk-swift` | `openapi-generator` | `a882367e67ddb2d23b596992dcde77d522b0c5e7301afe5c49d9c8c6523f8aca` | <https://github.com/LePips/openapi-generator/releases/download/v0.7.1/openapi-generator.artifactbundle.zip> |
| `swiftvlc` | `libvlc` | `23509b945aafb97634d2e66af24a377d7bd50b672aba8f5dec1d6f9ef8614045` | <https://github.com/harflabs/SwiftVLC/releases/download/v1.0.0/libvlc.xcframework.zip> |

`openapi-generator` is a build-tool artifact of the SDK's `GenerateAPI` command
plugin — it is resolved (hence the `-skipPackagePluginValidation` in CI) but
never linked into the app. `libvlc` is linked into both apps and carries
libVLC 4.0.6, the version `LicensesView` credits.
