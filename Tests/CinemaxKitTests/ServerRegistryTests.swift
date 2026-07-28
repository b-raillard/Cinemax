import Testing
import Foundation
@testable import CinemaxKit
@testable import Cinemax

// MARK: - URL normalization

/// The canonical spelling of a server URL is load-bearing twice over: it is the
/// URL we dial AND the key we dedup on. Over-normalizing (dropping a sub-path)
/// 404s every hand-built URL on a reverse-proxied server; under-normalizing
/// lets the same server be registered twice.
@Suite("ServerURLNormalizer")
struct ServerURLNormalizerTests {

    @Test("Scheme-less input defaults to https")
    func schemePrepended() {
        #expect(ServerURLNormalizer.normalize("jellyfin.local")?.absoluteString == "https://jellyfin.local")
    }

    @Test("Scheme and host are case-folded")
    func caseFolded() {
        #expect(ServerURLNormalizer.normalize("HTTPS://Jellyfin.LOCAL")?.absoluteString == "https://jellyfin.local")
    }

    @Test("Default ports are dropped, non-default ports kept")
    func defaultPortsDropped() {
        #expect(ServerURLNormalizer.normalize("https://host:443")?.absoluteString == "https://host")
        #expect(ServerURLNormalizer.normalize("http://host:80")?.absoluteString == "http://host")
        #expect(ServerURLNormalizer.normalize("http://host:8096")?.absoluteString == "http://host:8096")
        // :80 is NOT a default port for https, and vice versa.
        #expect(ServerURLNormalizer.normalize("https://host:80")?.absoluteString == "https://host:80")
    }

    @Test("Trailing slashes are stripped")
    func trailingSlashStripped() {
        #expect(ServerURLNormalizer.normalize("https://host/")?.absoluteString == "https://host")
        #expect(ServerURLNormalizer.normalize("https://host///")?.absoluteString == "https://host")
    }

    @Test("A sub-path is PRESERVED (reverse-proxy hosting)")
    func subPathPreserved() {
        #expect(ServerURLNormalizer.normalize("HTTPS://Host:443/jellyfin/")?.absoluteString == "https://host/jellyfin")
        #expect(ServerURLNormalizer.normalize("https://host/media/jellyfin")?.absoluteString == "https://host/media/jellyfin")
    }

    @Test("Query, fragment and credentials are dropped")
    func junkDropped() {
        #expect(ServerURLNormalizer.normalize("https://host/jellyfin?x=1#frag")?.absoluteString == "https://host/jellyfin")
        #expect(ServerURLNormalizer.normalize("https://user:pw@host")?.absoluteString == "https://host")
    }

    @Test("Non-http(s) schemes and unusable input are rejected")
    func invalidRejected() {
        #expect(ServerURLNormalizer.normalize("not a url at all !!!") == nil)
        #expect(ServerURLNormalizer.normalize("ftp://host") == nil)
        #expect(ServerURLNormalizer.normalize("   ") == nil)
        #expect(ServerURLNormalizer.normalize("https://") == nil)
    }

    /// IPv6 literals survive the `URLComponents` host round-trip with their
    /// brackets. Foundation returns the bracketed form from `.host`, so plain
    /// re-assignment is safe — this test is the tripwire if that ever changes
    /// (the symptom would be `normalize` returning nil for every IPv6 server).
    @Test("IPv6 literals round-trip, brackets intact")
    func ipv6Literal() {
        #expect(ServerURLNormalizer.normalize("https://[::1]:8096")?.absoluteString == "https://[::1]:8096")
        #expect(ServerURLNormalizer.normalize("https://[2001:DB8::1]/jellyfin/")?.absoluteString == "https://[2001:db8::1]/jellyfin")
        #expect(ServerURLNormalizer.normalize("https://[::1]:443")?.absoluteString == "https://[::1]")
    }

