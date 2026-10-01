import Foundation

/// A `CFBundleVersion` read as numbers: `"2.3.2"` → `[2, 3, 2]`.
///
/// This project's build numbers are DOTTED (`1`, `1.0.2`, `2.3.2` — see
/// `CURRENT_PROJECT_VERSION` in `project.yml`), so neither a string nor an
/// integer comparison is right: `"1.0.10" < "1.0.2"` as text, and `Int("2.3.2")`
/// is `nil`. Components compare as numbers, and a missing trailing component
/// counts as zero, so `1 == 1.0 == 1.0.0` — `Equatable` follows the same rule
/// as `<`, never the raw array.
nonisolated struct BuildNumber: Comparable, Sendable, CustomStringConvertible {
    let components: [Int]

    init(components: [Int]) {
        self.components = components
    }

    /// `nil` for anything but dot-separated ASCII digits (`"1.0b3"`, `"1."`, `""`).
    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ ("0"..."9").contains($0) }),
                  let value = Int(part) else { return nil }
            components.append(value)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// The facts of the App Store's `AppTransaction` this decision needs — and all
/// the Keychain cache keeps. Plain values, so the policy and the tests never
/// touch StoreKit (an `AppTransaction` cannot be built outside the system).
nonisolated struct AppTransactionSnapshot: Codable, Sendable, Equatable {
    enum Environment: String, Codable, Sendable {
        case production
        /// Sandbox AND TestFlight.
        case sandbox
        case xcode
    }

    /// The `CFBundleVersion` (the BUILD, not the marketing version) of the
    /// first copy this Apple account got of THIS app. Per app: the iOS and
    /// tvOS apps have different bundle ids, so each one has its own.
    let originalAppVersion: String
    let originalPurchaseDate: Date
    let environment: Environment
    /// The App Store's JWS of this transaction, kept so a later reader can
    /// VERIFY what the iCloud mirror hands it instead of trusting the blob
    /// (same reason as `CloudEntitlementRecord.signedTransaction`). Optional:
    /// absent from records written before it existed.
    var signedTransaction: String?
}

/// Which of the two apps — different bundle ids, so each one has its own
/// `AppTransaction`. An Apple account that got EITHER app before the Pro is an
/// early adopter in BOTH: each app publishes its own production facts to the
/// shared iCloud key-value store under its own key, and reads the other's.
nonisolated enum EarlyAdopterPlatform: String, Sendable, CaseIterable {
    case iOS = "ios"
    case tvOS = "tvos"

    static var current: Self {
        #if os(tvOS)
        .tvOS
        #else
        .iOS
        #endif
    }

    var other: Self {
        switch self {
        case .iOS: .tvOS
        case .tvOS: .iOS
        }
    }

    /// One key PER platform, so neither app can overwrite the other's facts
    /// (a TV app installed after the Pro would otherwise erase the iPhone's
    /// early-adopter proof). Versioned like `entitlement.pro.v1`.
    var mirrorKey: String { "earlyAdopter.\(rawValue).v1" }
}

/// When the Pro launched. Both `nil` = it has not: every production install
/// predates it.
nonisolated struct EarlyAdopterConfiguration: Sendable, Equatable {
    /// The FIRST build that ships the Pro. A first install strictly older is
    /// an early adopter.
    var pivotBuild: BuildNumber?
    /// The alternative criterion: a first purchase strictly before it is an
    /// early adopter, whatever the build said.
    var pivotDate: Date?

    /// THE production constant. **RULE — set `pivotBuild` to the first Pro
    /// build in the very release that ships the Pro** (see
    /// `Shared/Entitlements/CLAUDE.md`): left `nil`, every new install gets
    /// the Pro for free. The cache keeps the transaction's facts, not a
    /// verdict, so setting it re-decides every user, offline ones included.
    static let production = Self(pivotBuild: nil, pivotDate: nil)
}

nonisolated enum EarlyAdopterStatus: Sendable, Equatable {
    /// Never evaluated: nothing cached, and StoreKit unreachable or not asked.
    case unknown
    case earlyAdopter
    case regular
    /// Sandbox, TestFlight or Xcode: `originalAppVersion` is « 1.0 » in the
    /// sandbox (every tester an early adopter) and the current build under
    /// Xcode — meaningless either way.
    case nonProduction
}

/// Settings → Debug → « Early adopter ». DEBUG builds only. The raw value is
/// what `SettingsKey.debugEarlyAdopterOverride` stores.
nonisolated enum EarlyAdopterDebugOverride: String, CaseIterable, Sendable {
    case automatic = ""
    case earlyAdopter = "earlyAdopter"
    case regular = "regular"

    /// The row cycles through the three.
    var next: Self {
        switch self {
        case .automatic: .earlyAdopter
        case .earlyAdopter: .regular
        case .regular: .automatic
        }
    }
}

/// The pure early-adopter decision. No state, no I/O — `EarlyAdopterService`
/// gathers the inputs and `EarlyAdopterTests` locks every branch.
nonisolated enum EarlyAdopterPolicy {
    /// Non-production first (its « 1.0 » means nothing). Then: no pivot at all
    /// → the Pro has not shipped → early adopter. Otherwise either criterion
    /// grants. An unreadable `originalAppVersion` fails the build criterion
    /// only — the date may still grant.
    static func evaluate(
        _ transaction: AppTransactionSnapshot,
        configuration: EarlyAdopterConfiguration
    ) -> EarlyAdopterStatus {
        guard transaction.environment == .production else { return .nonProduction }
        guard configuration.pivotBuild != nil || configuration.pivotDate != nil else { return .earlyAdopter }
        if let pivot = configuration.pivotBuild,
           let original = BuildNumber(transaction.originalAppVersion),
           original < pivot {
            return .earlyAdopter
        }
        if let pivotDate = configuration.pivotDate, transaction.originalPurchaseDate < pivotDate {
            return .earlyAdopter
        }
        return .regular
    }

    /// The published boolean: this app's status OR the other platform's
    /// (read from the iCloud mirror). A Release build ignores `debugOverride`
    /// whatever the stored value says, like « Simuler Pro ».
    static func isEarlyAdopter(
        status: EarlyAdopterStatus,
        otherPlatformStatus: EarlyAdopterStatus = .unknown,
        debugOverride: EarlyAdopterDebugOverride
    ) -> Bool {
        #if DEBUG
        switch debugOverride {
        case .earlyAdopter: return true
        case .regular: return false
        case .automatic: break
        }
        #endif
        return status == .earlyAdopter || otherPlatformStatus == .earlyAdopter
    }
}

/// The last VERIFIED transaction facts — the Keychain cache's payload, and
/// the iCloud mirror's (under `EarlyAdopterPlatform.mirrorKey`).
/// `decode(_:)` returns `nil` for an unknown version or a malformed blob, never
/// traps — an unreadable cache is just « nothing cached ».
nonisolated struct EarlyAdopterCacheRecord: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let transaction: AppTransactionSnapshot
    let fetchedAt: Date

    init(transaction: AppTransactionSnapshot, fetchedAt: Date) {
        self.version = Self.currentVersion
        self.transaction = transaction
        self.fetchedAt = fetchedAt
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> Self? {
        guard let record = try? JSONDecoder().decode(Self.self, from: data),
              record.version == currentVersion else { return nil }
        return record
    }
}
