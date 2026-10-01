import CinemaxKit
import Foundation
import Observation
import OSLog
import StoreKit

private let logger = Logger(subsystem: "com.cinemax", category: "EarlyAdopter")

/// Where the App Store's transaction comes from. StoreKit in the app, a stub
/// in the tests.
protocol AppTransactionSource: Sendable {
    /// Throws when the App Store cannot answer, AND when its answer fails
    /// verification — an unverified transaction is never trusted.
    func fetch() async throws -> AppTransactionSnapshot
}

/// `AppTransaction.shared`, verified. A Debug build raises a sandbox Apple
/// account prompt here — which is why the launch call is Release-only (see
/// `Shared/Entitlements/CLAUDE.md`).
nonisolated struct StoreKitAppTransactionSource: AppTransactionSource {
    func fetch() async throws -> AppTransactionSnapshot {
        let result = try await AppTransaction.shared
        switch result {
        case .verified(let transaction):
            return AppTransactionSnapshot(
                originalAppVersion: transaction.originalAppVersion,
                originalPurchaseDate: transaction.originalPurchaseDate,
                environment: AppTransactionSnapshot.Environment(transaction.environment),
                signedTransaction: result.jwsRepresentation
            )
        case .unverified(_, let error):
            throw error
        }
    }
}

private extension AppTransactionSnapshot.Environment {
    /// A value StoreKit may add later counts as non-production: fail closed.
    nonisolated init(_ environment: AppStore.Environment) {
        switch environment {
        case .production: self = .production
        case .xcode: self = .xcode
        default: self = .sandbox
        }
    }
}

/// The offline memory of the last verified transaction.
@MainActor
protocol EarlyAdopterCache {
    func load() -> EarlyAdopterCacheRecord?
    func save(_ record: EarlyAdopterCacheRecord)
}

/// The app-private Keychain item `early_adopter`. Survives a logout (and, on
/// iOS, usually a reinstall). A failed write is logged and dropped: the status
/// in memory is still right, and the next online launch writes it again.
struct KeychainEarlyAdopterCache: EarlyAdopterCache {
    private let keychain = KeychainService()

    func load() -> EarlyAdopterCacheRecord? {
        keychain.getEarlyAdopterRecord().flatMap(EarlyAdopterCacheRecord.decode)
    }

