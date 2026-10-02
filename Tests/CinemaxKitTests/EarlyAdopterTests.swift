import Foundation
import Testing
@testable import Cinemax

private func build(_ string: String) -> BuildNumber {
    guard let number = BuildNumber(string) else {
        Issue.record("\(string) should parse")
        return BuildNumber(components: [0])
    }
    return number
}

private let pivotDate = Date(timeIntervalSinceReferenceDate: 820_000_000)

private func transaction(
    _ originalAppVersion: String,
    purchased: Date = pivotDate.addingTimeInterval(86_400),
    environment: AppTransactionSnapshot.Environment = .production
) -> AppTransactionSnapshot {
    AppTransactionSnapshot(
        originalAppVersion: originalAppVersion,
        originalPurchaseDate: purchased,
        environment: environment
    )
}

@Suite("Build number comparison")
struct BuildNumberTests {
    @Test("Dotted build numbers parse into their numeric components", arguments: [
        ("250", [250]),
        ("2.3.2", [2, 3, 2]),
        ("1.0.10", [1, 0, 10]),
        (" 3.0 ", [3, 0]),
        ("007", [7]),
    ])
    func parses(raw: String, components: [Int]) {
        #expect(BuildNumber(raw)?.components == components)
    }

    @Test("Anything but dot-separated digits is refused", arguments: [
        "", " ", "1.", ".1", "1..2", "1a", "-1", "+1", "1.0b3", "1,0", "v2", "1 .0", "١٢",
    ])
    func refuses(raw: String) {
        #expect(BuildNumber(raw) == nil)
    }

    @Test("Missing trailing components count as zero: 1 == 1.0 == 1.0.0")
    func trailingZeros() {
        #expect(build("1") == build("1.0"))
        #expect(build("1.0") == build("1.0.0"))
        #expect(!(build("1") < build("1.0.0")))
        #expect(!(build("1.0.0") < build("1")))
    }

    @Test("Components compare as numbers, not as text", arguments: [
        ("1.0.2", "1.0.10"),
        ("2.9", "2.10"),
        ("9", "10"),
        ("2.3.2", "3.0"),
        ("2.3.2", "2.4"),
        ("1", "1.0.1"),
        ("2.99.99", "3"),
    ])
    func ordering(lower: String, higher: String) {
        #expect(build(lower) < build(higher))
        #expect(!(build(higher) < build(lower)))
        #expect(build(lower) != build(higher))
    }

    @Test("Every build number this project ever shipped sorts in shipping order")
    func projectHistory() {
        let shipped = ["1", "1.0.1", "1.0.2", "2.0.0", "2.3.1", "2.3.2"].map(build)
        #expect(shipped == shipped.sorted())
    }
}

@Suite("Early adopter policy")
struct EarlyAdopterPolicyTests {
    private let byBuild = EarlyAdopterConfiguration(pivotBuild: BuildNumber("3.0"), pivotDate: nil)
    private let byDate = EarlyAdopterConfiguration(pivotBuild: nil, pivotDate: pivotDate)
    private let byEither = EarlyAdopterConfiguration(pivotBuild: BuildNumber("3.0"), pivotDate: pivotDate)

    @Test("A first install older than the pivot build is an early adopter")
    func olderBuildIsEarly() {
        #expect(EarlyAdopterPolicy.evaluate(transaction("2.3.2"), configuration: byBuild) == .earlyAdopter)
        #expect(EarlyAdopterPolicy.evaluate(transaction("1"), configuration: byBuild) == .earlyAdopter)
    }

    @Test("The pivot build itself and anything after it are regular", arguments: ["3.0", "3", "3.0.0", "3.0.1", "10"])
    func pivotAndLaterAreRegular(original: String) {
        #expect(EarlyAdopterPolicy.evaluate(transaction(original), configuration: byBuild) == .regular)
    }

    @Test("Sandbox, TestFlight and Xcode report « 1.0 » — never an early adopter, whatever the pivots")
    func nonProductionIsNeverEarly() {
        for environment in [AppTransactionSnapshot.Environment.sandbox, .xcode] {
            let sandbox = transaction("1.0", purchased: pivotDate.addingTimeInterval(-86_400), environment: environment)
            #expect(EarlyAdopterPolicy.evaluate(sandbox, configuration: byEither) == .nonProduction)
            #expect(EarlyAdopterPolicy.evaluate(sandbox, configuration: .init(pivotBuild: nil, pivotDate: nil)) == .nonProduction)
        }
    }

