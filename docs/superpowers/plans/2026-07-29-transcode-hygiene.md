# Hygiène des sessions de transcodage — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fermer proprement le live stream et le job d'encodage que Jellyfin alloue à chaque lecture, et empêcher le serveur de récupérer un transcode encore utilisé pendant une pause.

**Architecture:** `PlaybackReporter` devient le propriétaire unique de la fin de vie d'une session de lecture. Les deux presenters (VLC et natif) héritent du comportement sans modification structurelle, puisqu'ils partagent déjà ce sous-contrôleur et son tick 1 s. Trois méthodes s'ajoutent à la tranche `PlaybackAPI`, toutes avec implémentation par défaut vide.

**Tech Stack:** Swift 6 strict concurrency, CinemaxKit (package local), jellyfin-sdk-swift v0.6.0, swift-testing.

**Spec:** [`docs/superpowers/specs/2026-07-29-transcode-hygiene-design.md`](../specs/2026-07-29-transcode-hygiene-design.md)

## Global Constraints

- Aucune UI, aucun réglage, aucune chaîne localisée dans ce lot.
- Tous les nouveaux appels réseau sont best-effort : `Task.detached`, `try?`, erreur avalée, jamais remontée à l'UI.
- Aucun des nouveaux appels ne passe par `notifyIfUnauthorized` — ils partent pendant un teardown et un 401 transitoire y déclencherait une revalidation de session parasite.
- **Aucun nouveau timer.** Le keep-alive se greffe sur `onTick()`, appelé par l'observateur 1 s que le presenter possède déjà.
- Les trois nouvelles méthodes `PlaybackAPI` ont une implémentation par défaut vide dans une extension du protocole (modèle `SyncPlayAPI`), pour ne pas casser les conformances manuelles existantes.
- Cadence du ping : **30 ticks** (30 s). Conditions cumulatives : `playMethod == .transcode` **ET** lecture en pause.
- `DELETE /Videos/ActiveEncodings` est envoyé **systématiquement** à l'arrêt, sans regarder `playMethod`.
- Tests : suite complète via `xcodebuild test -scheme Cinemax`. `-only-testing` exécute silencieusement 0 test swift-testing — ne jamais s'en servir pour valider.

---

### Task 1 : Le `liveStreamId` traverse jusqu'à l'arrêt

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/PlaybackInfo.swift`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift:169`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift:449`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift` (sites de construction de `PlaybackInfo`)
- Modify: `Shared/Screens/VideoPlayer/PlaybackReporter.swift:89`
- Test: `Tests/CinemaxKitTests/PlaybackReporterTests.swift`

**Interfaces:**
- Consumes: rien (première tâche).
- Produces: `PlaybackInfo.liveStreamId: String?` ; `PlaybackAPI.reportPlaybackStopped(itemId:userId:mediaSourceId:playSessionId:positionTicks:liveStreamId:)` ; sur le mock de test, `CountingPlaybackAPI.lastStopLiveStreamId: String?` et `PlaybackInfo.stubbed(liveStreamId:)`.

- [ ] **Step 1: Étendre le mock et le stub de test**

Dans `Tests/CinemaxKitTests/PlaybackReporterTests.swift`, ajouter le champ au struct `Counts` et l'accesseur, puis mettre la signature de `reportPlaybackStopped` à jour :

```swift
    private struct Counts {
        var start = 0
        var progress = 0
        var stop = 0
        var lastStartTicks: Int?
        var lastProgressTicks: Int?
        var lastStopTicks: Int?
        var lastStopLiveStreamId: String?
    }
```

```swift
    var lastStopLiveStreamId: String? { state.withLock { $0.lastStopLiveStreamId } }
```

```swift
    func reportPlaybackStopped(
        itemId: String, userId: String,
        mediaSourceId: String?, playSessionId: String?,
        positionTicks: Int?, liveStreamId: String?
    ) async {
        state.withLock {
            $0.stop += 1
            $0.lastStopTicks = positionTicks
            $0.lastStopLiveStreamId = liveStreamId
        }
    }
```

Et remplacer l'extension `stubbed()` par une version paramétrée (les appels existants `\.stubbed()` continuent de compiler grâce aux valeurs par défaut) :

