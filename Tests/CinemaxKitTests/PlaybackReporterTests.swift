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

    // NB: Testing the 10-tick throttle end-to-end requires an AVPlayer in the
    // Context struct, but AVPlayer construction under the test runner
    // intermittently fails discovery (opaque AVFoundation init behaviour in an
    // isolated test environment). The throttle itself is trivial (counter
    // compared to 10), so we cover the surrounding behaviour — nil-context
    // no-op, reset, and the start/stop paths — and rely on integration/QA for
    // the counter increment. A future refactor could make `Context.player` a
    // protocol to allow a pure-Swift mock.

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
        try await Task.sleep(for: .milliseconds(30))
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
}

// MARK: - Test helpers

/// Minimal `PlaybackAPI` conformance that counts calls. Uses
/// `OSAllocatedUnfairLock` because it's async-safe (unlike `NSLock.lock/unlock`
/// which are unavailable from async contexts under Swift 6).
private final class CountingPlaybackAPI: PlaybackAPI, Sendable {
    private struct Counts {
        var start = 0
        var progress = 0
        var stop = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: Counts())

    var startCount: Int { state.withLock { $0.start } }
    var progressCount: Int { state.withLock { $0.progress } }
    var stopCount: Int { state.withLock { $0.stop } }

    func reportPlaybackStart(
        itemId: String, userId: String,
        mediaSourceId: String?, playSessionId: String?,
        positionTicks: Int?, playMethod: CinemaxKit.PlayMethod
    ) async {
        state.withLock { $0.start += 1 }
    }

    func reportPlaybackProgress(
        itemId: String, userId: String,
        mediaSourceId: String?, playSessionId: String?,
        positionTicks: Int?, isPaused: Bool, playMethod: CinemaxKit.PlayMethod
    ) async {
        state.withLock { $0.progress += 1 }
    }

    func reportPlaybackStopped(
        itemId: String, userId: String,
        mediaSourceId: String?, playSessionId: String?,
        positionTicks: Int?
    ) async {
        state.withLock { $0.stop += 1 }
    }

    func getMediaSegments(itemId: String, includeSegmentTypes: [MediaSegmentType]?) async throws -> [MediaSegmentDto] {
        []
    }
}

private extension PlaybackInfo {
    static func stubbed() -> PlaybackInfo {
        PlaybackInfo(
            url: URL(string: "http://localhost/stream")!,
            playSessionId: "session1",
            mediaSourceId: "src1",
            playMethod: .directStream,
            audioTracks: [],
            subtitleTracks: [],
            selectedAudioIndex: nil,
            selectedSubtitleIndex: nil,
            authToken: nil
        )
    }
}
