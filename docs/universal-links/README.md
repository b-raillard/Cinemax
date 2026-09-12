# Universal Links — hosting the AASA

The iOS app declares `applinks:b-raillard.github.io` (`project.yml`, iOS target) and
`DeepLinkRoute.universalLinkHost` carries the same host. For iOS to route
`https://b-raillard.github.io/item/<id>` and `/home` into the app, that host must
serve the file next to this README at its **root**:

```
https://b-raillard.github.io/.well-known/apple-app-site-association
```

## Why not this repo's Pages site

This repository's GitHub Pages is a *project* site served under
`https://b-raillard.github.io/Cinemax/` (source: `docs/`). A project site cannot
serve anything at the host root, so the AASA cannot live here. It needs the
**user site** repository `b-raillard/b-raillard.github.io`, whose Pages output is
the host root — or a custom domain, in which case change the host in both
`project.yml` and `DeepLinkRoute.universalLinkHost`.

## Deploying to the user site

1. Create the repository `b-raillard/b-raillard.github.io` (public, Pages on `main`, root).
2. Copy `apple-app-site-association` (no extension) to `.well-known/apple-app-site-association`.
3. Add an empty `.nojekyll` at the root — Jekyll ignores dot-directories, so without it
   `.well-known/` is not published.
4. Optionally add an `index.html` and an `item/index.html` saying "Open in Cinemax",
   so a link opened on a device without the app does not 404.

## Verifying before any device test

Both the origin and Apple's CDN copy must answer a direct `200`, `application/json`,
no redirect, and contain `4T334S4NP6.com.cinemax.ios`:

```bash
curl -si https://b-raillard.github.io/.well-known/apple-app-site-association
curl -si https://app-site-association.cdn-apple.com/a/v1/b-raillard.github.io
```

Apple's CDN refreshes on its own schedule (hours to a day). On a development
device, `Settings → Developer → Universal Links → Diagnostics` shows whether the
entitlement matched the served file.

## What the file claims, deliberately

- `components` are scoped to `/item/*` and `/home` only. Nothing else on the host
  is claimed, so any other page under that host keeps opening in Safari.
- No `webcredentials`, no `activitycontinuation`: this is navigation only. The
  same "never add a play verb" rule as the custom scheme applies — the app
  validates the item id and never starts playback from a link.
- The Team ID is public information (it is in every signed binary); the file is
  safe to commit.
