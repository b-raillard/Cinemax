import Testing
import Foundation
import os
@testable import Cinemax
@testable import CinemaxKit
import JellyfinAPI

/// Tests for `PlaybackReporter` — the @MainActor sub-controller that throttles
/// per-tick progress reports to the server (one report per ten `onTick()` calls
/// from the presenter's shared 1 Hz time observer).
///
/// The reporter fires `Task.detached` for the actual API calls, so we race a
/// short yield window against the counter's public effect. These tests cover
/// the pure throttle logic — network success/failure is server-side and not
/// reachable from a unit test anyway (MockAPIClient stubs return void).
@MainActor
@Suite("PlaybackReporter throttle")
struct PlaybackReporterTests {

    // NB: `Context.player` stays unusable under the test runner (AVPlayer init
    // intermittently fails discovery in an isolated test environment), but the
    // `timeSource` closure — which the VLC path already injects in production —
    // bypasses the player entirely inside `currentState`. The cadence tests
    // drive position and paused state from the test through it, no AVFoundation
    // involved. The 10-tick progress throttle itself still leans on
    // integration/QA for its counter increment.

    @Test("resetTicking clears counter (nil-player path only triggers guard)")
    func resetClearsCounter() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) }
        )
        // Without a player, reportPeriodicProgress guards out — progressCount
        // always 0. This test verifies resetTicking is callable and no fire
        // happens across the reset boundary.
        for _ in 0..<9 { reporter.onTick() }
        reporter.resetTicking()
        for _ in 0..<9 { reporter.onTick() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(mock.progressCount == 0)
    }

    @Test("onTick no-ops when context provider returns nil")
    func noContextNoReport() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { nil }
        )

        for _ in 0..<20 { reporter.onTick() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(mock.progressCount == 0)
    }

    @Test("reportStart fires one reportPlaybackStart")
    func startFires() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) }
        )

        reporter.reportStart(startTime: nil)
        // The API call rides a Task.detached — on a loaded CI host a fixed
        // sleep races its scheduling, so poll (bounded) for the effect instead.
        for _ in 0..<200 where mock.startCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.startCount == 1)
    }

    @Test("reportStart no-ops when context is nil")
    func startWithoutContext() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { nil }
        )
        reporter.reportStart(startTime: nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(mock.startCount == 0)
    }

    // MARK: - Non-finite position guards
    //
    // `AVPlayer.currentTime()` is an invalid CMTime (`.seconds == NaN`) until a
    // player item is attached, and `NativeVideoPresenter.present` creates the
    // player before the async audio-session hop that attaches one. A dismiss or
    // a background inside that window used to trap in `Int(seconds * 10_000_000)`.

    @Test("ticks conversion is NaN/infinity-safe and clamps out-of-range values")
    func ticksConversionIsSafe() {
        #expect(PlaybackReporter.positionTicks(fromSeconds: .nan) == 0)
        #expect(PlaybackReporter.positionTicks(fromSeconds: .infinity) == 0)
        #expect(PlaybackReporter.positionTicks(fromSeconds: -.infinity) == 0)
        #expect(PlaybackReporter.positionTicks(fromSeconds: .signalingNaN) == 0)
        #expect(PlaybackReporter.positionTicks(fromSeconds: 0) == 0)
        #expect(PlaybackReporter.positionTicks(fromSeconds: 12.5) == 125_000_000)
        // Negative positions are meaningless to the server — floor at 0.
        #expect(PlaybackReporter.positionTicks(fromSeconds: -3) == 0)
        // Finite but astronomically large: the multiply itself overflows to
        // +infinity, which must clamp rather than trap.
        #expect(PlaybackReporter.positionTicks(fromSeconds: .greatestFiniteMagnitude) == Int.max)
    }

    @Test("reportStop with a NaN time source reports 0 ticks instead of trapping")
    func stopWithNaNTimeSource() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) },
            timeSource: { (seconds: .nan, isPaused: false) }
        )

        reporter.reportStop()
        for _ in 0..<200 where mock.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.stopCount == 1)
        #expect(mock.lastStopTicks == 0)
    }

    @Test("reportBackgroundProgress with an infinite time source reports 0 ticks")
    func backgroundProgressWithInfiniteTimeSource() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) },
            timeSource: { (seconds: .infinity, isPaused: false) }
        )

        reporter.reportBackgroundProgress()
        for _ in 0..<200 where mock.progressCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.progressCount == 1)
        #expect(mock.lastProgressTicks == 0)
    }

    @Test("periodic progress with a NaN time source reports 0 ticks")
    func periodicProgressWithNaNTimeSource() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) },
            timeSource: { (seconds: .nan, isPaused: true) }
        )

        for _ in 0..<10 { reporter.onTick() }
        for _ in 0..<200 where mock.progressCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.progressCount == 1)
        #expect(mock.lastProgressTicks == 0)
    }

    @Test("reportStart with a NaN startTime reports 0 ticks")
    func startWithNaNStartTime() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) }
        )

        reporter.reportStart(startTime: .nan)
        for _ in 0..<200 where mock.startCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.startCount == 1)
        #expect(mock.lastStartTicks == 0)
    }

    // MARK: - Live stream lifecycle
    //
    // The server opens a live stream for every PlaybackInfo negotiation
    // (`isAutoOpenLiveStream=true`). Handing its id back on the stop report is
    // what lets the server release it — without it the resource lingers.

    @Test("reportStop carries the PlaybackInfo live stream id")
    func stopCarriesLiveStreamId() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(liveStreamId: "ls-42"), player: nil) }
        )

        reporter.reportStop()
        for _ in 0..<200 where mock.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.stopCount == 1)
        #expect(mock.lastStopLiveStreamId == "ls-42")
    }

    @Test("reportStop tolerates a missing live stream id")
    func stopWithoutLiveStreamId() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) }
        )

        reporter.reportStop()
        for _ in 0..<200 where mock.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.stopCount == 1)
        #expect(mock.lastStopLiveStreamId == nil)
    }

    @Test("reportStop reports the stop, then kills the encoding job")
    func stopThenStopEncoding() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(liveStreamId: "ls-1"), player: nil) }
        )

        reporter.reportStop()
        for _ in 0..<200 where mock.stopEncodingCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Order matters: the server must record the resume position before we
        // tear the job down.
        #expect(mock.callOrder == ["stopped", "stopEncoding"])
    }

    @Test("stopEncoding fires even on a DirectPlay session")
    func stopEncodingIsUnconditional() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(playMethod: .directPlay), player: nil) }
        )

        reporter.reportStop()
        for _ in 0..<200 where mock.stopEncodingCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.stopEncodingCount == 1)
    }

    // MARK: - Transcode keep-alive
    //
    // The server reaps an encoding job it believes idle. While the engine is
    // pulling segments the job stays active on its own, so the ping only earns
    // its keep while paused — and only on a transcoding session, since a
    // DirectPlay session has no job to keep alive. Net cost on ordinary
    // playback: zero requests.

    @Test("pings every 30 ticks while paused on a transcode")
    func pingFiresWhilePausedOnTranscode() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(playMethod: .transcode), player: nil) },
            timeSource: { (seconds: 42, isPaused: true) }
        )

        for _ in 0..<60 { reporter.onTick() }
        for _ in 0..<200 where mock.pingCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.pingCount == 2)
    }

    @Test("never pings during active playback")
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

    @Test("never pings a DirectPlay session, even paused")
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

    @Test("resuming resets the ping counter")
    func resumeResetsPingCounter() async throws {
        let mock = CountingPlaybackAPI()
        // 20 ticks paused, one playing, 20 paused. Without the reset the 40
        // paused ticks would cross the 30-tick threshold and fire a ping.
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

    @Test("a finite time source still reports the real position")
    func finiteTimeSourceReportsPosition() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) },
            timeSource: { (seconds: 42, isPaused: false) }
        )

        reporter.reportStop()
        for _ in 0..<200 where mock.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mock.lastStopTicks == 420_000_000)
    }

    // MARK: - Annonce du changement de données utilisateur

    /// Verrouille le correctif du Home périmé : la lecture était le seul
    /// producteur de changement de données utilisateur qui n'annonçait rien, si
    /// bien que l'Accueil affichait encore « 1h 44m restantes » après une
    /// lecture qui avait ramené le film à 1h 43m (mesuré sur appareil le
    /// 2026-08-14, ligne « Reprendre »).

    @Test("Fin de session : l'annonce part APRÈS le rapport au serveur")
    func sessionEndAnnouncesAfterServerReport() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) }
        )
        let witness = NotificationWitness()
        let token = NotificationCenter.default.addObserver(
            forName: .cinemaxItemUserDataChanged, object: nil, queue: nil
        ) { [mock] _ in
            witness.record(stopCountAtPost: mock.stopCount)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        reporter.reportStop()
        for _ in 0..<200 where witness.count == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(witness.count == 1, "une fin de session doit annoncer exactement une fois")
        // Le cœur du test : annoncer AVANT que le serveur ait enregistré la
        // position ferait relire l'ancienne valeur à tous les consommateurs —
        // le bug que cette notification existe pour corriger, en intermittent.
        #expect(witness.stopCountAtPost == 1, "l'annonce doit suivre reportPlaybackStopped, pas le précéder")
    }

    @Test("Changement d'épisode : aucune annonce")
    func episodeSwapStaysSilent() async throws {
        let mock = CountingPlaybackAPI()
        let reporter = PlaybackReporter(
            apiClient: mock, userId: "u1",
            context: { .init(itemId: "item1", info: .stubbed(), player: nil) }
        )
        let witness = NotificationWitness()
        let token = NotificationCenter.default.addObserver(
            forName: .cinemaxItemUserDataChanged, object: nil, queue: nil
        ) { _ in witness.record(stopCountAtPost: 0) }
        defer { NotificationCenter.default.removeObserver(token) }

        reporter.reportStop(reason: .episodeSwap)
        // Attendre que le rapport serveur soit parti, pour que l'absence
        // d'annonce soit un vrai constat et pas une course gagnée de justesse.
        for _ in 0..<200 where mock.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(mock.stopCount == 1, "le serveur doit tout de même recevoir le stop")
        #expect(witness.count == 0, "on regarde encore : rafraîchir les rails ici coûterait une salve par épisode")
    }
}