    @Test("No pivot at all means the Pro has not shipped: every production install predates it")
    func noPivotIsEarly() {
        let unlaunched = EarlyAdopterConfiguration(pivotBuild: nil, pivotDate: nil)
        #expect(EarlyAdopterPolicy.evaluate(transaction("99"), configuration: unlaunched) == .earlyAdopter)
    }

    @Test("The date pivot alone decides when no build pivot is set; equal is not before")
    func datePivot() {
        let before = transaction("99", purchased: pivotDate.addingTimeInterval(-1))
        let at = transaction("1", purchased: pivotDate)
        #expect(EarlyAdopterPolicy.evaluate(before, configuration: byDate) == .earlyAdopter)
        #expect(EarlyAdopterPolicy.evaluate(at, configuration: byDate) == .regular)
    }

    @Test("Either criterion is enough when both are set")
    func eitherCriterion() {
        let oldBuildLateDate = transaction("2.3.2", purchased: pivotDate.addingTimeInterval(86_400))
        let newBuildEarlyDate = transaction("3.1", purchased: pivotDate.addingTimeInterval(-86_400))
        let newBuildLateDate = transaction("3.1", purchased: pivotDate.addingTimeInterval(86_400))
        #expect(EarlyAdopterPolicy.evaluate(oldBuildLateDate, configuration: byEither) == .earlyAdopter)
        #expect(EarlyAdopterPolicy.evaluate(newBuildEarlyDate, configuration: byEither) == .earlyAdopter)
        #expect(EarlyAdopterPolicy.evaluate(newBuildLateDate, configuration: byEither) == .regular)
    }

    @Test("An unreadable original version fails closed on the build criterion, the date may still grant")
    func unreadableVersion() {
        #expect(EarlyAdopterPolicy.evaluate(transaction("1.0b3"), configuration: byBuild) == .regular)
        let earlyDate = transaction("1.0b3", purchased: pivotDate.addingTimeInterval(-1))
        #expect(EarlyAdopterPolicy.evaluate(earlyDate, configuration: byEither) == .earlyAdopter)
    }

    /// The only expectations that depend on the build configuration, like
    /// « Simuler Pro »: tests build Debug; the `#else` documents Release.
    @Test("The debug override forces either status in a DEBUG build only")
    func debugOverride() {
        #expect(EarlyAdopterPolicy.isEarlyAdopter(status: .earlyAdopter, debugOverride: .automatic))
        #expect(!EarlyAdopterPolicy.isEarlyAdopter(status: .regular, debugOverride: .automatic))
        #expect(!EarlyAdopterPolicy.isEarlyAdopter(status: .nonProduction, debugOverride: .automatic))
        #expect(!EarlyAdopterPolicy.isEarlyAdopter(status: .unknown, debugOverride: .automatic))
        #if DEBUG
        #expect(EarlyAdopterPolicy.isEarlyAdopter(status: .nonProduction, debugOverride: .earlyAdopter))
        #expect(!EarlyAdopterPolicy.isEarlyAdopter(status: .earlyAdopter, debugOverride: .regular))
        #else
        #expect(!EarlyAdopterPolicy.isEarlyAdopter(status: .nonProduction, debugOverride: .earlyAdopter))
        #expect(EarlyAdopterPolicy.isEarlyAdopter(status: .earlyAdopter, debugOverride: .regular))
        #endif
    }

    @Test("The override cycles automatic → early adopter → regular → automatic")
    func overrideCycle() {
        #expect(EarlyAdopterDebugOverride.automatic.next == .earlyAdopter)
        #expect(EarlyAdopterDebugOverride.earlyAdopter.next == .regular)
        #expect(EarlyAdopterDebugOverride.regular.next == .automatic)
    }

    @Test("The cached record round-trips and refuses an unknown version")
    func cacheRecord() throws {
        let record = EarlyAdopterCacheRecord(
            transaction: transaction("2.3.2", purchased: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456)),
            fetchedAt: pivotDate
        )
        let data = try #require(record.encoded())
        #expect(EarlyAdopterCacheRecord.decode(data) == record)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 2
        #expect(EarlyAdopterCacheRecord.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
        #expect(EarlyAdopterCacheRecord.decode(Data("not json".utf8)) == nil)
    }
}

// MARK: - Service

private struct StubTransactionError: Error {}