    func save(_ record: EarlyAdopterCacheRecord) {
        guard let data = record.encoded() else { return }
        do {
            try keychain.saveEarlyAdopterRecord(data)
        } catch {
            logger.error("Early adopter cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// « Did this Apple account get EITHER app before the Pro launched? » — those
/// keep the Pro for free, for good, on both platforms: this app's own
/// transaction decides `status`, the other app's facts — published to the
/// shared iCloud key-value store — decide `otherPlatformStatus`. A process singleton hosted by
/// `AppNavigation` (`sharedEarlyAdopter`) and injected through the environment.
///
/// Nothing reads `isEarlyAdopter` to grant anything yet: it is to be plugged
/// into `EntitlementStore`. Plain stored properties + explicit mutators — no
/// `didSet` on an `@Observable` (root RULE).
@MainActor @Observable
final class EarlyAdopterService {
    private(set) var status: EarlyAdopterStatus = .unknown
    /// The facts `status` was decided from — Settings → Debug shows them.
    private(set) var transaction: AppTransactionSnapshot?
    /// The OTHER app's status, decided from the facts it published to iCloud
    /// (`EarlyAdopterPlatform.mirrorKey`). `.unknown` until it has run with a
    /// network once on an account sharing this iCloud.
    private(set) var otherPlatformStatus: EarlyAdopterStatus = .unknown
    private(set) var otherPlatformTransaction: AppTransactionSnapshot?
    /// Always `.automatic` in a Release build.
    private(set) var debugOverride: EarlyAdopterDebugOverride = .automatic

    var isEarlyAdopter: Bool {
        EarlyAdopterPolicy.isEarlyAdopter(
            status: status,
            otherPlatformStatus: otherPlatformStatus,
            debugOverride: debugOverride
        )
    }

    @ObservationIgnored private let source: any AppTransactionSource
    @ObservationIgnored private let cache: any EarlyAdopterCache
    @ObservationIgnored private let configuration: EarlyAdopterConfiguration
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cloud: any CloudKeyValueStore
    @ObservationIgnored private let platform: EarlyAdopterPlatform
    @ObservationIgnored private var externalChangesTask: Task<Void, Never>?
    /// Set once StoreKit has answered in this process: the launch evaluation
    /// is done, a later network return asks nothing.
    @ObservationIgnored private var hasEvaluatedThisLaunch = false
    @ObservationIgnored private var isEvaluating = false

    /// Every argument is a test seam (`cloud`: `InMemoryCloudKeyValueStore`,
    /// never the real iCloud in a test). Reads the Keychain cache and the
    /// other platform's iCloud record synchronously, so the very first frame
    /// already knows both, then listens for iCloud's external changes — the
    /// other app may publish while this one is open.
    init(
        source: any AppTransactionSource = StoreKitAppTransactionSource(),
        cache: any EarlyAdopterCache = KeychainEarlyAdopterCache(),
        configuration: EarlyAdopterConfiguration = .production,
        defaults: UserDefaults = .standard,
        cloud: any CloudKeyValueStore = UbiquitousCloudKeyValueStore(),
        platform: EarlyAdopterPlatform = .current
    ) {
        self.source = source
        self.cache = cache
        self.configuration = configuration
        self.defaults = defaults
        self.cloud = cloud
        self.platform = platform
        #if DEBUG
        debugOverride = defaults.string(forKey: SettingsKey.debugEarlyAdopterOverride)
            .flatMap(EarlyAdopterDebugOverride.init(rawValue:)) ?? .automatic
        #endif
        if let record = cache.load() {
            apply(record.transaction)
        }
        readOtherPlatform()
        externalChangesTask = Task { [weak self, cloud] in
            for await _ in cloud.externalChanges() {
                guard let self else { return }
                self.readOtherPlatform()
            }
        }
    }

    deinit {
        externalChangesTask?.cancel()
    }

    /// Launch, and every return of the network until StoreKit has answered
    /// once in this process. Offline, the cached status stands. Re-reads the
    /// other platform's record first, whatever the network.
    func refreshIfNeeded(isOnline: Bool) async {
        cloud.synchronize()
        readOtherPlatform()
        guard isOnline, !hasEvaluatedThisLaunch else { return }
        await evaluate()
    }

    /// Asks StoreKit now, whatever was already asked. A verified answer
    /// replaces the cache — both ways: the facts never change, only the
    /// configuration can. A failure (offline, App Store down, unverified)
    /// leaves the cached status alone. Returns whether StoreKit answered.
    @discardableResult
    func evaluate() async -> Bool {
        guard !isEvaluating else { return false }
        isEvaluating = true
        defer { isEvaluating = false }
        do {
            let fresh = try await source.fetch()
            hasEvaluatedThisLaunch = true
            let record = EarlyAdopterCacheRecord(transaction: fresh, fetchedAt: Date())
            cache.save(record)
            publish(record)
            apply(fresh)
            logger.info("Early adopter evaluated: original build \(fresh.originalAppVersion, privacy: .public), \(fresh.environment.rawValue, privacy: .public)")
            return true
        } catch {
            logger.error("Early adopter evaluation failed, keeping the cached status: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    #if DEBUG
    /// Settings → Debug → « Early adopter ». Persisted, DEBUG builds only;
    /// `.automatic` removes the key.
    func setDebugOverride(_ value: EarlyAdopterDebugOverride) {
        if value == .automatic {
            defaults.removeObject(forKey: SettingsKey.debugEarlyAdopterOverride)
        } else {
            defaults.set(value.rawValue, forKey: SettingsKey.debugEarlyAdopterOverride)
        }
        if value != debugOverride { debugOverride = value }
    }
    #endif

    /// Hands this app's facts to the other platform. PRODUCTION facts only: a
    /// TestFlight or Xcode answer means nothing to the other app either, and
    /// publishing it would only overwrite a production record of this same app
    /// on the account (a tester's own App Store install).
    private func publish(_ record: EarlyAdopterCacheRecord) {
        guard record.transaction.environment == .production, let data = record.encoded() else { return }
        cloud.set(data, forKey: platform.mirrorKey)
        cloud.synchronize()
    }

    private func readOtherPlatform() {
        let other = cloud.data(forKey: platform.other.mirrorKey)
            .flatMap(EarlyAdopterCacheRecord.decode)?.transaction
        if other != otherPlatformTransaction { otherPlatformTransaction = other }
        let resolved = other.map { EarlyAdopterPolicy.evaluate($0, configuration: configuration) } ?? .unknown
        if resolved != otherPlatformStatus { otherPlatformStatus = resolved }
    }

    private func apply(_ fresh: AppTransactionSnapshot) {
        if fresh != transaction { transaction = fresh }
        let resolved = EarlyAdopterPolicy.evaluate(fresh, configuration: configuration)
        if resolved != status { status = resolved }
    }
}
