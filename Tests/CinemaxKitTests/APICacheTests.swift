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

    @Test("Set overwrites an existing entry with the newer TTL")
    func setOverwritesExisting() async {
        let cache = APICache()
        cache.set("key.delta", value: 1, ttl: 0.05)
        cache.set("key.delta", value: 99, ttl: 10) // extends TTL

        try? await Task.sleep(for: .milliseconds(120))

        let hit: Int? = cache.get("key.delta")
        #expect(hit == 99)
    }
}