```swift
private extension PlaybackInfo {
    static func stubbed(
        playMethod: PlayMethod = .directStream,
        liveStreamId: String? = nil
    ) -> PlaybackInfo {
        PlaybackInfo(
            url: URL(string: "http://localhost/stream")!,
            playSessionId: "session1",
            mediaSourceId: "src1",
            playMethod: playMethod,
            audioTracks: [],
            subtitleTracks: [],
            selectedAudioIndex: nil,
            selectedSubtitleIndex: nil,
            authToken: nil,
            liveStreamId: liveStreamId
        )
    }
}
```

- [ ] **Step 2: Écrire le test qui échoue**

Ajouter dans la suite `PlaybackReporterTests` :

```swift
    @Test("reportStop transmet le liveStreamId de PlaybackInfo")
    func stopCarriesLiveStreamId() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(liveStreamId: "ls-42"), player: nil) }
        )

        reporter.reportStop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(mock.stopCount == 1)
        #expect(mock.lastStopLiveStreamId == "ls-42")
    }

    @Test("reportStop tolère un liveStreamId absent")
    func stopWithoutLiveStreamId() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) }
        )

        reporter.reportStop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(mock.stopCount == 1)
        #expect(mock.lastStopLiveStreamId == nil)
    }
```

- [ ] **Step 3: Lancer les tests pour vérifier l'échec**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```

Attendu : **échec de compilation** — `PlaybackInfo` n'a pas d'argument `liveStreamId`, et la conformance `CountingPlaybackAPI` ne correspond plus au protocole.

- [ ] **Step 4: Ajouter le champ au modèle**

Dans `PlaybackInfo.swift`, après `sourceContainer` :

```swift
    /// Live stream ouvert par le serveur quand la négociation PlaybackInfo porte
    /// `isAutoOpenLiveStream=true`. Renvoyé au serveur dans le rapport d'arrêt
    /// pour qu'il libère la ressource ; nil quand aucun live stream n'a été
    /// ouvert (repli flux direct, qui ne parle pas au serveur).
    public let liveStreamId: String?
```

Ajouter le paramètre à l'initialiseur, en **dernière position avec une valeur par défaut** pour ne pas casser les sites d'appel existants :

```swift
        authToken: String?,
        sourceContainer: String? = nil,
        liveStreamId: String? = nil
```

et l'affectation correspondante :

```swift
        self.liveStreamId = liveStreamId
```

- [ ] **Step 5: Alimenter le champ depuis la réponse serveur**

Dans `JellyfinAPIClient+Playback.swift`, chaque construction de `PlaybackInfo` issue d'une réponse serveur reçoit `liveStreamId: mediaSource.liveStreamID`. Il y a deux sites concernés dans `_getPlaybackInfo` : la branche transcode (celle qui utilise `mediaSource.transcodingURL`) et la branche flux direct qui la suit.

Ajouter l'argument en fin de chaque appel, par exemple pour la branche transcode :

```swift
                    authToken: nil, // token already embedded in Jellyfin's HLS URL
                    liveStreamId: mediaSource.liveStreamID
```