// MARK: - Test helpers

/// Enregistre les notifications reçues et l'état du serveur À L'INSTANT du post,
/// ce qui est la seule façon d'observer l'ordonnancement depuis un test.
private final class NotificationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0
    private var stopCount = 0

    func record(stopCountAtPost: Int) {
        lock.lock(); defer { lock.unlock() }
        received += 1
        stopCount = stopCountAtPost
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return received }
    var stopCountAtPost: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
}


/// Minimal `PlaybackAPI` conformance that counts calls. Uses
/// `OSAllocatedUnfairLock` because it's async-safe (unlike `NSLock.lock/unlock`
/// which are unavailable from async contexts under Swift 6).
private final class CountingPlaybackAPI: PlaybackAPI, Sendable {
    private struct Counts {
        var start = 0
        var progress = 0
        var stop = 0
        var lastStartTicks: Int?
        var lastProgressTicks: Int?
        var lastStopTicks: Int?
        var lastStopLiveStreamId: String?
        var stopEncoding = 0
        var ping = 0
        /// Call sequence, so a test can assert the stop report lands *before*
        /// the encoding job is killed.
        var order: [String] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: Counts())

    var startCount: Int { state.withLock { $0.start } }
    var progressCount: Int { state.withLock { $0.progress } }
    var stopCount: Int { state.withLock { $0.stop } }
    var lastStartTicks: Int? { state.withLock { $0.lastStartTicks } }
    var lastProgressTicks: Int? { state.withLock { $0.lastProgressTicks } }
    var lastStopTicks: Int? { state.withLock { $0.lastStopTicks } }
    var lastStopLiveStreamId: String? { state.withLock { $0.lastStopLiveStreamId } }
    var stopEncodingCount: Int { state.withLock { $0.stopEncoding } }
    var pingCount: Int { state.withLock { $0.ping } }
    var callOrder: [String] { state.withLock { $0.order } }

