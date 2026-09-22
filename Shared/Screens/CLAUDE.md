# Shared/Screens — where each screen's rules live

This folder is flat, so its features cannot each have a `CLAUDE.md`. **Before editing a screen, open the rules file for it** (they are not loaded automatically):

| Screen / feature | Rules |
|---|---|
| `ServerSetupScreen`, `LoginScreen`, `PreAuthChrome`, `QuickConnect*`, `ServerHelpSheet`, `ServersScreen`, `OnboardingScreen` | `docs/rules/server-setup-and-multi-server.md` |
| `MovieLibraryScreen.swift` (`MediaLibraryScreen`), `Library*`, `MediaCardContextMenu`, `CardActionPresenter` | `docs/rules/media-library.md` |
| `MediaDetailScreen`, `MediaDetail*`, `PersonDetailScreen` | `docs/rules/media-detail.md` |
| `MediaDetailRemotePlay`, `RemoteControlListener` | `docs/rules/remote-control.md` |
| `HomeScreen`, `FavoritesScreen`, `WatchedHistoryScreen` | `docs/rules/home.md` (+ the Watch History bullet in `Settings/CLAUDE.md`) |
| `SearchScreen` | `docs/rules/search.md` |
| `AddToPlaylistSheet`, `PlaylistDetailScreen`, `LibraryFolderBrowseScreen` | `docs/rules/playlists.md` (+ the Collections / Playlists RULE in `Shared/Navigation/CLAUDE.md`) |
| `WatchTogetherLobby`, `MediaDetailWatchTogether` | `VideoPlayer/CLAUDE.md` → SyncPlay / Watch Together |
| `PrivacySecurityScreen`, `ProfileScreen`, `LicensesView` | `Settings/CLAUDE.md` |
| `NativeVideoPresenter`, `VideoPlayerView`, `PlayLink`, `HLSManifestLoader` | `VideoPlayer/CLAUDE.md` |

Any UI change also reads `Shared/DesignSystem/CLAUDE.md`. The sub-folders `VideoPlayer/`, `Settings/` and `Admin/` carry their own `CLAUDE.md`, loaded automatically.