/// Plays StoreKit: hands back the queued result and counts the calls.
private actor StubTransactionSource: AppTransactionSource {
    private var result: Result<AppTransactionSnapshot, any Error>
    private(set) var calls = 0

    init(_ result: Result<AppTransactionSnapshot, any Error>) {
        self.result = result
    }

    func setResult(_ result: Result<AppTransactionSnapshot, any Error>) {
        self.result = result
    }

    func fetch() async throws -> AppTransactionSnapshot {
        calls += 1
        return try result.get()
    }
}

@MainActor
private final class InMemoryEarlyAdopterCache: EarlyAdopterCache {
    var record: EarlyAdopterCacheRecord?
    init(_ record: EarlyAdopterCacheRecord? = nil) { self.record = record }
    func load() -> EarlyAdopterCacheRecord? { record }
    func save(_ record: EarlyAdopterCacheRecord) { self.record = record }
}

@Suite("Early adopter service")
@MainActor
struct EarlyAdopterServiceTests {
    private let configuration = EarlyAdopterConfiguration(pivotBuild: BuildNumber("3.0"), pivotDate: nil)

    private func service(
        source: StubTransactionSource,
        cache: InMemoryEarlyAdopterCache = InMemoryEarlyAdopterCache(),
        defaults: UserDefaults = .isolatedForTesting()
    ) -> EarlyAdopterService {
        EarlyAdopterService(
            source: source, cache: cache, configuration: configuration,
            defaults: defaults, cloud: InMemoryCloudKeyValueStore(), platform: .iOS
        )
    }

    @Test("Offline at launch: the cached facts decide, StoreKit is not asked")
    func offlineUsesCache() async {
        let source = StubTransactionSource(.failure(StubTransactionError()))
        let cache = InMemoryEarlyAdopterCache(EarlyAdopterCacheRecord(transaction: transaction("2.3.2"), fetchedAt: pivotDate))
        let service = service(source: source, cache: cache)
        #expect(service.status == .earlyAdopter)
        #expect(service.isEarlyAdopter)

        await service.refreshIfNeeded(isOnline: false)
        #expect(await source.calls == 0)
        #expect(service.isEarlyAdopter)
    }

    @Test("Nothing cached and offline is unknown — and not an early adopter")
    func nothingCachedIsUnknown() {
        let service = service(source: StubTransactionSource(.failure(StubTransactionError())))
        #expect(service.status == .unknown)
        #expect(!service.isEarlyAdopter)
    }

    @Test("Online: evaluates once, caches the facts, and does not ask again this launch")
    func onlineEvaluatesOnce() async {
        let source = StubTransactionSource(.success(transaction("2.3.2")))
        let cache = InMemoryEarlyAdopterCache()
        let service = service(source: source, cache: cache)

        await service.refreshIfNeeded(isOnline: true)
        #expect(service.status == .earlyAdopter)
        #expect(cache.record?.transaction == transaction("2.3.2"))

        await service.refreshIfNeeded(isOnline: true)
        #expect(await source.calls == 1)
    }

    @Test("A verified answer replaces the cache, both ways")
    func freshAnswerWins() async {
        let source = StubTransactionSource(.success(transaction("3.0.1")))
        let cache = InMemoryEarlyAdopterCache(EarlyAdopterCacheRecord(transaction: transaction("2.3.2"), fetchedAt: pivotDate))
        let service = service(source: source, cache: cache)
        #expect(service.status == .earlyAdopter)

        await service.refreshIfNeeded(isOnline: true)
        #expect(service.status == .regular)
        #expect(cache.record?.transaction.originalAppVersion == "3.0.1")
    }

    @Test("A failed (or unverified) fetch keeps the cached status and retries when the network comes back")
    func failureKeepsCacheAndRetries() async {
        let source = StubTransactionSource(.failure(StubTransactionError()))
        let cache = InMemoryEarlyAdopterCache(EarlyAdopterCacheRecord(transaction: transaction("2.3.2"), fetchedAt: pivotDate))
        let service = service(source: source, cache: cache)

        await service.refreshIfNeeded(isOnline: true)
        #expect(service.status == .earlyAdopter)
        #expect(cache.record?.transaction.originalAppVersion == "2.3.2")

        await source.setResult(.success(transaction("2.0.0")))
        await service.refreshIfNeeded(isOnline: true)
        #expect(await source.calls == 2)
        #expect(cache.record?.transaction.originalAppVersion == "2.0.0")
    }