Le repli `buildDirectStreamURL` (qui n'a jamais négocié avec le serveur) garde le défaut `nil` — ne rien y changer.

- [ ] **Step 6: Étendre le contrat de l'arrêt**

Dans `APIClientProtocol.swift`, remplacer la déclaration de `reportPlaybackStopped` :

```swift
    /// Reports that playback has stopped at the given position. Fire-and-forget; errors are silently ignored.
    /// `liveStreamId` — quand non-nil, demande au serveur de libérer le live
    /// stream qu'il avait ouvert pour cette session.
    func reportPlaybackStopped(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, liveStreamId: String?) async
```

Dans `JellyfinAPIClient+Playback.swift`, mettre l'implémentation à jour :

```swift
    public func reportPlaybackStopped(itemId: String, userId: String, mediaSourceId: String?, playSessionId: String?, positionTicks: Int?, liveStreamId: String?) async {
        guard let client = getClient() else { return }
        let body = PlaybackStopInfo(
            itemID: itemId,
            liveStreamID: liveStreamId,
            mediaSourceID: mediaSourceId,
            playSessionID: playSessionId,
            positionTicks: positionTicks
        )
```

Le reste du corps (les invalidations de cache) est inchangé.

- [ ] **Step 7: Transmettre depuis le reporter**

Dans `PlaybackReporter.swift`, dans `reportStop()` :

```swift
            await client.reportPlaybackStopped(
                itemId: itemId, userId: uid,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, liveStreamId: info.liveStreamId
            )
```

- [ ] **Step 8: Lancer les tests pour vérifier le succès**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'Suite "PlaybackReporter|✔|✘|BUILD (SUCCEEDED|FAILED)|error:'
```

Attendu : `Suite "PlaybackReporter throttle"` présente, les deux nouveaux tests passent, `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Packages/CinemaxKit/Sources/CinemaxKit/Networking/PlaybackInfo.swift Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift Shared/Screens/VideoPlayer/PlaybackReporter.swift Tests/CinemaxKitTests/PlaybackReporterTests.swift
git commit -m "feat(playback): transmettre le liveStreamId au rapport d'arrêt"
```

---

### Task 2 : Tuer le job d'encodage à l'arrêt

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift` (protocole `PlaybackAPI` + extension par défaut)
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift`
- Modify: `Shared/Screens/VideoPlayer/PlaybackReporter.swift`
- Test: `Tests/CinemaxKitTests/PlaybackReporterTests.swift`

**Interfaces:**
- Consumes: `PlaybackInfo.liveStreamId` (Task 1).
- Produces: `PlaybackAPI.stopEncoding(playSessionId: String) async` ; sur le mock, `CountingPlaybackAPI.stopEncodingCount: Int` et `CountingPlaybackAPI.callOrder: [String]`.

- [ ] **Step 1: Étendre le mock pour observer l'ordre des appels**

Dans `CountingPlaybackAPI`, ajouter au struct `Counts` :

```swift
        var stopEncoding = 0
        var order: [String] = []
```

les accesseurs :

```swift
    var stopEncodingCount: Int { state.withLock { $0.stopEncoding } }
    var callOrder: [String] { state.withLock { $0.order } }
```

enregistrer l'ordre dans `reportPlaybackStopped` (ajouter la ligne `order`) :

```swift
        state.withLock {
            $0.stop += 1
            $0.lastStopTicks = positionTicks
            $0.lastStopLiveStreamId = liveStreamId
            $0.order.append("stopped")
        }
```

et implémenter la nouvelle méthode :

```swift
    func stopEncoding(playSessionId: String) async {
        state.withLock { $0.stopEncoding += 1; $0.order.append("stopEncoding") }
    }
```

- [ ] **Step 2: Écrire le test qui échoue**

```swift
    @Test("reportStop signale l'arrêt puis tue l'encodage, dans cet ordre")
    func stopThenStopEncoding() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(liveStreamId: "ls-1"), player: nil) }
        )

        reporter.reportStop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.callOrder == ["stopped", "stopEncoding"])
    }

    @Test("stopEncoding part même en DirectPlay")
    func stopEncodingIsUnconditional() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(playMethod: .directPlay), player: nil) }
        )

        reporter.reportStop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.stopEncodingCount == 1)
    }
```

- [ ] **Step 3: Lancer les tests pour vérifier l'échec**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```

Attendu : **échec de compilation** — `stopEncoding` n'existe pas sur `PlaybackAPI`.

- [ ] **Step 4: Déclarer la méthode et son implémentation par défaut**

Dans `APIClientProtocol.swift`, à la fin du protocole `PlaybackAPI` :

```swift
    /// Tue le job d'encodage serveur associé à cette session de lecture.
    /// Idempotent côté serveur : no-op s'il n'y avait pas de transcode.
    func stopEncoding(playSessionId: String) async
}

/// Implémentations par défaut vides — même discipline que `SyncPlayAPI` : les
/// conformances manuelles (mocks de test) n'ont pas à stubber ce qu'elles ne
/// testent pas.
public extension PlaybackAPI {
    func stopEncoding(playSessionId: String) async {}
}
```

- [ ] **Step 5: Implémenter côté client**

Dans `JellyfinAPIClient+Playback.swift`, après `reportPlaybackStopped` :

```swift
    public func stopEncoding(playSessionId: String) async {
        guard let client = getClient() else { return }
        _ = try? await client.send(
            Paths.stopEncodingProcess(deviceID: deviceID, playSessionID: playSessionId)
        )
    }
```