    @Test("dedupKey collapses every equivalent spelling into one class")
    func dedupEquivalence() {
        let spellings = [
            "https://host/jellyfin",
            "HTTPS://Host/jellyfin/",
            "https://host:443/jellyfin",
            "https://host/jellyfin?x=1"
        ].compactMap { ServerURLNormalizer.normalize($0) }

        #expect(spellings.count == 4)
        let keys = Set(spellings.map { ServerURLNormalizer.dedupKey($0) })
        #expect(keys.count == 1)
        // A different sub-path is a DIFFERENT server.
        let other = ServerURLNormalizer.normalize("https://host/other")!
        #expect(ServerURLNormalizer.dedupKey(other) != keys.first)
    }
}

// MARK: - Registry logic

@Suite("ServerRegistry")
struct ServerRegistryTests {

    private func entry(
        _ name: String,
        _ urlString: String,
        token: String? = "tok",
        userId: String? = "user1",
        daysAgo: Double = 0
    ) -> ServerEntry {
        ServerEntry(
            name: name,
            url: ServerURLNormalizer.normalize(urlString)!,
            accessToken: token,
            userId: userId,
            username: "U",
            lastUsedAt: Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400)
        )
    }

    // MARK: Active-entry resolution

    @Test("Exact id wins")
    func activeExactId() {
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local", daysAgo: 1)
        #expect(ServerRegistry.activeEntry(in: [a, b], activeId: b.id)?.id == b.id)
    }

    @Test("A stale or missing id falls back to most-recently-used")
    func activeFallback() {
        let old = entry("Old", "https://a.local", daysAgo: 5)
        let recent = entry("Recent", "https://b.local", daysAgo: 1)
        #expect(ServerRegistry.activeEntry(in: [old, recent], activeId: nil)?.id == recent.id)
        #expect(ServerRegistry.activeEntry(in: [old, recent], activeId: "nope")?.id == recent.id)
    }

    @Test("Empty list resolves to nil")
    func activeEmpty() {
        #expect(ServerRegistry.activeEntry(in: [], activeId: "x") == nil)
    }

    // MARK: Sorting

    @Test("Active first, then lastUsedAt descending")
    func sorting() {
        let a = entry("A", "https://a.local", daysAgo: 5)
        let b = entry("B", "https://b.local", daysAgo: 1)
        let c = entry("C", "https://c.local", daysAgo: 3)

        let sorted = ServerRegistry.sorted([a, b, c], activeId: a.id)
        #expect(sorted.map(\.name) == ["A", "B", "C"])

        // With no active id it is pure recency.
        #expect(ServerRegistry.sorted([a, b, c], activeId: nil).map(\.name) == ["B", "C", "A"])
    }

    @Test("Sorting is total (equal timestamps break on id, order is stable)")
    func sortingTotal() {
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local")
        let first = ServerRegistry.sorted([a, b], activeId: nil).map(\.id)
        let second = ServerRegistry.sorted([b, a], activeId: nil).map(\.id)
        #expect(first == second)
    }

    // MARK: Upsert / dedup

    @Test("Upserting an equivalent URL updates in place, preserving the id")
    func upsertDedups() {
        let existing = entry("Old name", "https://host/jellyfin", daysAgo: 5)
        var incoming = entry("New name", "HTTPS://Host:443/jellyfin/")
        incoming.serverVersion = "10.9.0"

        let result = ServerRegistry.upsert(incoming, into: [existing])

        #expect(result.count == 1)
        #expect(result[0].id == existing.id)            // id is referenced by activeServerId
        #expect(result[0].name == "New name")
        #expect(result[0].serverVersion == "10.9.0")
        #expect(result[0].lastUsedAt > existing.lastUsedAt)   // timestamp only moves forward
    }

    @Test("Upserting a different URL appends")
    func upsertAppends() {
        let existing = entry("A", "https://a.local")
        let result = ServerRegistry.upsert(entry("B", "https://b.local"), into: [existing])
        #expect(result.count == 2)
    }

    @Test("contains matches any equivalent spelling")
    func containsProbe() {
        let existing = entry("A", "https://host/jellyfin")
        let probe = ServerURLNormalizer.normalize("https://HOST:443/jellyfin/")!
        #expect(ServerRegistry.contains(url: probe, in: [existing])?.id == existing.id)
        #expect(ServerRegistry.contains(url: URL(string: "https://other.local")!, in: [existing]) == nil)
    }

    // MARK: nextCandidate

    @Test("nextCandidate skips the current entry and every tokenless one")
    func nextCandidate() {
        let current = entry("Current", "https://a.local")
        let tokenless = entry("Signed out", "https://b.local", token: nil, daysAgo: 1)
        let usable = entry("Usable", "https://c.local", daysAgo: 2)
        let older = entry("Older", "https://d.local", daysAgo: 9)

        let picked = ServerRegistry.nextCandidate(after: current.id, in: [current, tokenless, usable, older])
        #expect(picked?.name == "Usable")          // most-recently-used remainder

        #expect(ServerRegistry.nextCandidate(after: current.id, in: [current]) == nil)
        #expect(ServerRegistry.nextCandidate(after: current.id, in: [current, tokenless]) == nil)
    }

    // MARK: decideSwitch truth table

    @Test("decideSwitch: offline short-circuits everything")
    func decideOffline() {
        #expect(ServerRegistry.decideSwitch(entry: entry("A", "https://a.local"), isOnline: false, validity: nil) == .offline)
        #expect(ServerRegistry.decideSwitch(entry: entry("A", "https://a.local"), isOnline: false, validity: .valid) == .offline)
    }

    @Test("decideSwitch: no token needs a login, before any network call")
    func decideNoToken() {
        let tokenless = entry("A", "https://a.local", token: nil)
        #expect(ServerRegistry.decideSwitch(entry: tokenless, isOnline: true, validity: nil) == .needsLogin)
        #expect(ServerRegistry.decideSwitch(entry: entry("A", "https://a.local", token: ""), isOnline: true, validity: nil) == .needsLogin)
    }

    @Test("decideSwitch: the server's answer maps 1:1")
    func decideValidityMapping() {
        let e = entry("A", "https://a.local")
        #expect(ServerRegistry.decideSwitch(entry: e, isOnline: true, validity: nil) == .commit)          // pre-flight
        #expect(ServerRegistry.decideSwitch(entry: e, isOnline: true, validity: .valid) == .commit)
        #expect(ServerRegistry.decideSwitch(entry: e, isOnline: true, validity: .invalid) == .needsLogin)
        // Unprovable failure must never destroy a token.
        #expect(ServerRegistry.decideSwitch(entry: e, isOnline: true, validity: .indeterminate) == .unreachable)
    }

    // MARK: Model

    @Test("ServerEntry round-trips through JSON")
    func codableRoundTrip() throws {
        let original = entry("A", "https://host/jellyfin")
        let decoded = try JSONDecoder().decode(ServerEntry.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test("hasSession vs hasUsableSession")
    func sessionShapes() {
        #expect(entry("A", "https://a.local").hasUsableSession)
        #expect(!entry("A", "https://a.local", token: nil).hasSession)
        #expect(!entry("A", "https://a.local", token: "").hasSession)
        // A token WITHOUT a user id is exactly what `applyActiveServer` refuses.
        let tokenOnly = entry("A", "https://a.local", userId: nil)
        #expect(tokenOnly.hasSession)
        #expect(!tokenOnly.hasUsableSession)
        #expect(!entry("A", "https://a.local", userId: "").hasUsableSession)
    }
}

// MARK: - Migration

/// The single-server → registry migration is the highest-risk piece of the
/// feature: getting it wrong logs every existing user out. It must be additive,
/// idempotent, and must never delete a legacy item.
@Suite("Multi-server migration")
struct MultiServerMigrationTests {

    private func seededKeychain() -> MockKeychain {
        let kc = MockKeychain()
        kc.savedServerURL = URL(string: "HTTPS://Host:443/jellyfin/")!
        kc.savedAccessToken = "tok"
        kc.savedSession = UserSession(userID: "user1", username: "Alice", accessToken: "tok", serverID: "srv1")
        return kc
    }

    @Test("A 1.0.6 install migrates to exactly one active entry")
    func migratesLegacyInstall() {
        let kc = seededKeychain()

        kc.migrateToMultiServerIfNeeded()

        #expect(kc.savedServers.count == 1)
        let entry = kc.savedServers[0]
        #expect(entry.url.absoluteString == "https://host/jellyfin")   // normalized
        #expect(entry.accessToken == "tok")
        #expect(entry.userId == "user1")
        #expect(entry.username == "Alice")
        #expect(entry.serverID == "srv1")
        #expect(kc.savedActiveServerId == entry.id)
    }

    @Test("Migration never deletes a legacy item")
    func legacyItemsSurvive() {
        let kc = seededKeychain()
        kc.migrateToMultiServerIfNeeded()

        #expect(kc.savedServerURL != nil)
        #expect(kc.savedAccessToken == "tok")
        #expect(kc.savedSession?.userID == "user1")
    }

    @Test("Second run is a no-op (idempotent)")
    func idempotent() {
        let kc = seededKeychain()
        kc.migrateToMultiServerIfNeeded()
        let firstId = kc.savedActiveServerId
        let firstEntry = kc.savedServers[0]

        kc.migrateToMultiServerIfNeeded()

        #expect(kc.savedServers.count == 1)
        #expect(kc.savedServers[0] == firstEntry)
        #expect(kc.savedActiveServerId == firstId)
    }

    @Test("An existing registry is never touched")
    func existingRegistryUntouched() {
        let kc = seededKeychain()
        let mine = ServerEntry(name: "Mine", url: URL(string: "https://mine.local")!)
        kc.savedServers = [mine]

        kc.migrateToMultiServerIfNeeded()

        #expect(kc.savedServers == [mine])
        #expect(kc.savedActiveServerId == nil)
    }

    @Test("Fresh install migrates nothing and doesn't crash")
    func freshInstall() {
        let kc = MockKeychain()
        kc.migrateToMultiServerIfNeeded()
        #expect(kc.savedServers.isEmpty)
        #expect(kc.savedActiveServerId == nil)
    }

    @Test("A server URL with no session still produces a (signed-out) entry")
    func serverWithoutSession() {
        let kc = MockKeychain()
        kc.savedServerURL = URL(string: "https://host.local")!

        kc.migrateToMultiServerIfNeeded()

        #expect(kc.savedServers.count == 1)
        #expect(kc.savedServers[0].hasSession == false)
    }
}

// MARK: - AppState orchestration

@MainActor
@Suite("Multi-server AppState")
struct MultiServerAppStateTests {

    private func makeState(
        api: MockAPIClient = MockAPIClient(),
        keychain: MockKeychain = MockKeychain(),
        servers: [ServerEntry] = [],
        activeId: String? = nil
    ) -> AppState {
        keychain.savedServers = servers
        keychain.savedActiveServerId = activeId
        let app = AppState(apiClient: api, keychain: keychain)
        app.loadServersFromKeychain()
        return app
    }

    private func entry(_ name: String, _ urlString: String, token: String? = "tok", userId: String? = "user1") -> ServerEntry {
        ServerEntry(
            name: name,
            url: ServerURLNormalizer.normalize(urlString)!,
            serverID: "srv-\(name)",
            accessToken: token,
            userId: userId,
            username: "U-\(name)"
        )
    }

    // MARK: switchTo

    @Test("A validated switch commits everywhere: state, mirror, client")
    func switchCommits() async {
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let kc = MockKeychain()
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local", userId: "user2")
        let app = makeState(api: api, keychain: kc, servers: [a, b], activeId: a.id)

        let decision = await app.switchTo(b)

        #expect(decision == .commit)
        #expect(app.activeServerId == b.id)
        #expect(app.serverURL == b.url)
        #expect(app.accessToken == "tok")
        #expect(app.currentUserId == "user2")
        #expect(app.isAuthenticated)
        // Legacy mirror follows the active entry (the documented RULE).
        #expect(kc.savedServerURL == b.url)
        #expect(kc.savedSession?.userID == "user2")
        #expect(kc.savedAccessToken == "tok")
        // The client ends up pointed at B and was NEVER pointed anywhere else.
        // `switchTo` deliberately repoints twice — once to validate the token
        // against the target, then again inside `applyActiveServer`, which is
        // the shared commit path (also reached from a rollback / a login, where
        // the client is not yet pointed). `reconnect` rebuilds a local client;
        // it issues no request, so collapsing the two would buy nothing and
        // would mean `applyActiveServer` had to trust its caller.
        #expect(Set(api.reconnectedURLs) == [b.url])
        #expect(api.reconnectedURLs.last == b.url)
        #expect(api.reconnectedTokens.allSatisfy { $0 == "tok" })
        // Cache cleared and the rating cap re-applied after the client rebuild.
        #expect(api.clearCacheCallCount >= 1)
        #expect(api.appliedRatingLimits.count >= 1)
        // lastUsedAt moved forward so B now sorts ahead of A.
        let stored = kc.savedServers.first { $0.id == b.id }
        #expect(stored!.lastUsedAt > b.lastUsedAt)
    }

    @Test("Switching while offline mutates nothing and never dials")
    func switchOffline() async {
        let api = MockAPIClient()
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local")
        let app = makeState(api: api, servers: [a, b], activeId: a.id)
        app.isOnlineProvider = { false }

        let decision = await app.switchTo(b)

        #expect(decision == .offline)
        #expect(app.activeServerId == a.id)
        #expect(api.reconnectedURLs.isEmpty)
        #expect(api.validateSessionCallCount == 0)
    }

    @Test("A confirmed-revoked token clears ONLY that entry and asks for a login")
    func switchInvalidScopesToOneEntry() async {
        let api = MockAPIClient()
        api.stubbedValidity = .invalid
        let kc = MockKeychain()
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local", userId: "user2")
        let app = makeState(api: api, keychain: kc, servers: [a, b], activeId: a.id)

        let decision = await app.switchTo(b)

        #expect(decision == .needsLogin)
        #expect(app.isAuthenticated == false)
        #expect(app.hasServer)                                  // LoginScreen for B
        let storedB = app.servers.first { $0.id == b.id }
        #expect(storedB?.accessToken == nil)
        // A's credentials are untouched — the blast radius is one entry.
        let storedA = app.servers.first { $0.id == a.id }
        #expect(storedA?.accessToken == "tok")
        #expect(storedA?.userId == "user1")
    }

    @Test("Indeterminate keeps the previous server AND the target's token")
    func switchIndeterminatePreservesToken() async {
        let api = MockAPIClient()
        api.stubbedValidity = .indeterminate
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local")
        let app = makeState(api: api, servers: [a, b], activeId: a.id)

        let decision = await app.switchTo(b)

        #expect(decision == .unreachable)
        #expect(app.activeServerId == a.id)
        #expect(app.servers.first { $0.id == b.id }?.accessToken == "tok")
        // Rolled back onto A, not left pointing at B.
        #expect(api.reconnectedURLs.last == a.url)
    }

    @Test("A tokenless target skips the network entirely")
    func switchTokenlessNeedsLogin() async {
        let api = MockAPIClient()
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local", token: nil)
        let app = makeState(api: api, servers: [a, b], activeId: a.id)

        #expect(await app.switchTo(b) == .needsLogin)
        #expect(api.validateSessionCallCount == 0)
        #expect(app.isAuthenticated == false)
    }

    // MARK: logout

    @Test("logout(.userInitiated) hops to the surviving candidate")
    func logoutHops() async {
        let api = MockAPIClient()
        api.stubbedValidity = .valid
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local", userId: "user2")
        let app = makeState(api: api, servers: [a, b], activeId: a.id)
        app.isAuthenticated = true

        let outcome = await app.logout(reason: .userInitiated)

        #expect(outcome == .switchedTo(b))
        #expect(app.activeServerId == b.id)
        #expect(app.isAuthenticated)
        // The signed-out entry stays in the registry, credential-free.
        let storedA = app.servers.first { $0.id == a.id }
        #expect(storedA != nil)
        #expect(storedA?.accessToken == nil)
    }

    @Test("logout(.userInitiated) with nothing to hop to lands on server setup")
    func logoutNoCandidate() async {
        let a = entry("A", "https://a.local")
        let app = makeState(servers: [a], activeId: a.id)
        app.isAuthenticated = true
        app.hasServer = true

        let outcome = await app.logout(reason: .userInitiated)

        #expect(outcome == .signedOut)
        #expect(app.hasServer == false)
        #expect(app.serverURL == nil)
        #expect(app.activeServerId == nil)
        #expect(app.servers.count == 1)          // entry kept so a re-add dedups onto it
    }

    @Test("logout(.sessionExpired) stays on this server's LoginScreen and spares the others")
    func logoutSessionExpired() async {
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local", userId: "user2")
        let app = makeState(servers: [a, b], activeId: a.id)
        app.isAuthenticated = true
        app.hasServer = true
        app.serverURL = a.url

        let outcome = await app.logout(reason: .sessionExpired)

        #expect(outcome == .signedOut)
        #expect(app.isAuthenticated == false)
        // Deliberate: LoginScreen for the SAME server, never ServerSetupScreen.
        #expect(app.hasServer)
        #expect(app.serverURL == a.url)
        #expect(app.activeServerId == a.id)
        // No auto-hop, and B is untouched.
        #expect(app.servers.first { $0.id == b.id }?.accessToken == "tok")
    }

    // MARK: add / rollback

    @Test("beginAddServer keeps the registry and the mirror intact")
    func beginAddPreservesEverything() async {
        let kc = MockKeychain()
        kc.savedServerURL = URL(string: "https://a.local")!
        kc.savedAccessToken = "tok"
        let a = entry("A", "https://a.local")
        let app = makeState(keychain: kc, servers: [a], activeId: a.id)

        app.beginAddServer()

        #expect(app.isAddingServer)
        #expect(app.hasServer == false)          // → ServerSetupScreen
        #expect(app.serverURL == nil)
        #expect(app.pendingRollbackServer?.id == a.id)
        // Nothing was destroyed — a cancelled add must be able to replay.
        #expect(app.servers.count == 1)
        #expect(kc.savedServerURL != nil)
        #expect(kc.savedAccessToken == "tok")
    }

    @Test("Cancelling an add restores the previous server")
    func cancelAddRestores() async {
        let api = MockAPIClient()
        let a = entry("A", "https://a.local")
        let app = makeState(api: api, servers: [a], activeId: a.id)

        app.beginAddServer()
        await app.restorePreviousServer()

        #expect(app.isAddingServer == false)
        #expect(app.pendingRollbackServer == nil)
        #expect(app.hasServer)
        #expect(app.serverURL == a.url)
        #expect(app.activeServerId == a.id)
        #expect(app.isAuthenticated)
    }

    // MARK: removeServer

    @Test("The active server is not removable; another one is")
    func removeServer() async {
        let a = entry("A", "https://a.local")
        let b = entry("B", "https://b.local")
        let app = makeState(servers: [a, b], activeId: a.id)

        await app.removeServer(a)
        #expect(app.servers.count == 2)          // refused

        await app.removeServer(b)
        #expect(app.servers.map(\.id) == [a.id])
    }

    // MARK: upsertActiveEntry

    @Test("A login on an already-registered URL updates in place and marks it active")
    func upsertActiveEntryDedups() {
        let kc = MockKeychain()
        let a = entry("A", "https://host/jellyfin", token: nil, userId: nil)
        let app = makeState(keychain: kc, servers: [a], activeId: nil)
        app.serverURL = ServerURLNormalizer.normalize("HTTPS://Host:443/jellyfin/")!

        app.upsertActiveEntry(session: UserSession(userID: "user9", username: "Nine", accessToken: "fresh", serverID: "srv1"))

        #expect(app.servers.count == 1)
        #expect(app.servers[0].id == a.id)       // id preserved → activeServerId stays meaningful
        #expect(app.activeServerId == a.id)
        #expect(app.servers[0].accessToken == "fresh")
        #expect(app.servers[0].userId == "user9")
        #expect(kc.savedActiveServerId == a.id)
    }
}