    @Test("A user-triggered evaluation always asks, even after the launch one")
    func explicitEvaluationAlwaysAsks() async {
        let source = StubTransactionSource(.success(transaction("2.3.2")))
        let service = service(source: source)
        await service.refreshIfNeeded(isOnline: true)
        #expect(await service.evaluate())
        #expect(await source.calls == 2)
    }

    @Test("A sandbox answer is cached as non-production, never as early adopter")
    func sandboxAnswer() async {
        let source = StubTransactionSource(.success(transaction("1.0", environment: .sandbox)))
        let service = service(source: source)
        await service.refreshIfNeeded(isOnline: true)
        #expect(service.status == .nonProduction)
        #if DEBUG
        #expect(!service.isEarlyAdopter)
        #endif
    }

    #if DEBUG
    @Test("The debug override is persisted and read back by the next instance")
    func debugOverridePersists() {
        let defaults = UserDefaults.isolatedForTesting()
        let source = StubTransactionSource(.failure(StubTransactionError()))
        let first = service(source: source, defaults: defaults)
        #expect(!first.isEarlyAdopter)

        first.setDebugOverride(.earlyAdopter)
        #expect(first.isEarlyAdopter)
        #expect(service(source: source, defaults: defaults).debugOverride == .earlyAdopter)

        first.setDebugOverride(.regular)
        #expect(!first.isEarlyAdopter)
        first.setDebugOverride(.automatic)
        #expect(defaults.string(forKey: SettingsKey.debugEarlyAdopterOverride) == nil)
    }
    #endif
}

// MARK: - Either app counts (iCloud mirror)

@Suite("Early adopter across iPhone and Apple TV")
@MainActor
struct EarlyAdopterCrossPlatformTests {
    private let configuration = EarlyAdopterConfiguration(pivotBuild: BuildNumber("3.0"), pivotDate: nil)

    private func service(
        _ platform: EarlyAdopterPlatform,
        source: StubTransactionSource,
        cloud: InMemoryCloudKeyValueStore
    ) -> EarlyAdopterService {
        EarlyAdopterService(
            source: source, cache: InMemoryEarlyAdopterCache(), configuration: configuration,
            defaults: .isolatedForTesting(), cloud: cloud, platform: platform
        )
    }

    private func mirrored(_ snapshot: AppTransactionSnapshot) throws -> Data {
        try #require(EarlyAdopterCacheRecord(transaction: snapshot, fetchedAt: pivotDate).encoded())
    }

    @Test("Each platform has its own key, and reads the other's")
    func keys() {
        #expect(EarlyAdopterPlatform.iOS.mirrorKey == "earlyAdopter.ios.v1")
        #expect(EarlyAdopterPlatform.tvOS.mirrorKey == "earlyAdopter.tvos.v1")
        #expect(EarlyAdopterPlatform.iOS.other == .tvOS)
        #expect(EarlyAdopterPlatform.tvOS.other == .iOS)
    }

