import Testing
import Foundation
@testable import CinemaxKit

@Suite("APICache TTL")
struct APICacheTests {

    @Test("get returns the value before the TTL expires")
    func valueVisibleBeforeExpiry() {
        let cache = APICache()
        cache.set("key.alpha", value: 42, ttl: 10)

        let hit: Int? = cache.get("key.alpha")
        #expect(hit == 42)
    }

    @Test("get returns nil after the TTL expires")
    func valueExpiresAfterTTL() async {
        let cache = APICache()
        cache.set("key.beta", value: "hello", ttl: 0.05) // 50 ms
        try? await Task.sleep(for: .milliseconds(120))

        let miss: String? = cache.get("key.beta")
        #expect(miss == nil)
    }

    @Test("Type-mismatched get returns nil")
    func typeMismatchReturnsNil() {
        let cache = APICache()
        cache.set("key.gamma", value: 42, ttl: 10)

        let miss: String? = cache.get("key.gamma")
        #expect(miss == nil)
    }

    @Test("invalidate(prefix:) drops matching entries only")
    func invalidatePrefixScopesCorrectly() {
        let cache = APICache()
        cache.set("home.resume", value: [1, 2, 3], ttl: 60)
        cache.set("home.latest", value: [4, 5], ttl: 60)
        cache.set("library.items", value: ["movie"], ttl: 60)

        cache.invalidate(prefix: "home.")

        let resume: [Int]? = cache.get("home.resume")
        let latest: [Int]? = cache.get("home.latest")
        let library: [String]? = cache.get("library.items")
        #expect(resume == nil)
        #expect(latest == nil)
        #expect(library == ["movie"])
    }

    @Test("clear() removes all entries")
    func clearRemovesAll() {
        let cache = APICache()
        cache.set("a", value: 1, ttl: 60)
        cache.set("b", value: 2, ttl: 60)

        cache.clear()

        let a: Int? = cache.get("a")
        let b: Int? = cache.get("b")
        #expect(a == nil)
        #expect(b == nil)
    }

    @Test("set sweeps already-expired entries so the store stays bounded")
    func setSweepsExpiredEntries() async {
        let cache = APICache()
        cache.set("stale.a", value: 1, ttl: 0.02) // 20 ms
        cache.set("stale.b", value: 2, ttl: 0.02)
        #expect(cache.storedKeyCount == 2)

        try? await Task.sleep(for: .milliseconds(60))

        // Both keys are now expired; the next write must physically drop them,
        // leaving only the fresh entry — not merely hide them on read.
        cache.set("fresh", value: 3, ttl: 60)
        #expect(cache.storedKeyCount == 1)

        let fresh: Int? = cache.get("fresh")
        #expect(fresh == 3)
    }

    @Test("Set overwrites an existing entry with the newer TTL")
    func setOverwritesExisting() async {
        let cache = APICache()
        cache.set("key.delta", value: 1, ttl: 0.05)
        cache.set("key.delta", value: 99, ttl: 10) // extends TTL

        try? await Task.sleep(for: .milliseconds(120))

        let hit: Int? = cache.get("key.delta")
        #expect(hit == 99)
    }

    // MARK: - Single-flight coalescing

    /// Counts how many times a coalesced operation actually executed. An actor
    /// so concurrent callers can bump it without a data race.
    private actor CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private struct StubError: Error {}

    @Test("coalesce runs the operation once for concurrent callers and delivers the result to both")
    func coalesceRunsOnceForConcurrentCallers() async throws {
        let cache = APICache()
        let counter = CallCounter()

        // Two callers race on the SAME key. The winner registers its in-flight
        // task synchronously (under the lock, before any await), so the loser
        // always joins it instead of firing a second operation.
        async let first: Int = cache.coalesce(key: "flight.item") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(80))
            return 7
        }
        async let second: Int = cache.coalesce(key: "flight.item") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(80))
            return 7
        }

        let (a, b) = try await (first, second)
        #expect(a == 7)
        #expect(b == 7)
        let runs = await counter.count
        #expect(runs == 1)
    }

    @Test("coalesce propagates a thrown error to every in-flight caller")
    func coalescePropagatesErrorToAll() async {
        let cache = APICache()
        let counter = CallCounter()
        let op: @Sendable () async throws -> Int = {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            throw StubError()
        }

        async let first: Int = cache.coalesce(key: "flight.err", operation: op)
        async let second: Int = cache.coalesce(key: "flight.err", operation: op)

        var firstThrew = false
        var secondThrew = false
        do { _ = try await first } catch { firstThrew = true }
        do { _ = try await second } catch { secondThrew = true }

        #expect(firstThrew)
        #expect(secondThrew)
        let runs = await counter.count
        #expect(runs == 1)
    }

    @Test("A failed coalesce does not poison the key — a later call re-executes")
    func coalesceDoesNotPoisonAfterFailure() async throws {
        let cache = APICache()
        let counter = CallCounter()

        do {
            _ = try await cache.coalesce(key: "flight.retry") { () async throws -> Int in
                await counter.increment()
                throw StubError()
            }
            Issue.record("expected the first coalesce to throw")
        } catch {
            // expected — the in-flight entry must be dropped on failure.
        }

        // A subsequent call for the same key must run a fresh operation (proving
        // the failed task was removed, not cached), not re-serve the error.
        let value: Int = try await cache.coalesce(key: "flight.retry") { () async throws -> Int in
            await counter.increment()
            return 99
        }
        #expect(value == 99)
        let runs = await counter.count
        #expect(runs == 2)
    }
}