    func reportPlaybackStart(
        itemId: String, userId: String,
        mediaSourceId: String?, playSessionId: String?,
        positionTicks: Int?, playMethod: CinemaxKit.PlayMethod
    ) async {
        state.withLock { $0.start += 1; $0.lastStartTicks = positionTicks }
    }

    func reportPlaybackProgress(
        itemId: String, userId: String,
        mediaSourceId: String?, playSessionId: String?,
        positionTicks: Int?, isPaused: Bool, playMethod: CinemaxKit.PlayMethod
    ) async {
        state.withLock { $0.progress += 1; $0.lastProgressTicks = positionTicks }
    }

    func reportPlaybackStopped(
        itemId: String, userId: String,
        mediaSourceId: String?, playSessionId: String?,
        positionTicks: Int?, liveStreamId: String?
    ) async {
        state.withLock {
            $0.stop += 1
            $0.lastStopTicks = positionTicks
            $0.lastStopLiveStreamId = liveStreamId
            $0.order.append("stopped")
        }
    }

    func stopEncoding(playSessionId: String) async {
        state.withLock { $0.stopEncoding += 1; $0.order.append("stopEncoding") }
    }

    func pingPlaybackSession(playSessionId: String) async {
        state.withLock { $0.ping += 1 }
    }

    func getMediaSegments(itemId: String, includeSegmentTypes: [MediaSegmentType]?) async throws -> [MediaSegmentDto] {
        []
    }
}

private extension PlaybackInfo {
    static func stubbed(
        playMethod: CinemaxKit.PlayMethod = .directStream,
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
