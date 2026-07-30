# Télécommande « Lire sur… » — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Depuis la fiche d'un item, envoyer la lecture sur une autre session Jellyfin de l'utilisateur (`POST /Sessions/{id}/Playing`), sans aucun contrôle depuis l'appareil émetteur.

**Architecture:** Un nouveau tranchant `RemoteControlAPI` (2 méthodes, implémentations par défaut à la `SyncPlayAPI`) expose `GET /Sessions?controllableByUserId=…` et l'ordre `PlayNow`. Un modèle de valeur `RemotePlayTarget` porte la résolution des cibles sous forme de **fonction pure** testable. `MediaDetailViewModel` découvre les cibles dans une `Task` détachée après le chargement principal (comme `loadCollection`) ; l'affordance n'existe que si la liste est non vide. Une feuille sibling `MediaDetailRemotePlay.swift` re-sonde à l'ouverture et envoie.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, `@Observable`, jellyfin-sdk-swift v0.6.0 (`Paths.getSessions`, `Paths.play`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-07-30-remote-play-design.md`

## Global Constraints

- Toute chaîne utilisateur passe par `loc.localized("clé")` — jamais de littéral. Clés dans `Resources/{fr,en}.lproj/Localizable.strings`, les deux fichiers, fr par défaut.
- Jamais `error.localizedDescription` à l'écran : `loc.userFacingMessage(for:)`.
- Aucun `didSet`/`willSet` sur une propriété `@Observable`.
- Pas de littéral numérique nu dans `.font(.system(size:))` — `CinemaScale.pt(...)` ou un token `CinemaFont.*`.
- tvOS : `.sheet` interdit pour un modal → `.fullScreenCover`.
- Tout nouveau fichier sous `Shared/` ou `Tests/` impose `cd . && xcodegen generate` avant de builder. Les fichiers sous `Packages/CinemaxKit/` sont glob-és par SwiftPM et n'en ont pas besoin.
- `project.pbxproj` doit rester la sortie **vierge** de xcodegen : jamais de `git add -A` après un `xcodebuild` (il y injecte `DEVELOPMENT_TEAM`). Toujours `git add <chemins explicites>`.
- Builds : iOS **et** tvOS, en série (pas en parallèle — ils se battent sur `build.db`), avec `set -o pipefail`.
- Tests : `xcodebuild test -scheme Cinemax` sur la suite **entière** (`-only-testing` exécute silencieusement 0 test swift-testing).

## File Structure

| Fichier | Responsabilité |
|---|---|
| `Packages/CinemaxKit/Sources/CinemaxKit/Models/RemotePlayTarget.swift` **(créer)** | Le modèle de valeur `Sendable` + la fonction pure de résolution/filtrage/tri |
| `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift` | Déclarer `RemoteControlAPI` + implémentations par défaut + l'ajouter à `APIClientProtocol` |
| `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+RemoteControl.swift` **(créer)** | Les 2 appels réseau |
| `Shared/ViewModels/MediaDetailViewModel.swift` | `remoteTargets` + `loadRemoteTargets` |
| `Shared/Screens/MediaDetailRemotePlay.swift` **(créer)** | `RemotePlayIntent`, `RemotePlayModel`, `RemotePlaySheet`, `RemotePlayPresentation` |
| `Shared/Screens/MediaDetailScreen.swift` | `startTicks` sur `ResolvedPlayTarget`, le constructeur d'intent, les 2 boutons, le modifier |
| `Resources/{fr,en}.lproj/Localizable.strings` | 7 clés `remote.*` |
| `Tests/CinemaxKitTests/RemotePlayTargetTests.swift` **(créer)** | Le filtrage et le tri, règle par règle |
| `Tests/CinemaxKitTests/MediaDetailViewModelTests.swift` | Peuplement + échec silencieux de `loadRemoteTargets` |
| `Tests/CinemaxKitTests/MockAPIClient.swift` | Stubs + compteurs pour les 2 nouvelles méthodes |
| `CLAUDE.md` | La section et les RULEs |

---

### Task 1: Le modèle de cible et sa résolution pure

**Files:**
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Models/RemotePlayTarget.swift`
- Create: `Tests/CinemaxKitTests/RemotePlayTargetTests.swift`

**Interfaces:**
- Consumes: `SessionInfoDto` (JellyfinAPI), `MediaType` (JellyfinAPI).
- Produces: `RemotePlayTarget { id: String, name: String, clientName: String?, nowPlayingTitle: String? }` et `static func resolve(sessions: [SessionInfoDto], currentUserId: String, excludingDeviceId: String?) -> [RemotePlayTarget]`.

- [ ] **Step 1: Écrire les tests qui échouent**

Dans `Tests/CinemaxKitTests/RemotePlayTargetTests.swift` :

```swift
import Testing
import Foundation
import JellyfinAPI
@testable import Cinemax
@testable import CinemaxKit

@Suite("RemotePlayTarget resolution")
struct RemotePlayTargetTests {
    /// Minimal builder — `SessionInfoDto` has ~25 optional fields and we only
    /// care about the handful the resolver reads.
    private func session(
        id: String? = "s1",
        userId: String? = "user-1",
        deviceId: String? = "device-tv",
        deviceName: String? = "Salon",
        client: String? = "Jellyfin for Apple TV",
        supportsRemoteControl: Bool? = true,
        playableMediaTypes: [MediaType]? = [.video],
        nowPlaying: BaseItemDto? = nil
    ) -> SessionInfoDto {
        var s = SessionInfoDto()
        s.id = id
        s.userID = userId
        s.deviceID = deviceId
        s.deviceName = deviceName
        s.client = client
        s.isSupportsRemoteControl = supportsRemoteControl
        s.playableMediaTypes = playableMediaTypes
        s.nowPlayingItem = nowPlaying
        return s
    }

    @Test("keeps a controllable video session belonging to the current user")
    func keepsValidSession() {
        let out = RemotePlayTarget.resolve(
            sessions: [session()],
            currentUserId: "user-1",
            excludingDeviceId: "device-phone"
        )
        #expect(out.count == 1)
        #expect(out.first?.id == "s1")
        #expect(out.first?.name == "Salon")
        #expect(out.first?.clientName == "Jellyfin for Apple TV")
        #expect(out.first?.nowPlayingTitle == nil)
    }

    @Test("drops our own device — sending to ourselves is the Play button")
    func dropsOwnDevice() {
        let out = RemotePlayTarget.resolve(
            sessions: [session(deviceId: "device-phone")],
            currentUserId: "user-1",
            excludingDeviceId: "device-phone"
        )
        #expect(out.isEmpty)
    }

    @Test("drops a session belonging to another user even if the server returned it")
    func dropsOtherUser() {
        let out = RemotePlayTarget.resolve(
            sessions: [session(userId: "user-2")],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.isEmpty)
    }

    @Test("drops a session with no user id — it can't be verified")
    func dropsUnknownUser() {
        let out = RemotePlayTarget.resolve(
            sessions: [session(userId: nil)],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.isEmpty)
    }

    @Test("drops a session that doesn't support remote control")
    func dropsNonControllable() {
        let out = RemotePlayTarget.resolve(
            sessions: [session(supportsRemoteControl: false), session(id: "s2", supportsRemoteControl: nil)],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.isEmpty)
    }

    @Test("drops a session with no id — it can't be addressed")
    func dropsMissingId() {
        let out = RemotePlayTarget.resolve(
            sessions: [session(id: nil), session(id: "")],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.isEmpty)
    }

    @Test("drops an audio-only session but keeps one that reports nothing")
    func videoCapability() {
        let out = RemotePlayTarget.resolve(
            sessions: [
                session(id: "audio", playableMediaTypes: [.audio]),
                session(id: "unknown", playableMediaTypes: nil),
                session(id: "empty", playableMediaTypes: [])
            ],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.map(\.id).sorted() == ["empty", "unknown"])
    }

    @Test("falls back to the client name when the device has none")
    func nameFallback() {
        let out = RemotePlayTarget.resolve(
            sessions: [session(deviceName: nil), session(id: "s2", deviceId: "d2", deviceName: "", client: nil)],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.first(where: { $0.id == "s1" })?.name == "Jellyfin for Apple TV")
        #expect(out.first(where: { $0.id == "s2" })?.name == "")
    }

    @Test("surfaces what the target is already playing")
    func nowPlaying() {
        var playing = BaseItemDto()
        playing.name = "Dune"
        let out = RemotePlayTarget.resolve(
            sessions: [session(nowPlaying: playing)],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        #expect(out.first?.nowPlayingTitle == "Dune")
    }

    @Test("sorts by device name, diacritic- and case-insensitively, then by id")
    func sorting() {
        let out = RemotePlayTarget.resolve(
            sessions: [
                session(id: "c", deviceId: "d1", deviceName: "Zèbre"),
                session(id: "b", deviceId: "d2", deviceName: "salon"),
                session(id: "a", deviceId: "d3", deviceName: "Salon")
            ],
            currentUserId: "user-1",
            excludingDeviceId: nil
        )
        // "Salon" == "salon" under the fold, so the session id breaks the tie.
        #expect(out.map(\.id) == ["a", "b", "c"])
    }
}
```

- [ ] **Step 2: Lancer les tests et vérifier qu'ils échouent**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "^/.*error:|✘ |Test run with|\*\* TEST"
```

Attendu : erreur de compilation « cannot find 'RemotePlayTarget' in scope ».

- [ ] **Step 3: Écrire le modèle et le résolveur**

`Packages/CinemaxKit/Sources/CinemaxKit/Models/RemotePlayTarget.swift` :

```swift
import Foundation
import JellyfinAPI

/// One Jellyfin session this user can drive from here — the "Play on…" picker's
/// row model. A flattened, `Sendable` projection of `SessionInfoDto`: the DTO
/// itself carries a `BaseItemDto` and isn't Sendable, and the view only needs
/// these four strings.
public struct RemotePlayTarget: Identifiable, Sendable, Equatable {
    /// Jellyfin session id — what `POST /Sessions/{id}/Playing` addresses.
    public let id: String
    /// Best-effort device name. May be empty: the view localizes the fallback
    /// (the model has no `LocalizationManager`).
    public let name: String
    /// Client app name ("Jellyfin for Apple TV"), shown as the row subtitle.
    public let clientName: String?
    /// What the target is already playing, when it is — warns the user that
    /// sending will interrupt something.
    public let nowPlayingTitle: String?

    public init(id: String, name: String, clientName: String?, nowPlayingTitle: String?) {
        self.id = id
        self.name = name
        self.clientName = clientName
        self.nowPlayingTitle = nowPlayingTitle
    }

    /// Filters and orders the sessions the server returned into sendable targets.
    ///
    /// Pure on purpose — the filtering rules are exactly where a silent mistake
    /// costs the most (sending a film to a stranger's TV), so they're locked by
    /// unit tests rather than by an eyeball check.
    ///
    /// **RULE — the `userID == currentUserId` test is defense in depth, not
    /// redundancy.** `GET /Sessions?controllableByUserId=` is supposed to filter
    /// server-side, but the unfiltered endpoint leaks every user's session to
    /// non-admins on some servers (jellyfin#5210); a server that ignored the
    /// parameter would otherwise let one tap start a film on someone else's TV.
    /// A session with no `userID` can't be verified and is dropped.
    public static func resolve(
        sessions: [SessionInfoDto],
        currentUserId: String,
        excludingDeviceId: String?
    ) -> [RemotePlayTarget] {
        sessions
            .filter { session in
                guard let id = session.id, !id.isEmpty else { return false }
                guard session.userID == currentUserId else { return false }
                guard session.isSupportsRemoteControl == true else { return false }
                if let excludingDeviceId, session.deviceID == excludingDeviceId { return false }
                // Older clients under-report their capabilities, so an absent
                // or empty list is treated as "unknown", not as "no video".
                if let types = session.playableMediaTypes, !types.isEmpty,
                   !types.contains(.video) { return false }
                return true
            }
            .map { session in
                let device = session.deviceName ?? ""
                let name = device.isEmpty ? (session.client ?? "") : device
                return RemotePlayTarget(
                    id: session.id ?? "",
                    name: name,
                    clientName: session.client,
                    nowPlayingTitle: session.nowPlayingItem?.name
                )
            }
            // Total order: the name folds case and diacritics, so equal names
            // fall through to the session id and the list stays stable between
            // two polls instead of shuffling under the user's finger.
            .sorted { lhs, rhs in
                let cmp = lhs.name.compare(
                    rhs.name,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: nil,
                    locale: nil
                )
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            }
    }
}
```

- [ ] **Step 4: Relancer les tests et vérifier qu'ils passent**

Même commande qu'à l'étape 2. Attendu : `Suite "RemotePlayTarget resolution" passed`.

- [ ] **Step 5: Commit**

```bash
git add Packages/CinemaxKit/Sources/CinemaxKit/Models/RemotePlayTarget.swift Tests/CinemaxKitTests/RemotePlayTargetTests.swift
git commit -m "feat(remote): résoudre les sessions pilotables en cibles d'envoi"
```

*(Si `xcodegen generate` est nécessaire pour que le nouveau fichier de test soit compilé, le lancer avant l'étape 2 et ajouter `Cinemax.xcodeproj/project.pbxproj` au commit.)*

---

### Task 2: Le tranchant `RemoteControlAPI`

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift`
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+RemoteControl.swift`
- Modify: `Tests/CinemaxKitTests/MockAPIClient.swift`

**Interfaces:**
- Consumes: `RemotePlayTarget` (Task 1) — non, en fait rien : ce tranchant renvoie des `SessionInfoDto` bruts, la résolution se fait au-dessus.
- Produces:
  - `func getControllableSessions(userId: String) async throws -> [SessionInfoDto]`
  - `func playOnSession(sessionId: String, itemIds: [String], startPositionTicks: Int?, mediaSourceId: String?) async throws`
  - `APIClientProtocol` inclut désormais `RemoteControlAPI`.

- [ ] **Step 1: Déclarer le protocole et ses implémentations par défaut**

Dans `APIClientProtocol.swift`, après le bloc `SyncPlayAPI` (protocole **et** son extension de valeurs par défaut, pour rester lisible) :

```swift
// MARK: - Remote control ("Play on…")

/// Driving *another* Jellyfin session — the "Play on…" picker. Deliberately its
/// own slice rather than an addition to `PlaybackAPI` (which is about reporting
/// *local* playback) or `AuthAPI` (which owns session *listing*).
///
/// Both members carry empty default implementations, on the `SyncPlayAPI` model,
/// so hand-written test mocks compile without stubbing calls they don't exercise.
public protocol RemoteControlAPI: Sendable {
    /// Sessions the given user is allowed to drive. Uses Jellyfin's
    /// `controllableByUserId` filter, so **no elevated rights are needed** —
    /// unlike the unfiltered `getActiveSessions` (admin-gated in this app
    /// because it leaks every user's session on some servers).
    func getControllableSessions(userId: String) async throws -> [SessionInfoDto]

    /// Tells a session to play an item now. Fire-and-forget by design: this app
    /// sends and stops there — see the "Remote control" section in CLAUDE.md.
    func playOnSession(
        sessionId: String,
        itemIds: [String],
        startPositionTicks: Int?,
        mediaSourceId: String?
    ) async throws
}

public extension RemoteControlAPI {
    func getControllableSessions(userId: String) async throws -> [SessionInfoDto] { [] }
    func playOnSession(
        sessionId: String,
        itemIds: [String],
        startPositionTicks: Int?,
        mediaSourceId: String?
    ) async throws {}
}
```

Puis étendre la composition (chercher la ligne existante) :

```swift
public typealias APIClientProtocol = ServerAPI & AuthAPI & LibraryAPI & PlaybackAPI & AdminAPI & SyncPlayAPI & RemoteControlAPI
```

- [ ] **Step 2: Implémenter les 2 appels**

`Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+RemoteControl.swift` :

```swift
import Foundation
import JellyfinAPI

extension JellyfinAPIClient {
    /// `GET /Sessions?controllableByUserId=…&activeWithinSeconds=300`
    ///
    /// The 5-minute window bounds staleness explicitly rather than trusting the
    /// server's own idea of "active": a device that checked in within five
    /// minutes is realistically still there, and a stale entry would only cost
    /// a no-op command the server drops.
    public func getControllableSessions(userId: String) async throws -> [SessionInfoDto] {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.GetSessionsParameters(
            controllableByUserID: userId,
            activeWithinSeconds: 300
        )
        do {
            let response = try await client.send(Paths.getSessions(parameters: params))
            return response.value
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }

    /// `POST /Sessions/{id}/Playing?playCommand=PlayNow`
    public func playOnSession(
        sessionId: String,
        itemIds: [String],
        startPositionTicks: Int? = nil,
        mediaSourceId: String? = nil
    ) async throws {
        guard let client = getClient() else { throw JellyfinError.notConnected }
        let params = Paths.PlayParameters(
            playCommand: .playNow,
            itemIDs: itemIds,
            startPositionTicks: startPositionTicks,
            mediaSourceID: mediaSourceId
        )
        do {
            _ = try await client.send(Paths.play(sessionID: sessionId, parameters: params))
        } catch {
            notifyIfUnauthorized(error)
            throw error
        }
    }
}
```

- [ ] **Step 3: Outiller le mock**

Dans `Tests/CinemaxKitTests/MockAPIClient.swift`, près des autres stubs :

```swift
    // MARK: - Remote control
    var stubbedControllableSessions: [SessionInfoDto] = []
    var controllableSessionsError: Error?
    var controllableSessionsCallCount = 0
    /// Every `playOnSession` call, in order.
    var playOnSessionCalls: [(sessionId: String, itemIds: [String], startPositionTicks: Int?, mediaSourceId: String?)] = []
    var playOnSessionError: Error?

    func getControllableSessions(userId: String) async throws -> [SessionInfoDto] {
        controllableSessionsCallCount += 1
        if let controllableSessionsError { throw controllableSessionsError }
        return stubbedControllableSessions
    }

    func playOnSession(
        sessionId: String,
        itemIds: [String],
        startPositionTicks: Int?,
        mediaSourceId: String?
    ) async throws {
        playOnSessionCalls.append((sessionId, itemIds, startPositionTicks, mediaSourceId))
        if let playOnSessionError { throw playOnSessionError }
    }
```

- [ ] **Step 4: Builder pour vérifier la conformance**

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5
```

Attendu : `** BUILD SUCCEEDED **`. Un `does not conform to protocol 'RemoteControlAPI'` signifierait que les implémentations par défaut manquent.

- [ ] **Step 5: Commit**

```bash
git add Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+RemoteControl.swift Tests/CinemaxKitTests/MockAPIClient.swift
git commit -m "feat(remote): tranchant RemoteControlAPI — sessions pilotables et ordre PlayNow"
```

---

### Task 3: La découverte des cibles dans le view model

**Files:**
- Modify: `Shared/ViewModels/MediaDetailViewModel.swift`
- Modify: `Tests/CinemaxKitTests/MediaDetailViewModelTests.swift`

**Interfaces:**
- Consumes: `RemotePlayTarget.resolve` (Task 1), `getControllableSessions` (Task 2), `KeychainService.getOrCreateDeviceID()`.
- Produces: `MediaDetailViewModel.remoteTargets: [RemotePlayTarget]`, `func loadRemoteTargets(using appState: AppState) async`.

- [ ] **Step 1: Écrire les tests qui échouent**

Ajouter dans `Tests/CinemaxKitTests/MediaDetailViewModelTests.swift` (adapter les helpers aux conventions déjà présentes dans le fichier) :

```swift
    @Test("loadRemoteTargets keeps only the sessions the user can drive")
    @MainActor
    func loadRemoteTargetsPopulates() async {
        let api = MockAPIClient()
        var mine = SessionInfoDto()
        mine.id = "s1"
        mine.userID = "user-1"
        mine.deviceID = "apple-tv"
        mine.deviceName = "Salon"
        mine.isSupportsRemoteControl = true
        var other = SessionInfoDto()
        other.id = "s2"
        other.userID = "user-2"
        other.deviceID = "someone-else"
        other.isSupportsRemoteControl = true
        api.stubbedControllableSessions = [mine, other]

        let appState = AppState(apiClient: api)
        appState.currentUserId = "user-1"
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)

        await vm.loadRemoteTargets(using: appState)

        #expect(api.controllableSessionsCallCount == 1)
        #expect(vm.remoteTargets.map(\.id) == ["s1"])
    }

    @Test("loadRemoteTargets swallows a failure — no targets, no error on screen")
    @MainActor
    func loadRemoteTargetsSwallowsFailure() async {
        let api = MockAPIClient()
        api.controllableSessionsError = MockError.genericFailure
        let appState = AppState(apiClient: api)
        appState.currentUserId = "user-1"
        let vm = MediaDetailViewModel(itemId: "movie-1", itemType: .movie)

        await vm.loadRemoteTargets(using: appState)

        #expect(vm.remoteTargets.isEmpty)
        #expect(vm.errorMessage == nil)
    }
```

- [ ] **Step 2: Lancer les tests et vérifier qu'ils échouent**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "^/.*error:|✘ |Test run with|\*\* TEST"
```

Attendu : « value of type 'MediaDetailViewModel' has no member 'remoteTargets' ».

- [ ] **Step 3: Implémenter**

Propriété, près de `collectionItems` :

```swift
    /// Jellyfin sessions this user can send the item to ("Play on…"). Resolved
    /// after the main load, like `loadCollection`, so a slow or failing
    /// `/Sessions` never delays the detail render. Empty ⇒ no affordance drawn.
    var remoteTargets: [RemotePlayTarget] = []
```

Méthode, près de `loadCollection` :

```swift
    /// Discovers the sessions the "Play on…" affordance can target.
    ///
    /// **Deliberately silent on failure**: no target is the ordinary case (a
    /// session only exists while Jellyfin is actually running on the other
    /// device), so a failed probe must degrade to "no button", never to an
    /// error state over an otherwise-fine detail screen.
    func loadRemoteTargets(using appState: AppState) async {
        guard let userId = appState.currentUserId else { return }
        do {
            let sessions = try await appState.apiClient.getControllableSessions(userId: userId)
            remoteTargets = RemotePlayTarget.resolve(
                sessions: sessions,
                currentUserId: userId,
                excludingDeviceId: KeychainService.getOrCreateDeviceID()
            )
        } catch {
            logger.debug("Remote targets probe failed: \(error.localizedDescription, privacy: .public)")
            remoteTargets = []
        }
    }
```

Et le lancer depuis `load()`, dans le même bloc que `loadCollection` (juste avant `isLoading = false`), sans `guard` de type puisque tout item est envoyable :

```swift
        // Side probe, like the collection lookup: never blocks the render, and
        // its failure is invisible.
        Task { await loadRemoteTargets(using: appState) }
```

- [ ] **Step 4: Relancer les tests**

Même commande. Attendu : les deux nouveaux tests passent, aucune régression.

- [ ] **Step 5: Commit**

```bash
git add Shared/ViewModels/MediaDetailViewModel.swift Tests/CinemaxKitTests/MediaDetailViewModelTests.swift
git commit -m "feat(remote): découvrir les cibles d'envoi depuis la fiche"
```

---

### Task 4: La feuille de sélection et les deux affordances

**Files:**
- Create: `Shared/Screens/MediaDetailRemotePlay.swift`
- Modify: `Shared/Screens/MediaDetailScreen.swift`
- Modify: `Resources/fr.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `RemotePlayTarget` (Task 1), `playOnSession` / `getControllableSessions` (Task 2), `MediaDetailViewModel.remoteTargets` (Task 3), `MediaDetailScreen.resolvedPlayTarget` / `selectedSource`.
- Produces: `RemotePlayIntent { itemId, title, startPositionTicks, mediaSourceId }`, `RemotePlaySheet`, `RemotePlayPresentation`.

- [ ] **Step 1: Ajouter les 7 clés dans les deux fichiers**

`Resources/fr.lproj/Localizable.strings` :

```
"remote.title" = "Lire sur…";
"remote.sent" = "Lecture lancée sur %@";
"remote.unknownDevice" = "Appareil inconnu";
"remote.idle" = "Prêt";
"remote.nowPlaying" = "lit %@";
"remote.noTargets.title" = "Aucun appareil disponible";
"remote.noTargets.subtitle" = "Ouvre Jellyfin sur l'appareil cible : il doit être allumé et connecté au serveur pour apparaître ici.";
```

`Resources/en.lproj/Localizable.strings` :

```
"remote.title" = "Play on…";
"remote.sent" = "Started playing on %@";
"remote.unknownDevice" = "Unknown device";
"remote.idle" = "Ready";
"remote.nowPlaying" = "playing %@";
"remote.noTargets.title" = "No device available";
"remote.noTargets.subtitle" = "Open Jellyfin on the target device — it has to be awake and connected to the server to show up here.";
```

- [ ] **Step 2: Écrire la feuille**

`Shared/Screens/MediaDetailRemotePlay.swift` — voir le corps complet dans la section « Code de la feuille » ci-dessous. Structure : `RemotePlayIntent` (Identifiable, Hashable), `RemotePlayModel` (`@MainActor @Observable`, `targets`/`isLoading`/`errorMessage`/`busy`), `RemotePlaySheet` (corps iOS et tvOS séparés, à l'image de `WatchTogetherSheet`), `RemotePlayPresentation` (ViewModifier, `.sheet` iOS / `.fullScreenCover` tvOS, ré-injection des objets d'environnement).

- [ ] **Step 3: Câbler dans `MediaDetailScreen`**

1. Ajouter `let startTicks: Int?` à `ResolvedPlayTarget` et le renseigner dans `resolvedPlayTarget` : `startTicks: showResume ? posTicks : nil`.
2. `@State private var remotePlaySheet: RemotePlayIntent?`.
3. Le constructeur d'intent :

```swift
    /// What "Play on…" sends: the same target the local Play button would open,
    /// through the same single-sourced resolution.
    private func remotePlayIntent(for item: BaseItemDto) -> RemotePlayIntent {
        let target = resolvedPlayTarget(for: item)
        return RemotePlayIntent(
            itemId: target.itemId.isEmpty ? viewModel.itemId : target.itemId,
            title: target.title,
            startPositionTicks: target.startTicks,
            // For a series the play target is an episode, whose media sources
            // aren't the ones the version row ranked (those belong to the
            // parent) — so the override only travels for the item itself.
            mediaSourceId: target.nextEpisode == nil ? selectedSource(item)?.id : nil
        )
    }
```

4. Le modifier, après `WatchTogetherPresentation` :

```swift
        .modifier(RemotePlayPresentation(
            sheet: $remotePlaySheet,
            appState: appState,
            themeManager: themeManager,
            loc: loc,
            toast: toast
        ))
```

5. iOS — une puce dans `secondaryActionsRow`, après la bande-annonce :

```swift
            // "Play on…" — only when a controllable session actually exists.
            // Deliberately NOT the AirPlay glyph: this is not AirPlay, and the
            // phone keeps no controls after sending.
            if network.isOnline, !viewModel.remoteTargets.isEmpty {
                secondaryActionCell(
                    systemImage: "tv.badge.wifi",
                    active: false,
                    accessibility: loc.localized("remote.title"),
                    trigger: false
                ) {
                    remotePlaySheet = remotePlayIntent(for: item)
                }
            }
```

6. tvOS — un bouton fantôme dans la rangée d'action, après `watchedButton` :

```swift
            if network.isOnline, !viewModel.remoteTargets.isEmpty {
                remotePlayButton(for: item)
            }
```

avec, à côté de `watchTogetherButton` :

```swift
    /// "Play on…" in the tvOS action row — moves the film to another room.
    private func remotePlayButton(for item: BaseItemDto) -> some View {
        Button {
            remotePlaySheet = remotePlayIntent(for: item)
        } label: {
            Image(systemName: "tv.badge.wifi")
                .font(.system(size: buttonFontSize, weight: .bold))
                .foregroundStyle(CinemaColor.onSurface)
                .padding(.vertical, buttonVerticalPadding)
                .padding(.horizontal, CinemaSpacing.spacing4)
        }
        .buttonStyle(CinemaTVButtonStyle(cinemaStyle: .ghost))
        .accessibilityLabel(loc.localized("remote.title"))
    }
```

- [ ] **Step 4: Régénérer le projet, builder les deux plateformes, relancer les tests**

```bash
xcodegen generate
```

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -3
```

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | tail -3
```

Attendu : `** BUILD SUCCEEDED **` deux fois. Puis la suite de tests complète.

- [ ] **Step 5: Commit**

```bash
git add Shared/Screens/MediaDetailRemotePlay.swift Shared/Screens/MediaDetailScreen.swift Resources/fr.lproj/Localizable.strings Resources/en.lproj/Localizable.strings Cinemax.xcodeproj/project.pbxproj
git commit -m "feat(remote): feuille « Lire sur… » sur la fiche, iOS et tvOS"
```

#### Code de la feuille

```swift
import SwiftUI
import CinemaxKit

// MARK: - "Play on…" (Jellyfin remote control)
//
// Presented from `MediaDetailScreen`. Lists the Jellyfin sessions this user can
// drive and sends `PlayNow` to the one they pick. Deliberately send-only: after
// the command lands the phone has NO transport controls — those two banner
// controllers (`PlaybackLiveActivityController`, `NowPlayingInfoController`) are
// attached by the local presenters only, and nothing plays locally here. The
// user pilots from the target device's own remote. See CLAUDE.md.

/// The item a "Play on…" send targets — resolved through
/// `MediaDetailScreen.resolvedPlayTarget`, so it carries the same episode,
/// resume position and version the local Play button would have opened.
struct RemotePlayIntent: Identifiable, Hashable {
    let id = UUID()
    let itemId: String
    let title: String
    let startPositionTicks: Int?
    let mediaSourceId: String?
}

/// Screen-scoped model: the target list plus transient busy/error state.
@MainActor
@Observable
final class RemotePlayModel {
    var targets: [RemotePlayTarget] = []
    var isLoading = false
    var errorMessage: String?
    /// True while a send is in flight — disables every row.
    var busy = false

    /// Re-probes the sessions when the sheet opens.
    ///
    /// The detail screen already probed once (that's what decided the button
    /// should exist), but that snapshot can be minutes old and this call is the
    /// one a command will be sent against — so it has to be fresh.
    func load(userId: String?, api: any RemoteControlAPI, loc: LocalizationManager) async {
        guard let userId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let sessions = try await api.getControllableSessions(userId: userId)
            targets = RemotePlayTarget.resolve(
                sessions: sessions,
                currentUserId: userId,
                excludingDeviceId: KeychainService.getOrCreateDeviceID()
            )
        } catch {
            errorMessage = loc.userFacingMessage(for: error)
        }
    }
}

struct RemotePlaySheet: View {
    let intent: RemotePlayIntent

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toast

    @State private var model = RemotePlayModel()

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        NavigationStack {
            iosBody
                .navigationTitle(loc.localized("remote.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(loc.localized("action.done")) { dismiss() }
                            .tint(themeManager.accent)
                    }
                }
        }
        #endif
    }

    #if os(iOS)
    private var iosBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CinemaSpacing.spacing4) {
                itemHeader
                targetList
            }
            .padding(CinemaSpacing.spacing4)
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .refreshable { await reload() }
        .task { await reload() }
    }
    #endif

    #if os(tvOS)
    private var tvBody: some View {
        ZStack {
            CinemaColor.surface.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing6) {
                    HStack {
                        Text(loc.localized("remote.title"))
                            .font(CinemaFont.headline(.large))
                            .foregroundStyle(CinemaColor.onSurface)
                        Spacer()
                        CinemaButton(title: loc.localized("action.done"), style: .ghost) { dismiss() }
                            .frame(width: 240)
                    }
                    .focusSection()

                    itemHeader
                    targetList
                }
                .padding(CinemaSpacing.spacing8)
            }
        }
        .task { await reload() }
    }
    #endif

    // MARK: - Shared pieces

    private var itemHeader: some View {
        Text(intent.title)
            .font(CinemaFont.body)
            .foregroundStyle(CinemaColor.onSurfaceVariant)
            .lineLimit(2)
    }

    @ViewBuilder
    private var targetList: some View {
        if model.isLoading {
            LoadingStateView()
        } else if let error = model.errorMessage {
            ErrorStateView(message: error, retryTitle: loc.localized("action.retry")) {
                Task { await reload() }
            }
        } else if model.targets.isEmpty {
            EmptyStateView(
                systemImage: "tv.slash",
                title: loc.localized("remote.noTargets.title"),
                subtitle: loc.localized("remote.noTargets.subtitle")
            )
        } else {
            VStack(spacing: CinemaSpacing.spacing3) {
                ForEach(model.targets) { target in
                    targetRow(target)
                }
            }
        }
    }

    private func targetRow(_ target: RemotePlayTarget) -> some View {
        Button {
            send(to: target)
        } label: {
            HStack(spacing: CinemaSpacing.spacing3) {
                Image(systemName: "tv")
                    .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(target))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurface)
                        .lineLimit(1)
                    Text(subtitle(target))
                        .font(CinemaFont.label(.small))
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: CinemaSpacing.spacing2)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: CinemaScale.pt(22), weight: .semibold))
                    .foregroundStyle(themeManager.accent)
            }
            .padding(CinemaSpacing.spacing4)
            .glassPanel()
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .accessibilityLabel(displayName(target))
        .accessibilityHint(loc.localized("remote.title"))
    }

    private func displayName(_ target: RemotePlayTarget) -> String {
        target.name.isEmpty ? loc.localized("remote.unknownDevice") : target.name
    }

    private func subtitle(_ target: RemotePlayTarget) -> String {
        var parts: [String] = []
        if let client = target.clientName, !client.isEmpty { parts.append(client) }
        if let playing = target.nowPlayingTitle, !playing.isEmpty {
            parts.append(loc.localized("remote.nowPlaying", playing))
        }
        return parts.isEmpty ? loc.localized("remote.idle") : parts.joined(separator: " • ")
    }

    // MARK: - Actions

    private func reload() async {
        await model.load(userId: appState.currentUserId, api: appState.apiClient, loc: loc)
    }

    private func send(to target: RemotePlayTarget) {
        guard !model.busy, !intent.itemId.isEmpty else { return }
        Task {
            model.busy = true
            do {
                try await appState.apiClient.playOnSession(
                    sessionId: target.id,
                    itemIds: [intent.itemId],
                    startPositionTicks: intent.startPositionTicks,
                    mediaSourceId: intent.mediaSourceId
                )
                model.busy = false
                toast.success(loc.localized("remote.sent", displayName(target)))
                dismiss()
            } catch {
                model.busy = false
                toast.error(loc.userFacingMessage(for: error))
            }
        }
    }
}

// MARK: - Presentation

/// Presents the picker — a bottom sheet on iOS, a full-screen cover on tvOS
/// (`.sheet` renders as a broken narrow modal on tvOS 26). Environment objects
/// are re-injected so the sheet's own `@Environment` reads resolve regardless of
/// automatic propagation. Same shape as `WatchTogetherPresentation`.
struct RemotePlayPresentation: ViewModifier {
    @Binding var sheet: RemotePlayIntent?
    let appState: AppState
    let themeManager: ThemeManager
    let loc: LocalizationManager
    let toast: ToastCenter

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.fullScreenCover(item: $sheet) { intent in sheetView(intent) }
        #else
        content.sheet(item: $sheet) { intent in sheetView(intent) }
        #endif
    }

    private func sheetView(_ intent: RemotePlayIntent) -> some View {
        RemotePlaySheet(intent: intent)
            .environment(appState)
            .environment(themeManager)
            .environment(loc)
            .environment(toast)
    }
}
```

---

### Task 5: Consigner dans CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Ajouter la section**

Après la section « SyncPlay / Watch Together » de `## Video Playback`, une sous-section `### Télécommande — « Lire sur… »` couvrant : le tranchant `RemoteControlAPI` et ses défauts vides ; la RULE du double filtre `controllableByUserId` + `userID == currentUserId` ; la RULE « la découverte ne bloque ni ne casse le rendu » ; la RULE « pas de contrôle après l'envoi, et pourquoi (les deux contrôleurs de bandeau sont attachés par les presenters locaux) » ; la RULE « `mediaSourceId` seulement quand la cible est l'item » ; le choix du glyphe non-AirPlay.

Mettre aussi à jour :
- la ligne `APIClientProtocol = …` dans « API protocol split » ;
- l'arbre `Project Structure` (ajouter `MediaDetailRemotePlay` aux siblings `MediaDetail*` et `RemotePlayTarget` aux modèles CinemaxKit).

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): consigner la télécommande « Lire sur… »"
```

---

## Self-Review

**Couverture du spec** — objectif : Tasks 2+4. Filtrage/tri : Task 1. Découverte non bloquante : Task 3. Gating du bouton : Task 4 (étapes 5-6). Reprise/version : Task 4 (étape 3, points 1 et 3). Feuille re-sondante : Task 4 (`RemotePlayModel.load`). Les 7 clés : Task 4 étape 1. Tests : Tasks 1 et 3. Builds deux plateformes : Task 4 étape 4. Doc : Task 5.

**Cohérence des types** — `RemotePlayTarget.resolve(sessions:currentUserId:excludingDeviceId:)` : même signature dans le modèle (T1), le view model (T3) et `RemotePlayModel` (T4). `playOnSession(sessionId:itemIds:startPositionTicks:mediaSourceId:)` : même signature dans le protocole (T2), le mock (T2) et l'appel de la feuille (T4). `RemotePlayIntent` : construit en T4 étape 3, consommé en T4 étape 2, mêmes 4 champs.

**Point de vigilance** — le tuple `[(sessionId:…)]` du mock n'est pas `Equatable` ; les assertions devront lire les champs (`calls.first?.sessionId`) plutôt que comparer le tuple entier.
