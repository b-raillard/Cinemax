# v2 deferred work

Items pulled out of the v1 App Store submission. Re-add and ship as a v2
feature.

## User-facing Profile Settings screen (iOS)

**Removed in v1:** the "Réglages du profil" row in Settings → Compte was a
stub with an empty action closure — flagged by App Store review as
unresponsive. Removed in `Shared/Screens/Settings/SettingsScreen+iOS.swift`
with a `TODO(v2)` comment pointing here.

**For v2 — build a real `ProfileSettingsScreen` that the row pushes to.**

Routing options:
- Add a new `SettingsCategory.profileSettings` case and dispatch through
  `settingsDetailView(for:)` (cleanest — same nav pattern as the other
  categories).
- Or wire as a nested push from `iOSAccountDetail` (lighter, no new category).

Capabilities for a regular (non-admin) user — what Jellyfin actually permits:
- **Change password** — `POST /Users/Password` (`UpdateUserPassword` in the
  SDK). Requires the current password. Add a confirmation toast on success.
- **Update avatar** — `POST /Users/{userId}/Images/Primary` with image data
  (multipart, base64-encoded body per the Jellyfin spec). Pull image via
  `PhotosPicker` on iOS.

Out of scope for v2:
- Display-name change is admin-only on Jellyfin.
- Policy / access edits are admin-only — already covered by the Admin Users
  surface (`Shared/Screens/Admin/Users/`).

When the screen lands, re-add the FR/EN strings (removed in the same v1
commit):
- `settings.profileSettings` = "Réglages du profil" / "Profile Settings"

tvOS: deferred indefinitely — tvOS has never shown the row, and on-screen
password entry on a remote is poor UX. Keep it iOS-only.