    @Test("iPhone before the Pro, Apple TV after: the TV app is an early adopter through the iPhone's facts")
    func phoneEarlyTVLate() async {
        let cloud = InMemoryCloudKeyValueStore()
        let phone = service(.iOS, source: StubTransactionSource(.success(transaction("2.3.2"))), cloud: cloud)
        await phone.refreshIfNeeded(isOnline: true)
        #expect(phone.status == .earlyAdopter)
        #expect(cloud.data(forKey: EarlyAdopterPlatform.iOS.mirrorKey) != nil)

        let tv = service(.tvOS, source: StubTransactionSource(.success(transaction("3.1"))), cloud: cloud)
        await tv.refreshIfNeeded(isOnline: true)
        #expect(tv.status == .regular)
        #expect(tv.otherPlatformStatus == .earlyAdopter)
        #expect(tv.isEarlyAdopter)
        // The TV's own (regular) facts never overwrite the iPhone's proof.
        #expect(EarlyAdopterCacheRecord.decode(cloud.data(forKey: EarlyAdopterPlatform.iOS.mirrorKey) ?? Data())?
            .transaction.originalAppVersion == "2.3.2")
    }

    @Test("The other app publishing while this one is open flips the status")
    func externalChange() async throws {
        let cloud = InMemoryCloudKeyValueStore()
        let tv = service(.tvOS, source: StubTransactionSource(.success(transaction("3.1"))), cloud: cloud)
        await tv.refreshIfNeeded(isOnline: true)
        #expect(!tv.isEarlyAdopter)

        #expect(await eventually { cloud.hasListeners })
        cloud.simulateExternalChange(try mirrored(transaction("2.0.0")), forKey: EarlyAdopterPlatform.iOS.mirrorKey)
        #expect(await eventually { tv.isEarlyAdopter })
        #expect(tv.otherPlatformStatus == .earlyAdopter)
    }

    @Test("Offline at launch, the other platform's record still counts")
    func offlineReadsMirror() throws {
        let cloud = InMemoryCloudKeyValueStore()
        cloud.set(try mirrored(transaction("2.3.2")), forKey: EarlyAdopterPlatform.iOS.mirrorKey)
        let tv = service(.tvOS, source: StubTransactionSource(.failure(StubTransactionError())), cloud: cloud)
        #expect(tv.status == .unknown)
        #expect(tv.isEarlyAdopter)
    }

    @Test("A sandbox / TestFlight answer is never published, and a mirrored one never grants")
    func nonProductionNeverCrosses() async throws {
        let cloud = InMemoryCloudKeyValueStore()
        let phone = service(.iOS, source: StubTransactionSource(.success(transaction("1.0", environment: .sandbox))), cloud: cloud)
        await phone.refreshIfNeeded(isOnline: true)
        #expect(cloud.data(forKey: EarlyAdopterPlatform.iOS.mirrorKey) == nil)

        cloud.set(try mirrored(transaction("1.0", environment: .sandbox)), forKey: EarlyAdopterPlatform.iOS.mirrorKey)
        let tv = service(.tvOS, source: StubTransactionSource(.failure(StubTransactionError())), cloud: cloud)
        #expect(tv.otherPlatformStatus == .nonProduction)
        #expect(!tv.isEarlyAdopter)
    }

    @Test("An app ignores its OWN key as « the other platform »")
    func ownKeyIsNotOther() throws {
        let cloud = InMemoryCloudKeyValueStore()
        cloud.set(try mirrored(transaction("2.3.2")), forKey: EarlyAdopterPlatform.tvOS.mirrorKey)
        let tv = service(.tvOS, source: StubTransactionSource(.failure(StubTransactionError())), cloud: cloud)
        #expect(tv.otherPlatformStatus == .unknown)
        #expect(!tv.isEarlyAdopter)
    }

    @Test("Both late is regular on both")
    func bothLate() async {
        let cloud = InMemoryCloudKeyValueStore()
        let phone = service(.iOS, source: StubTransactionSource(.success(transaction("3.0"))), cloud: cloud)
        await phone.refreshIfNeeded(isOnline: true)
        let tv = service(.tvOS, source: StubTransactionSource(.success(transaction("3.2"))), cloud: cloud)
        await tv.refreshIfNeeded(isOnline: true)
        #expect(!phone.isEarlyAdopter)
        #expect(!tv.isEarlyAdopter)
    }

    @Test("The Debug row shows the App Store facts of this app, then of the other one")
    func factsText() async throws {
        let loc = LocalizationManager()
        let cloud = InMemoryCloudKeyValueStore()
        let tv = service(.tvOS, source: StubTransactionSource(.success(transaction("3.1"))), cloud: cloud)
        #expect(earlyAdopterFactsText(tv, loc: loc) == nil)

        await tv.refreshIfNeeded(isOnline: true)
        let own = try #require(earlyAdopterFactsText(tv, loc: loc))
        #expect(own.contains("3.1"))
        #expect(!own.contains("\n"))

        cloud.set(try mirrored(transaction("2.3.2")), forKey: EarlyAdopterPlatform.iOS.mirrorKey)
        await tv.refreshIfNeeded(isOnline: true)
        let both = try #require(earlyAdopterFactsText(tv, loc: loc)).components(separatedBy: "\n")
        #expect(both.count == 2)
        #expect(both[0].contains("3.1"))
        #expect(both[1].contains("2.3.2"))
    }

    @Test("A mirrored record carrying the JWS round-trips it")
    func jwsRoundTrip() throws {
        var snapshot = transaction("2.3.2")
        snapshot.signedTransaction = "eyJhbGciOiJFUzI1NiJ9.payload.signature"
        let decoded = EarlyAdopterCacheRecord.decode(try mirrored(snapshot))
        #expect(decoded?.transaction.signedTransaction == snapshot.signedTransaction)
    }
}