`deviceID` est la propriété interne existante du client (`JellyfinAPIClient.swift:385`) — le reporter n'a pas à la connaître.

- [ ] **Step 6: Enchaîner dans le reporter**

Dans `reportStop()`, la `Task.detached` existante enchaîne les deux appels **séquentiellement** (le serveur doit enregistrer la position de reprise avant qu'on tue le job) :

```swift
        Task.detached {
            await client.reportPlaybackStopped(
                itemId: itemId, userId: uid,
                mediaSourceId: info.mediaSourceId, playSessionId: info.playSessionId,
                positionTicks: positionTicks, liveStreamId: info.liveStreamId
            )
            if let playSessionId = info.playSessionId {
                await client.stopEncoding(playSessionId: playSessionId)
            }
        }
```

- [ ] **Step 7: Lancer les tests pour vérifier le succès**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'Suite "PlaybackReporter|✔|✘|BUILD (SUCCEEDED|FAILED)|error:'
```

Attendu : les deux nouveaux tests passent, `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift Shared/Screens/VideoPlayer/PlaybackReporter.swift Tests/CinemaxKitTests/PlaybackReporterTests.swift
git commit -m "feat(playback): tuer le job d'encodage à l'arrêt de lecture"
```

---

### Task 3 : Keep-alive conditionnel pendant les pauses

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift`
- Modify: `Shared/Screens/VideoPlayer/PlaybackReporter.swift`
- Test: `Tests/CinemaxKitTests/PlaybackReporterTests.swift`

**Interfaces:**
- Consumes: `PlaybackAPI.stopEncoding` (Task 2) — même patron d'extension par défaut.
- Produces: `PlaybackAPI.pingPlaybackSession(playSessionId: String) async` ; sur le mock, `CountingPlaybackAPI.pingCount: Int`.

**Note pour l'implémenteur :** le commentaire en tête de `PlaybackReporterTests` affirme que la logique de tick n'est pas testable sans `AVPlayer`. C'était vrai avant l'ajout de `timeSource`. En injectant ce closure, `currentState` n'a plus besoin du player — les tests ci-dessous exploitent cette porte d'entrée. Mettre le commentaire à jour fait partie de la tâche.

- [ ] **Step 1: Étendre le mock**

Dans `Counts` : `var ping = 0`. Accesseur : `var pingCount: Int { state.withLock { $0.ping } }`. Puis :

```swift
    func pingPlaybackSession(playSessionId: String) async {
        state.withLock { $0.ping += 1 }
    }
```

- [ ] **Step 2: Écrire les tests qui échouent**

```swift
    @Test("ping toutes les 30 s en pause sur un transcode")
    func pingFiresWhilePausedOnTranscode() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(playMethod: .transcode), player: nil) },
            timeSource: { (seconds: 42, isPaused: true) }
        )

        for _ in 0..<60 { reporter.onTick() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.pingCount == 2)
    }

    @Test("aucun ping pendant une lecture active")
    func noPingWhilePlaying() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(playMethod: .transcode), player: nil) },
            timeSource: { (seconds: 42, isPaused: false) }
        )

        for _ in 0..<60 { reporter.onTick() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.pingCount == 0)
    }

    @Test("aucun ping en DirectPlay, même en pause")
    func noPingOnDirectPlay() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(playMethod: .directPlay), player: nil) },
            timeSource: { (seconds: 42, isPaused: true) }
        )

        for _ in 0..<60 { reporter.onTick() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.pingCount == 0)
    }

    @Test("une reprise remet le compteur de ping à zéro")
    func resumeResetsPingCounter() async throws {
        let mock = CountingPlaybackAPI()
        // `isPaused` piloté depuis le test : 20 ticks en pause, 1 en lecture,
        // 20 en pause. Sans remise à zéro, les 40 ticks en pause déclencheraient
        // un ping.
        nonisolated(unsafe) var paused = true
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(playMethod: .transcode), player: nil) },
            timeSource: { (seconds: 42, isPaused: paused) }
        )

        for _ in 0..<20 { reporter.onTick() }
        paused = false
        reporter.onTick()
        paused = true
        for _ in 0..<20 { reporter.onTick() }

        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.pingCount == 0)
    }
```

- [ ] **Step 3: Lancer les tests pour vérifier l'échec**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```

Attendu : **échec de compilation** — `pingPlaybackSession` n'existe pas sur `PlaybackAPI`.

- [ ] **Step 4: Déclarer la méthode et son implémentation par défaut**

Dans `APIClientProtocol.swift`, dans le protocole `PlaybackAPI` à côté de `stopEncoding` :

```swift
    /// Maintient en vie le job d'encodage serveur d'une session de lecture.
    /// N'a d'effet que sur une session transcodée.
    func pingPlaybackSession(playSessionId: String) async
```

et dans l'extension des implémentations par défaut :

```swift
    func pingPlaybackSession(playSessionId: String) async {}
```

- [ ] **Step 5: Implémenter côté client**

Dans `JellyfinAPIClient+Playback.swift`, à côté de `stopEncoding` :

```swift
    public func pingPlaybackSession(playSessionId: String) async {
        guard let client = getClient() else { return }
        _ = try? await client.send(Paths.pingPlaybackSession(playSessionID: playSessionId))
    }
```

- [ ] **Step 6: Implémenter le keep-alive dans le reporter**

Dans `PlaybackReporter.swift`, ajouter la propriété et la constante à côté de `tickCounter` :

```swift
    private var tickCounter = 0
    /// Compteur de ping, indépendant de `tickCounter` : la cadence diffère
    /// (30 s contre 10 s) et le ping porte des conditions que la progression
    /// n'a pas.
    private var pingCounter = 0
    private static let pingTickInterval = 30
```

Étendre `resetTicking()` :

```swift
    func resetTicking() {
        tickCounter = 0
        pingCounter = 0
    }
```

Remanier `onTick()` et ajouter `tickKeepAlive()` :

```swift
    /// Call once per second from the presenter's shared time observer.
    /// Reports progress every 10 ticks (~10 s), and keeps a transcoding session
    /// alive every 30 ticks while paused.
    func onTick() {
        tickCounter += 1
        if tickCounter >= 10 {
            tickCounter = 0
            reportPeriodicProgress()
        }
        tickKeepAlive()
    }

    /// Le serveur récupère un job d'encodage qu'il croit inactif. Tant que le
    /// moteur tire ses segments, le job reste actif tout seul — le ping n'a de
    /// valeur qu'en pause, et uniquement sur une session transcodée (une
    /// session DirectPlay n'a aucun job à maintenir en vie). Toute condition
    /// non remplie remet le compteur à zéro, pour qu'une reprise ne laisse pas
    /// un ping résiduel partir juste après.
    private func tickKeepAlive() {
        guard let ctx = context(),
              ctx.info.playMethod == .transcode,
              let playSessionId = ctx.info.playSessionId,
              let state = currentState(ctx),
              state.isPaused else {
            pingCounter = 0
            return
        }
        pingCounter += 1
        guard pingCounter >= Self.pingTickInterval else { return }
        pingCounter = 0
        let client = apiClient
        Task.detached {
            await client.pingPlaybackSession(playSessionId: playSessionId)
        }
    }
```

- [ ] **Step 7: Mettre à jour le commentaire obsolète de la suite de tests**

En tête de `PlaybackReporterTests.swift`, le bloc `// NB:` affirme que le throttle n'est pas testable sans `AVPlayer`. Le remplacer par :

```swift
    // NB: `Context.player` reste inutilisable sous le test runner (init AVPlayer
    // intermittent en environnement isolé), mais le closure `timeSource` — que
    // le chemin VLC injecte déjà en production — court-circuite entièrement le
    // player dans `currentState`. Les tests de cadence s'en servent pour piloter
    // position et état de pause depuis le test, sans AVFoundation.
```

- [ ] **Step 8: Lancer les tests pour vérifier le succès**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'Suite "PlaybackReporter|✔|✘|BUILD (SUCCEEDED|FAILED)|error:'
```

Attendu : les quatre tests de ping passent, `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift Shared/Screens/VideoPlayer/PlaybackReporter.swift Tests/CinemaxKitTests/PlaybackReporterTests.swift
git commit -m "feat(playback): keep-alive du transcode pendant les pauses"
```

---

### Task 4 : Chemin d'abandon — libérer quand la lecture ne démarre jamais

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift`
- Modify: `Shared/Screens/VideoPlayer/VLCStreamPresenter.swift:3002`
- Modify: `Shared/Screens/NativeVideoPresenter.swift:732`

**Interfaces:**
- Consumes: `PlaybackAPI.stopEncoding` (Task 2), `PlaybackInfo.liveStreamId` (Task 1).
- Produces: `PlaybackAPI.closeLiveStream(liveStreamId: String) async`.

**Note pour l'implémenteur :** cette tâche n'a pas de test unitaire. Le code vit dans des presenters UIKit, hors de portée d'un mock `PlaybackAPI` — c'est consigné comme tel dans le spec. La vérification est manuelle et décrite au Step 5.

- [ ] **Step 1: Déclarer la méthode et son implémentation par défaut**

Dans `APIClientProtocol.swift`, dans le protocole `PlaybackAPI` :

```swift
    /// Libère un live stream ouvert par une négociation PlaybackInfo dont la
    /// lecture n'a jamais démarré. Le chemin nominal n'en a pas besoin : le
    /// `liveStreamId` transmis au rapport d'arrêt suffit.
    func closeLiveStream(liveStreamId: String) async
```

et dans l'extension des implémentations par défaut :

```swift
    func closeLiveStream(liveStreamId: String) async {}
```

- [ ] **Step 2: Implémenter côté client**

Dans `JellyfinAPIClient+Playback.swift` :

```swift
    public func closeLiveStream(liveStreamId: String) async {
        guard let client = getClient() else { return }
        _ = try? await client.send(Paths.closeLiveStream(liveStreamID: liveStreamId))
    }
```

- [ ] **Step 3: Brancher le chemin d'abandon VLC**

Dans `VLCStreamPresenter.swift`, dans `handlePlaybackError()` — au moment où l'échec devient terminal (après épuisement du retry), avant de présenter l'erreur à l'utilisateur. Lire le corps de la méthode pour placer l'appel sur la branche terminale et non sur celle qui retente :

```swift
        // La négociation PlaybackInfo a réussi mais aucune lecture n'aura lieu :
        // rien n'enverra de rapport d'arrêt, donc c'est ici qu'on libère les
        // ressources serveur. Le job d'encodage part inconditionnellement — le
        // moteur a pu tirer assez de segments pour que le serveur en lance un
        // avant d'échouer.
        if let info = playbackInfo {
            let client = apiClient
            Task.detached {
                if let liveStreamId = info.liveStreamId {
                    await client.closeLiveStream(liveStreamId: liveStreamId)
                }
                if let playSessionId = info.playSessionId {
                    await client.stopEncoding(playSessionId: playSessionId)
                }
            }
        }
```

Adapter les noms `playbackInfo` / `apiClient` à ceux réellement utilisés dans ce presenter (les lire avant d'écrire).

- [ ] **Step 4: Brancher le chemin d'abandon natif**

Dans `NativeVideoPresenter.swift`, dans `showPlaybackErrorAlert(error:)` — atteint seulement après épuisement de `retryWithDirectURL` (`:342`). Insérer le même bloc, adapté aux noms locaux du presenter.

- [ ] **Step 5: Vérifier la compilation des deux plateformes**

Sérialiser les deux builds — ils se disputent `build.db` sur la même DerivedData.

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'BUILD (SUCCEEDED|FAILED)|error:'
```

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | grep -E 'BUILD (SUCCEEDED|FAILED)|error:'
```

Attendu : `** BUILD SUCCEEDED **` sur les deux.

Vérification manuelle du comportement (à faire une fois, hors CI) : lancer une lecture sur un conteneur seek-heavy, couper le serveur entre la réponse PlaybackInfo et l'ouverture du flux, et confirmer dans les logs serveur qu'aucun live stream ni job ffmpeg ne subsiste.

- [ ] **Step 6: Commit**

```bash
git add Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Playback.swift Shared/Screens/VideoPlayer/VLCStreamPresenter.swift Shared/Screens/NativeVideoPresenter.swift
git commit -m "feat(playback): libérer les ressources serveur quand la lecture échoue"
```

---

### Task 5 : Documenter dans CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (section « Video Playback »)

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: rien.

**Note pour l'implémenteur :** le dépôt possède un hook `PreToolUse` sur `gh pr create` qui exige que CLAUDE.md soit à jour avant l'ouverture d'une PR. Cette tâche n'est pas optionnelle.

- [ ] **Step 1: Ajouter la RULE**

Dans `CLAUDE.md`, section « Video Playback », après le bloc sur `PlaybackReporter` :

```markdown
- **RULE — le cycle de vie d'une session de lecture appartient à `PlaybackReporter`, pas aux presenters** : `reportStop()` signale l'arrêt **avec le `liveStreamId`** (que `PlaybackInfo` transporte depuis `mediaSource.liveStreamID`) **puis** appelle `stopEncoding` — séquentiellement, le serveur doit enregistrer la position de reprise avant qu'on tue le job. `DELETE /Videos/ActiveEncodings` part **systématiquement**, sans regarder `playMethod` : l'appel est idempotent côté serveur et couvre le cas où le serveur a transcodé sans qu'on l'ait déduit. Un seul propriétaire ⇒ les deux moteurs en héritent ; les presenters ont des teardowns distincts (dismiss iOS, delegate tvOS, nav d'épisode, PiP) et y dupliquer la séquence garantirait qu'un chemin soit oublié. **Keep-alive** : `POST /Playback/Ping` toutes les **30 ticks**, uniquement si `playMethod == .transcode` **ET** lecture en pause — tant que le moteur tire ses segments le job reste actif tout seul, et une session DirectPlay n'a aucun job à maintenir. Coût : zéro requête sur une lecture normale. Toute condition non remplie remet `pingCounter` à zéro (une reprise ne doit pas laisser partir un ping résiduel). **Aucun nouveau timer** — tout passe par l'`onTick()` existant. Le **chemin d'abandon** (PlaybackInfo obtenu, lecture jamais démarrée) est le seul cas traité dans les presenters (`handlePlaybackError`, `showPlaybackErrorAlert`) : `closeLiveStream` + `stopEncoding`, puisque aucun rapport d'arrêt ne partira jamais. Les trois méthodes `PlaybackAPI` ont des **implémentations par défaut vides** (modèle `SyncPlayAPI`) pour ne pas casser les conformances manuelles des mocks de test.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): consigner le cycle de vie des sessions de transcodage"
```

---

## Self-Review

**Couverture du spec** — chaque exigence a sa tâche :

| Exigence du spec | Tâche |
|---|---|
| `PlaybackInfo.liveStreamId` alimenté depuis `mediaSource.liveStreamID` | 1 |
| `liveStreamId` transmis à `Sessions/Playing/Stopped` | 1 |
| `stopEncoding` systématique à l'arrêt, après le rapport d'arrêt | 2 |
| Ping conditionné (transcode ET pause), 30 s, sans nouveau timer | 3 |
| Remise à zéro du compteur à la reprise | 3 |
| `closeLiveStream` réservé au chemin d'abandon, + `stopEncoding` | 4 |
| Implémentations par défaut sur `PlaybackAPI` | 2, 3, 4 |
| Appels best-effort, jamais via `notifyIfUnauthorized` | Contraintes globales ; respecté par `try?` + absence de `notifyIfUnauthorized` dans chaque implémentation |
| Liste de tests du spec | 1 (liveStreamId présent/absent), 2 (ordre, inconditionnalité), 3 (4 cas de ping) |
| Chemin d'abandon non couvert par les tests unitaires | 4, Step 5 (vérification manuelle) |

**Cohérence des types** — `stopEncoding(playSessionId:)` et non `stopEncoding(deviceId:playSessionId:)` comme envisagé dans le spec : le client résout `deviceID` en interne. C'est un resserrement de l'interface, pas une divergence fonctionnelle. `pingPlaybackSession(playSessionId:)`, `closeLiveStream(liveStreamId:)` et `reportPlaybackStopped(..., liveStreamId:)` sont employés à l'identique dans toutes les tâches et dans le mock.

**Écart assumé avec le spec** — le spec disait « le teardown avant première frame passe déjà par `reportStop()` ». La Task 4 le maintient : seul l'échec terminal déclenche le chemin d'abandon, pas un dismiss précoce.
